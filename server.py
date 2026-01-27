import http.server
import socketserver
import os
import urllib.parse
import sys
import re
import json
import logging
import shutil

# --- Configuration ---
PORT = 8001
FIFO_STDIN = "/tmp/gp-stdin"
FIFO_CONTROL = "/tmp/gp-control"
LOG_FILE = "/tmp/gp-logs/vpn.log"
MODE_FILE = "/tmp/gp-mode"
DEBUG_LOG = "/tmp/gp-logs/debug_parser.log"

# --- Logging Setup ---
# We use a custom format to clearly distinguish Server logic from VPN logic
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "DEBUG").upper(),
    format="[%(asctime)s] [SERVER] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.FileHandler(DEBUG_LOG),
        logging.StreamHandler(sys.stderr),
    ],
)
logger = logging.getLogger()

# State cache to prevent log spam on every poll
last_known_state = None


def strip_ansi(text):
    """
    Aggressively removes ANSI escape sequences to reveal pure text.
    Handles colors, cursor movements, and line clearing.
    """
    # 7-bit C1 ANSI sequences
    ansi_escape = re.compile(
        r"""
        \x1B  # ESC
        (?:   # 7-bit C1 Fe (except CSI)
            [@-Z\\-_]
        |     # or [ for CSI, followed by a control sequence
            \[
            [0-?]* # Parameter bytes
            [ -/]* # Intermediate bytes
            [@-~]   # Final byte
        )
    """,
        re.VERBOSE,
    )
    return ansi_escape.sub("", text)


