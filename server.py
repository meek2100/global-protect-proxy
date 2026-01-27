import http.server
import socketserver
import os
import urllib.parse
import sys
import time
import re
import json

# --- Configuration ---
PORT = 8001
FIFO_STDIN = "/tmp/gp-stdin"  # Pipe to send keystrokes (SAML code) to gpclient
FIFO_CONTROL = "/tmp/gp-control"  # Pipe to signal entrypoint.sh to run gpclient
LOG_FILE = "/tmp/gp-logs/vpn.log"
MODE_FILE = (
    "/tmp/gp-mode"  # Simple state file: 'idle' or 'active' (managed by entrypoint.sh)
)
DEBUG_LOG = "/tmp/gp-logs/debug_parser.log"


def log_debug(msg):
    """Writes to the debug log with a timestamp."""
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ')}] {msg}\n")
    except Exception as e:
        print(f"Failed to write debug log: {e}", file=sys.stderr)


def get_vpn_state():
    """
    Determines the current state of the VPN by combining:
    1. The coarse process state (from MODE_FILE)
    2. The fine-grained log content (from LOG_FILE)
    """
    state = "idle"

    # 1. Check Coarse Mode (written by entrypoint.sh)
    if os.path.exists(MODE_FILE):
        try:
            with open(MODE_FILE, "r") as f:
                mode = f.read().strip()
                if mode == "active":
                    state = "connecting"
        except Exception:
            pass

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
                        return {
                            "state": "connected",
                            "log": "VPN Established Successfully!",
                        }

                # Scan for Auth URL (Capture the last one found)
                # Regex looks for http/https URLs, excluding common false positives
                url_pattern = re.compile(r'(https?://[^\s"<>]+)')
                for line in reversed(lines):
                    if "prelogin.esp" in line:
                        continue  # Skip internal prelogin calls

                    match = url_pattern.search(line)
                    if match:
                        found_url = match.group(1)
                        # Basic validation to ensure it looks like an SSO link
                        if (
                            "saml" in found_url.lower()
                            or "sso" in found_url.lower()
                            or "login" in found_url.lower()
                        ):
                            sso_url = found_url
                            state = "auth"
                            break
        except Exception as e:
            log_content += f"\n[Error reading log: {e}]"

    return {
        "state": state,
        "url": sso_url,
        "log": log_content,
        "debug": f"Parsed State: {state} | URL Found: {bool(sso_url)}",
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
        # --- Handle "Connect" Signal ---
        if self.path == "/connect":
            try:
                log_debug("Received /connect signal via Web UI")
                with open(FIFO_CONTROL, "w") as f:
                    f.write("START\n")

                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            except Exception as e:
                log_debug(f"Error triggering start: {e}")
                self.send_error(500, str(e))
            return

        # --- Handle "Callback" Submission ---
        if self.path == "/submit":
            try:
                content_length = int(self.headers.get("Content-Length", 0))
                post_data = self.rfile.read(content_length).decode("utf-8")
                parsed_data = urllib.parse.parse_qs(post_data)

                if "callback_url" in parsed_data:
                    raw_input = parsed_data["callback_url"][0].strip()
                    log_debug(
                        f"User submitted callback: {raw_input[:20]}..."
                    )  # Log partial for privacy

                    # sanitize: Handle "globalprotect://" prefix if pasted directly
                    final_code = raw_input
                    if raw_input.startswith("globalprotect://"):
                        # Pass the full string; gpclient often expects the full protocol string
                        # if it is a callback.
                        pass

                    with open(FIFO_STDIN, "w") as fifo:
                        fifo.write(final_code + "\n")
                        fifo.flush()

                    self.send_response(200)
                    self.send_header("Content-type", "text/html")
                    self.end_headers()
                    self.wfile.write(
                        b"<html><head><meta http-equiv='refresh' content='0;url=/'></head><body>Sent.</body></html>"
                    )
                else:
                    self.send_error(400, "Missing callback_url")
            except Exception as e:
                log_debug(f"Error submitting code: {e}")
                self.send_error(500, str(e))
            return


# --- Main Execution ---
if __name__ == "__main__":
    os.chdir("/var/www/html")
    log_debug("Python Server Starting on Port 8001")

    # Ensure pipes exist (fallback if entrypoint.sh hasn't made them yet)
    if not os.path.exists(FIFO_CONTROL):
        os.mkfifo(FIFO_CONTROL)
        os.chmod(FIFO_CONTROL, 0o666)

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        print(f"Serving on port {PORT}", file=sys.stderr)
        httpd.serve_forever()
