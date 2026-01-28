import http.server
import socketserver
import os
import urllib.parse
import sys
import re
import json
import logging
import shutil
import subprocess
import time

# --- Configuration ---
PORT = 8001
FIFO_STDIN = "/tmp/gp-stdin"
FIFO_CONTROL = "/tmp/gp-control"
LOG_FILE = "/tmp/gp-logs/vpn.log"
MODE_FILE = "/tmp/gp-mode"
DEBUG_LOG = "/tmp/gp-logs/debug_parser.log"

# --- Logging Setup ---
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

last_known_state = None


def strip_ansi(text):
    """
    Aggressively removes ANSI escape sequences to reveal pure text.
    Handles colors, cursor movements, and line clearing.
    """
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
    """
    global last_known_state

    current_state = "idle"

    # 1. Check Mode File
    # If entrypoint.sh says "active", we are at least connecting.
    # If entrypoint.sh writes "idle", we trust that immediately.
    if os.path.exists(MODE_FILE):
        try:
            with open(MODE_FILE, "r") as f:
                content = f.read().strip()
                if content == "active":
                    current_state = "connecting"
                elif content == "idle":
                    return {"state": "idle", "log": "Ready to connect."}
        except Exception as e:
            logger.error(f"Failed to read mode file: {e}")

    log_content = ""
    sso_url = ""
    prompt_msg = ""
    prompt_type = "text"
    input_options = []
    error_msg = ""

    # 2. Parse Logs
    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r", errors="replace") as f:
                lines = f.readlines()
                log_content = "".join(lines[-300:])
                clean_lines = [strip_ansi(l).strip() for l in lines[-100:]]

                # A. Success Check
                for line in reversed(clean_lines):
                    if "Connected" in line and "to" in line:
                        current_state = "connected"
                        break

                # B. Error Check
                if current_state != "connected":
                    for line in reversed(clean_lines):
                        if "Login failed" in line or "GP response error" in line:
                            current_state = "error"
                            if "512" in line:
                                error_msg = "Gateway Rejected Connection (Error 512). Check Gateway selection or User Agent."
                            else:
                                error_msg = line
                            break

                # C. Input/Prompt Check
                if current_state not in ["connected", "error"]:
                    for line in reversed(clean_lines):
                        if "Which gateway do you want to connect to" in line:
                            current_state = "input"
                            prompt_msg = "Select Gateway:"
                            prompt_type = "select"

                            gateway_regex = re.compile(
                                r"(?:>|\s)*([A-Za-z0-9\-\.]+\s+\([A-Za-z0-9\-\.]+\))"
                            )
                            seen = set()
                            for l in clean_lines:
                                m = gateway_regex.search(l)
                                if m:
                                    opt = m.group(1).strip()
                                    if opt not in seen and "Which gateway" not in opt:
                                        seen.add(opt)
                                        input_options.append(opt)
                            break

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

                # D. Auth Check
                if current_state == "connecting":
                    if (
                        "Manual Authentication Required" in log_content
                        or "auth server started" in log_content
                    ):
                        current_state = "auth"
                        url_pattern = re.compile(r'(https?://[^\s"<>]+)')
                        found_urls = url_pattern.findall(log_content)
                        if found_urls:
                            local_urls = [
                                u
                                for u in found_urls
                                if str(PORT) not in u and "127.0.0.1" not in u
                            ]
                            sso_url = local_urls[-1] if local_urls else found_urls[-1]

        except Exception as e:
            logger.error(f"Log parse error: {e}")
            log_content += f"\n[System Error: {e}]"

    if current_state != last_known_state:
        logger.info(f"State Transition: {last_known_state} -> {current_state}")
        last_known_state = current_state

    return {
        "state": current_state,
        "url": sso_url,
        "prompt": prompt_msg,
        "input_type": prompt_type,
        "options": sorted(input_options),
        "error": error_msg,
        "log": log_content,
        "debug": f"State: {current_state}",
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
        # --- CONNECT HANDLER ---
        if self.path == "/connect":
            logger.info("User requested Connection (POST /connect)")
            try:
                logger.info("Ensuring previous gpclient processes are terminated...")
                # Use sudo because gpclient runs as root
                subprocess.run(["sudo", "pkill", "gpclient"], stderr=subprocess.DEVNULL)
                time.sleep(0.5)  # Allow entrypoint loop to reset
            except Exception as e:
                logger.error(f"Failed to kill gpclient: {e}")

            try:
                with open(FIFO_CONTROL, "w") as f:
                    f.write("START\n")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            except Exception as e:
                logger.error(f"Failed to write to control pipe: {e}")
                self.send_error(500, "Failed to start VPN process")
            return

        # --- DISCONNECT HANDLER (NEW) ---
        if self.path == "/disconnect":
            logger.info("User requested Disconnect (POST /disconnect)")
            try:
                # Use sudo to kill the root process.
                # entrypoint.sh will detect the exit and set state to 'idle'.
                subprocess.run(["sudo", "pkill", "gpclient"], stderr=subprocess.DEVNULL)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            except Exception as e:
                logger.error(f"Disconnect failed: {e}")
                self.send_error(500, "Failed to stop VPN process")
            return

        # --- SUBMIT HANDLER ---
        if self.path == "/submit":
            try:
                length = int(self.headers.get("Content-Length", 0))
                data = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))

                user_input = ""
                if "callback_url" in data:
                    user_input = data["callback_url"][0].strip()
                    logger.info("User submitted SSO Callback URL")
                elif "user_input" in data:
                    user_input = data["user_input"][0].strip()
                    logger.info(f"User submitted Interactive Input: '{user_input}'")

                if user_input:
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

    socketserver.TCPServer.allow_reuse_address = True

    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        logger.info("Server Ready. Waiting for interactions.")
        httpd.serve_forever()