def get_vpn_state():
    """
    Parses the VPN log to determine the current state of the connection process.
    Moves from the specific (log lines) to the whole (User UI State).
    """
    global last_known_state

    # default state
    current_state = "idle"

    # 1. Check coarse process state (The Container's Mode)
    if os.path.exists(MODE_FILE):
        try:
            with open(MODE_FILE, "r") as f:
                mode = f.read().strip()
                if mode == "active":
                    current_state = "connecting"
        except Exception as e:
            logger.error(f"Failed to read mode file: {e}")

    if current_state == "idle":
        return {"state": "idle", "log": "Ready to connect."}

    log_content = ""
    sso_url = ""
    prompt_msg = ""
    prompt_type = "text"
    input_options = []
    error_msg = ""

    # 2. Analyze the 'Parts' (The Logs) to understand the 'Whole' (The Status)
    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r", errors="replace") as f:
                lines = f.readlines()
                log_content = "".join(lines[-300:])  # Keep last 300 lines for UI

                # Clean lines for logic processing
                clean_lines = [strip_ansi(l).strip() for l in lines[-100:]]

                # --- HERMENEUTIC ANALYSIS OF LOGS ---

                # A. Did we succeed?
                for line in reversed(clean_lines):
                    if "Connected" in line and "to" in line:  # OpenConnect success msg
                        current_state = "connected"
                        break

                # B. Did we fail? (The missing link in your previous code)
                # We prioritize errors to stop the loop.
                if current_state != "connected":
                    for line in reversed(clean_lines):
                        if "Login failed" in line or "GP response error" in line:
                            current_state = "error"
                            # Extract specific error if possible
                            if "512" in line:
                                error_msg = "Gateway Rejected Connection (Error 512). Check Gateway selection or User Agent."
                            else:
                                error_msg = line
                            break

                # C. Does the CLI need us? (Interactive Prompts)
                if current_state not in ["connected", "error"]:
                    for i, line in enumerate(reversed(clean_lines)):
                        # Gateway Selection
                        if "Which gateway do you want to connect to" in line:
                            current_state = "input"
                            prompt_msg = "Select Gateway:"
                            prompt_type = "select"

                            # Parse Options (Scan forward from the prompt in the *raw* lines ideally,
                            # but clean lines work if stripped correctly)
                            # We look for lines like: "  Lehi-Gateway (vpn.snapone.com)"
                            gateway_regex = re.compile(
                                r"^\s*([A-Za-z0-9\-\.]+\s+\([A-Za-z0-9\-\.]+\))"
                            )

                            # Scan the whole clean buffer for options
                            seen = set()
                            for l in clean_lines:
                                m = gateway_regex.search(l)
                                if m:
                                    opt = m.group(1).strip()
                                    if opt not in seen and "Which gateway" not in opt:
                                        seen.add(opt)
                                        input_options.append(opt)
                            break

                        # Password / Username
                        if "password:" in line.lower():
                            current_state = "input"
                            prompt_msg = "Enter Password:"
                            prompt_type = "password"
                            break

                        if "username:" in line.lower():
                            current_state = "input"
                            prompt_msg = "Enter Username:"
                            prompt_type = "text"
                            break

                # D. Authentication (The Sticky State)
                # If we are connecting/input but see auth URLs, we shift to Auth mode
                if current_state in ["connecting", "input"]:
                    is_manual_auth = "Manual Authentication Required" in log_content
                    auth_server_active = "auth server started" in log_content

                    if is_manual_auth or auth_server_active:
                        current_state = "auth"
                        # Extract SAML URL
                        url_pattern = re.compile(r'(https?://[^\s"<>]+)')
                        found_urls = url_pattern.findall(log_content)
                        if found_urls:
                            # Heuristic: The last URL is usually the one we want.
                            # Prefer URLs that look like our local auth server
                            local_urls = [
                                u
                                for u in found_urls
                                if str(PORT) not in u and "127.0.0.1" not in u
                            ]
                            if local_urls:
                                sso_url = local_urls[-1]
                            # Fallback to any URL found (handling the local auth server redirect)
                            if not sso_url and found_urls:
                                sso_url = found_urls[-1]

        except Exception as e:
            logger.error(f"Error parsing log file: {e}")
            log_content += f"\n[System Error: {e}]"

    # --- Logging the 'Why' (Hermeneutic Context) ---
    # Only log if state changed to reduce noise, but keep context available
    if current_state != last_known_state:
        logger.info(f"State Transition: {last_known_state} -> {current_state}")
        if current_state == "input":
            logger.info(
                f"detected Prompt: '{prompt_msg}' | Options found: {len(input_options)}"
            )
        if current_state == "error":
            logger.error(f"detected Error: {error_msg}")
        last_known_state = current_state

    return {
        "state": current_state,
        "url": sso_url,
        "prompt": prompt_msg,
        "input_type": prompt_type,
        "options": sorted(input_options),  # Sort for UX consistency
        "error": error_msg,
        "log": log_content,
        "debug": f"Server Decision: {current_state} | Input Options: {len(input_options)}",
    }


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/status.json"):
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(json.dumps(get_vpn_state()).encode("utf-8"))
            return

        if self.path == "/download_logs":
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header(
                    "Content-Disposition", "attachment; filename=vpn_full_debug.log"
                )
                self.end_headers()

                self.wfile.write(b"=== SYSTEM DEBUG LOG (debug_parser.log) ===\n\n")
                if os.path.exists(DEBUG_LOG):
                    with open(DEBUG_LOG, "rb") as f:
                        shutil.copyfileobj(f, self.wfile)

                self.wfile.write(b"\n\n=== VPN CLIENT LOG (vpn.log) ===\n\n")
                if os.path.exists(LOG_FILE):
                    with open(LOG_FILE, "rb") as f:
                        shutil.copyfileobj(f, self.wfile)
            except Exception as e:
                logger.error(f"Download failed: {e}")
            return

        if self.path == "/":
            self.path = "/index.html"
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == "/connect":
            logger.info("User requested Connection (POST /connect)")
            with open(FIFO_CONTROL, "w") as f:
                f.write("START\n")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if self.path == "/submit":
            try:
                length = int(self.headers.get("Content-Length", 0))
                data = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))

                # Determine what was submitted
                user_input = ""
                if "callback_url" in data:
                    user_input = data["callback_url"][0].strip()
                    logger.info("User submitted SSO Callback URL")
                elif "user_input" in data:
                    user_input = data["user_input"][0].strip()
                    logger.info(f"User submitted Interactive Input: '{user_input}'")

                if user_input:
                    # Write to the pipe that feeds gpclient
                    with open(FIFO_STDIN, "w") as fifo:
                        fifo.write(user_input + "\n")
                        fifo.flush()

                    self.send_response(200)
                    self.send_header("Content-type", "text/html")
                    self.end_headers()
                    self.wfile.write(
                        b"<html><head><meta http-equiv='refresh' content='0;url=/'></head><body>Sent.</body></html>"
                    )
                else:
                    logger.warning("User submitted empty input.")
                    self.send_error(400, "Empty input")
            except Exception as e:
                logger.error(f"Input submission failed: {e}")
                self.send_error(500, str(e))
            return


if __name__ == "__main__":
    os.chdir("/var/www/html")
    logger.info(f"Server initializing on Port {PORT}...")

    if not os.path.exists(FIFO_CONTROL):
        os.mkfifo(FIFO_CONTROL)
        os.chmod(FIFO_CONTROL, 0o666)

    # Allow quick restarts during dev/debug
    socketserver.TCPServer.allow_reuse_address = True

    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        logger.info("Server Ready. Waiting for interactions.")
        httpd.serve_forever()
