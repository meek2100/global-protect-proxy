# File: server.py
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
from collections import deque
from pathlib import Path
from typing import List, Any, Optional, TypedDict

# --- Configuration ---
PORT = 8001
FIFO_STDIN = Path("/tmp/gp-stdin")
FIFO_CONTROL = Path("/tmp/gp-control")
CLIENT_LOG = Path("/tmp/gp-logs/gp-client.log")
MODE_FILE = Path("/tmp/gp-mode")
SERVICE_LOG = Path("/tmp/gp-logs/gp-service.log")

# --- Logging Setup ---
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "DEBUG").upper(),
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
    handlers=[
        logging.FileHandler(SERVICE_LOG),
        logging.StreamHandler(sys.stderr),
    ],
)
logger = logging.getLogger()

last_known_state: Optional[str] = None


class VPNState(TypedDict):
    """Type definition for the VPN state response."""

    state: str
    url: str
    prompt: str
    input_type: str
    options: List[str]
    error: str
    log: str
    debug_mode: bool
    vpn_mode: str


def strip_ansi(text: str) -> str:
    """
    Aggressively remove ANSI escape sequences to reveal pure text.
    Handles colors, cursor movements, and line clearing.
    """
    ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
    return ansi_escape.sub("", text)


def get_vpn_state() -> VPNState:
    """
    Parse the VPN log to determine the current state of the connection process.

    Returns:
        VPNState: A dictionary containing the current status, prompts, and debug logs.
    """
    global last_known_state
    current_state = "idle"
    is_debug = os.getenv("LOG_LEVEL", "INFO").upper() in ["DEBUG", "TRACE"]
    vpn_mode = os.getenv("VPN_MODE", "standard")

    # 1. Check Mode File
    if MODE_FILE.exists():
        try:
            content = MODE_FILE.read_text().strip()
            if content == "active":
                current_state = "connecting"
            elif content == "idle":
                return {
                    "state": "idle",
                    "url": "",
                    "prompt": "",
                    "input_type": "text",
                    "options": [],
                    "error": "",
                    "log": "Ready.",
                    "debug_mode": is_debug,
                    "vpn_mode": vpn_mode,
                }
        except Exception:
            pass

    log_content = ""
    sso_url = ""
    prompt_msg = ""
    prompt_type = "text"
    input_options: List[str] = []
    error_msg = ""

    # 2. Parse Logs (Optimized with Seek)
    if CLIENT_LOG.exists():
        try:
            file_size = CLIENT_LOG.stat().st_size
            with open(CLIENT_LOG, "r", errors="replace") as f:
                # Optimization: Only read the last 64KB to avoid O(N) on large logs
                if file_size > 65536:
                    f.seek(file_size - 65536)
                    f.readline()  # Discard partial line

                lines = list(deque(f, maxlen=300))
                log_content = "".join(lines)
                clean_lines = [strip_ansi(line).strip() for line in lines[-100:]]

                # Determine State
                for line in reversed(clean_lines):
                    if "Connected" in line and "to" in line:
                        current_state = "connected"
                        break

                if current_state != "connected":
                    for line in reversed(clean_lines):
                        if "Login failed" in line or "GP response error" in line:
                            current_state = "error"
                            if "512" in line:
                                error_msg = "Gateway Rejected Connection (Error 512). Check Gateway selection."
                            else:
                                error_msg = line
                            break

                if current_state not in ["connected", "error"]:
                    for line in reversed(clean_lines):
                        if "Which gateway do you want to connect to" in line:
                            current_state = "input"
                            prompt_msg = "Select Gateway"
                            prompt_type = "select"
                            gateway_regex = re.compile(
                                r"(?:>|\s)*([A-Za-z0-9\-\.]+\s+\([A-Za-z0-9\-\.]+\))"
                            )
                            seen = set()
                            for scan_line in clean_lines:
                                m = gateway_regex.search(scan_line)
                                if m:
                                    opt = m.group(1).strip()
                                    if opt not in seen and "Which gateway" not in opt:
                                        seen.add(opt)
                                        input_options.append(opt)
                            break

                        if "password:" in line.lower():
                            current_state = "input"
                            prompt_msg = "Enter Password"
                            prompt_type = "password"
                            break

                        if "username:" in line.lower():
                            current_state = "input"
                            prompt_msg = "Enter Username"
                            prompt_type = "text"
                            break

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
        "debug_mode": is_debug,
        "vpn_mode": vpn_mode,
    }


class Handler(http.server.SimpleHTTPRequestHandler):
    """
    Custom HTTP Request Handler for the VPN Web UI.
    Handles API endpoints for status, connections, and log downloads.
    """

    def log_message(self, format: str, *args: Any) -> None:
        """Redirect default HTTP logs to the unified logger."""
        logger.info("%s - - %s", self.client_address[0], format % args)

    def do_GET(self) -> None:
        """Handle GET requests."""
        if self.path.startswith("/status.json"):
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(json.dumps(get_vpn_state()).encode("utf-8"))
            return

        if self.path == "/download_logs":
            # Security Check: Only allow download if debug is enabled
            if os.getenv("LOG_LEVEL", "INFO").upper() not in ["DEBUG", "TRACE"]:
                self.send_error(403, "Debug mode required to download logs.")
                return

            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header(
                    "Content-Disposition", "attachment; filename=vpn_full_debug.log"
                )
                self.end_headers()

                self.wfile.write(b"=== SERVICE LOG (Wrapper/UI) ===\n\n")
                if SERVICE_LOG.exists():
                    with open(SERVICE_LOG, "rb") as f:
                        shutil.copyfileobj(f, self.wfile)

                self.wfile.write(b"\n\n=== CLIENT LOG (GlobalProtect) ===\n\n")
                if CLIENT_LOG.exists():
                    with open(CLIENT_LOG, "rb") as f:
                        shutil.copyfileobj(f, self.wfile)
            except Exception:
                pass
            return

        if self.path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self) -> None:
        """Handle POST requests for connection control."""
        if self.path == "/connect":
            logger.info("User requested Connection")
            subprocess.run(["sudo", "pkill", "gpclient"], stderr=subprocess.DEVNULL)
            time.sleep(0.5)
            try:
                with open(FIFO_CONTROL, "w") as f:
                    f.write("START\n")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            except Exception:
                self.send_error(500, "Failed to start")
            return

        if self.path == "/disconnect":
            logger.info("User requested Disconnect")
            subprocess.run(["sudo", "pkill", "gpclient"], stderr=subprocess.DEVNULL)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if self.path == "/submit":
            try:
                length = int(self.headers.get("Content-Length", 0))
                data = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))
                user_input = (
                    data.get("callback_url", [""])[0] or data.get("user_input", [""])[0]
                )

                if user_input:
                    logger.info(f"User submitted input (Length: {len(user_input)})")
                    with open(FIFO_STDIN, "w") as fifo:
                        fifo.write(user_input.strip() + "\n")
                        fifo.flush()
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"OK")
                else:
                    self.send_error(400, "Empty input")
            except Exception as e:
                logger.error(f"Input error: {e}")
                self.send_error(500, str(e))
            return


if __name__ == "__main__":
    os.chdir("/var/www/html")
    if not FIFO_CONTROL.exists():
        os.mkfifo(FIFO_CONTROL)
        os.chmod(FIFO_CONTROL, 0o666)

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("", PORT), Handler) as httpd:
        logger.info(f"Server listening on {PORT}")
        httpd.serve_forever()
