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
TRACE_LEVEL_NUM = 5
logging.addLevelName(TRACE_LEVEL_NUM, "TRACE")


def trace(self, message, *args, **kws):
    if self.isEnabledFor(TRACE_LEVEL_NUM):
        self._log(TRACE_LEVEL_NUM, message, args, **kws)


logging.Logger.trace = trace

env_level = os.getenv("LOG_LEVEL", "INFO").upper()
log_level = getattr(logging, env_level, logging.INFO)
if env_level == "TRACE":
    log_level = TRACE_LEVEL_NUM

handlers = [
    logging.FileHandler(DEBUG_LOG),
    logging.StreamHandler(sys.stderr),
]

logging.basicConfig(
    level=log_level,
    format="[%(asctime)s] [%(levelname)s] [server.py] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
    handlers=handlers,
)

logger = logging.getLogger()


def strip_ansi(text):
    """Removes ANSI escape sequences from log lines."""
    ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
    return ansi_escape.sub("", text)


def get_vpn_state():
    """
    Determines the current state of the VPN.
    Combines coarse process state (MODE_FILE) with fine-grained log parsing.
    """
    state = "idle"
    if os.path.exists(MODE_FILE):
        try:
            with open(MODE_FILE, "r") as f:
                mode = f.read().strip()
                if mode == "active":
                    state = "connecting"
        except Exception as e:
            logger.error(f"Failed to read mode file: {e}")

    if state == "idle":
        return {"state": "idle", "log": "Ready to connect."}

    log_content = ""
    sso_url = ""
    prompt_msg = ""
    prompt_type = "text"  # text, password, select
    input_options = []

    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r", errors="replace") as f:
                lines = f.readlines()
                # Keep last 300 lines for display
                log_content = "".join(lines[-300:])

                # Create clean lines for parsing (strip colors)
                # We check the last 50 lines for active prompts
                clean_lines = [strip_ansi(l) for l in lines[-50:]]

                # 1. Check for Success
                for line in reversed(clean_lines):
                    if "Connected" in line:
                        state = "connected"
                        logger.debug("State transition detected: CONNECTED")
                        return {
                            "state": "connected",
                            "log": "VPN Established Successfully!",
                        }

                # 2. Check for Interactive Prompts (PRIORITY OVER AUTH)
                for i, line in enumerate(reversed(clean_lines)):
                    line_stripped = line.strip()

                    # A. Gateway Selection (Dropdown)
                    if "Which gateway do you want to connect to" in line:
                        state = "input"
                        prompt_msg = "Select Gateway:"
                        prompt_type = "select"

                        # Scrape options from the lines we just reversed
                        gateway_regex = re.compile(
                            r"(?:>)?\s+([a-zA-Z0-9-]+\s+\([a-zA-Z0-9.-]+\))"
                        )
                        seen = set()
                        for l in clean_lines:
                            m = gateway_regex.search(l)
                            if m:
                                opt = m.group(1).strip()
                                if opt not in seen:
                                    seen.add(opt)
                                    input_options.append(opt)
                        break

                    # B. Specific Inputs (Masked)
                    if "password:" in line.lower():
                        state = "input"
                        prompt_msg = line_stripped
                        prompt_type = "password"
                        break

                    if "username:" in line.lower():
                        state = "input"
                        prompt_msg = line_stripped
                        prompt_type = "text"
                        break

                    # C. Generic Catch-All (2FA, Challenges, etc.)
                    # Logic: Line does NOT start with timestamp '[' AND ends with ':' or '?'
                    # We also filter out "browser" instructions to avoid grabbing the Auth text.
                    if re.match(r"^[^\[].*[:?]\s*$", line_stripped):
                        # Filter out common false positives
                        if "browser" in line.lower() or "url" in line.lower():
                            continue

                        state = "input"
                        prompt_msg = line_stripped
                        prompt_type = "text"
                        break

                # 3. Check for Auth URL (Only if we aren't already prompting for input)
                if state != "input":
                    is_manual_auth = "Manual Authentication Required" in log_content
                    url_pattern = re.compile(r'(https?://[^\s"<>]+)')

                    for line in reversed(lines[-300:]):
                        if "prelogin.esp" in line:
                            continue
                        match = url_pattern.search(line)
                        if match:
                            found_url = match.group(1)
                            if (
                                "saml" in found_url.lower()
                                or "sso" in found_url.lower()
                                or "login" in found_url.lower()
                                or (is_manual_auth and "http://" in found_url)
                            ):
                                sso_url = found_url
                                state = "auth"
                            logger.debug(
                                f"State transition detected: AUTH | URL: {sso_url[:30]}..."
                            )
                            break
                        else:
                            logger.trace(
                                f"URL rejected (no saml/sso keyword): {found_url}"
                            )
        except Exception as e:
            logger.error(f"Error parsing vpn.log: {e}")
            log_content += f"\n[Error reading log: {e}]"

    return {
        "state": state,
        "url": sso_url,
        "prompt": prompt_msg,
        "input_type": prompt_type,
        "options": input_options,
        "log": log_content,
        "debug": f"State: {state} | Type: {prompt_type}",
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
                logger.error(f"Failed to download logs: {e}")
            return

        if self.path == "/":
            self.path = "/index.html"
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == "/connect":
            try:
                logger.info("Received /connect signal via Web UI")
                with open(FIFO_CONTROL, "w") as f:
                    f.write("START\n")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            except Exception as e:
                logger.error(f"Error triggering start: {e}")
                self.send_error(500, str(e))
            return

        if self.path == "/submit":
            try:
                content_length = int(self.headers.get("Content-Length", 0))
                post_data = self.rfile.read(content_length).decode("utf-8")
                parsed_data = urllib.parse.parse_qs(post_data)

                user_input = ""
                if "callback_url" in parsed_data:
                    user_input = parsed_data["callback_url"][0].strip()
                elif "user_input" in parsed_data:
                    user_input = parsed_data["user_input"][0].strip()

                if user_input:
                    logger.info(f"User submitted input. Length: {len(user_input)}")
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
                    self.send_error(400, "Missing input data")
            except Exception as e:
                logger.error(f"Error submitting code: {e}")
                self.send_error(500, str(e))
            return


if __name__ == "__main__":
    os.chdir("/var/www/html")
    logger.info(f"Python Server Starting on Port {PORT} | Level: {env_level}")

    if not os.path.exists(FIFO_CONTROL):
        os.mkfifo(FIFO_CONTROL)
        os.chmod(FIFO_CONTROL, 0o666)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        httpd.serve_forever()
