import http.server
import socketserver
import os
import urllib.parse
import sys

PORT = 8001
FIFO_PATH = "/tmp/gp-stdin"


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # redirect root to index.html
        if self.path == "/":
            self.path = "/index.html"
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == "/submit":
            try:
                content_length = int(self.headers["Content-Length"])
                post_data = self.rfile.read(content_length).decode("utf-8")
                parsed_data = urllib.parse.parse_qs(post_data)

                if "callback_url" in parsed_data:
                    callback_value = parsed_data["callback_url"][0].strip()
                    # Print to stderr so it shows in docker logs
                    print(f"Received Callback: {callback_value}", file=sys.stderr)

                    # Write to the Named Pipe
                    # We open in 'w' mode. Since start.sh keeps this pipe open
                    # with a file descriptor, this write happens immediately.
                    with open(FIFO_PATH, "w") as fifo:
                        fifo.write(callback_value + "\n")
                        fifo.flush()

                    self.send_response(200)
                    self.send_header("Content-type", "text/html")
                    self.end_headers()
                    self.wfile.write(
                        b"<html><head><meta http-equiv='refresh' content='2;url=/'></head><body style='font-family:sans-serif;text-align:center;padding:50px;background:#e6fffa;'><h1>Code Sent!</h1><p>Connecting...</p></body></html>"
                    )
                else:
                    self.send_error(400, "No callback_url found")
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
                self.send_error(500, f"Server Error: {e}")


# Serve from the web directory
os.chdir("/var/www/html")
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"Serving Web Interface on port {PORT}", file=sys.stderr)
    httpd.serve_forever()
