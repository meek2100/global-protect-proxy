import http.server
import socketserver
import os
import urllib.parse
import sys
import time
import re
import json
import logging

# --- Configuration ---
PORT = 8001
FIFO_STDIN = "/tmp/gp-stdin"
FIFO_CONTROL = "/tmp/gp-control"
LOG_FILE = "/tmp/gp-logs/vpn.log"
MODE_FILE = "/tmp/gp-mode"
DEBUG_LOG = "/tmp/gp-logs/debug_parser.log"

# --- Logging Setup ---
# Define TRACE level (lower than DEBUG)
TRACE_LEVEL_NUM = 5
logging.addLevelName(TRACE_LEVEL_NUM, "TRACE")


def trace(self, message, *args, **kws):
    if self.isEnabledFor(TRACE_LEVEL_NUM):
        self._log(TRACE_LEVEL_NUM, message, args, **kws)


logging.Logger.trace = trace

# Get Level from Env (Default INFO)
env_level = os.getenv("LOG_LEVEL", "INFO").upper()
log_level = getattr(logging, env_level, logging.INFO)
if env_level == "TRACE":
    log_level = TRACE_LEVEL_NUM

logging.basicConfig(
    filename=DEBUG_LOG,
    level=log_level,
    format="[%(asctime)s] [%(levelname)s] [server.py] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)

logger = logging.getLogger()


def get_vpn_state():
    """
    Determines the current state of the VPN.
    Combines coarse process state (MODE_FILE) with fine-grained log parsing.
    """
    state = "idle"

    # 1. Check Coarse Mode
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

    # 2. Parse Logs for Fine-Grained State
    log_content = ""
    sso_url = ""

    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r", errors="replace") as f:
                lines = f.readlines()
                log_content = "".join(lines[-20:])  # Keep last 20 lines for UI

                # Scan for success
                for line in reversed(lines):
                    if "Connected" in line:
                        state = "connected"
                        logger.debug("State transition detected: CONNECTED")
                        return {
                            "state": "connected",
                            "log": "VPN Established Successfully!",
                        }

                # Scan for Auth URL
                url_pattern = re.compile(r'(https?://[^\s"<>]+)')

                # Trace logging for parser logic (Only if LOG_LEVEL=TRACE)
                logger.trace(f"Parsing {len(lines)} lines for URLs...")

                for i, line in enumerate(reversed(lines)):
                    if "prelogin.esp" in line:
                        continue

                    match = url_pattern.search(line)
                    if match:
                        found_url = match.group(1)
                        logger.trace(f"Line -{i}: Potential URL found: {found_url}")

                        if (
                            "saml" in found_url.lower()
                            or "sso" in found_url.lower()
                            or "login" in found_url.lower()
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
        "log": log_content,
        "debug": f"State: {state} | Level: {env_level}",
    }


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # Serve Status API
        if self.path.startswith("/status.json"):
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()

            data = get_vpn_state()
            self.wfile.write(json.dumps(data).encode("utf-8"))
            return

        # Serve Static Files
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

                if "callback_url" in parsed_data:
                    raw_input = parsed_data["callback_url"][0].strip()
                    logger.info(f"User submitted callback. Length: {len(raw_input)}")
                    logger.debug(f"Callback payload: {raw_input[:20]}...")

                    with open(FIFO_STDIN, "w") as fifo:
                        fifo.write(raw_input + "\n")
                        fifo.flush()

                    self.send_response(200)
                    self.send_header("Content-type", "text/html")
                    self.end_headers()
                    self.wfile.write(
                        b"<html><head><meta http-equiv='refresh' content='0;url=/'></head><body>Sent.</body></html>"
                    )
                else:
                    logger.warning("Received /submit without callback_url")
                    self.send_error(400, "Missing callback_url")
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
        # Redirect stderr to avoid cluttering docker logs unless error
        httpd.serve_forever()
