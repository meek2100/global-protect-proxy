#!/bin/bash
set -e

echo "=== Container Started ==="

# --- SETUP: Permissions, Pipes, and Logs ---
rm -f /var/run/gpservice.lock /tmp/gp-stdin
touch /var/run/gpservice.lock
chown gpuser:gpuser /var/run/gpservice.lock

mkfifo /tmp/gp-stdin
chown gpuser:gpuser /tmp/gp-stdin
chmod 600 /tmp/gp-stdin

mkdir -p /tmp/gp-logs
touch /tmp/gp-logs/vpn.log
chown -R gpuser:gpuser /tmp/gp-logs
# -------------------------------------------

# 1. Start Microsocks (Proxy)
echo "Starting Microsocks..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

# 2. Create the Python Web Server (Form Handler)
#    This creates a mini-server that takes your pasted code and writes it to the pipe.
cat <<'EOF' > /var/www/html/server.py
import http.server
import socketserver
import os
import urllib.parse

PORT = 8001
FIFO_PATH = "/tmp/gp-stdin"

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.path = "/index.html"
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == "/submit":
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length).decode('utf-8')
            parsed_data = urllib.parse.parse_qs(post_data)

            if 'callback_url' in parsed_data:
                callback_value = parsed_data['callback_url'][0].strip()
                print(f"Received Callback: {callback_value}")

                try:
                    # Write the code into the Named Pipe
                    with open(FIFO_PATH, 'w') as fifo:
                        fifo.write(callback_value + "\n")

                    self.send_response(200)
                    self.send_header("Content-type", "text/html")
                    self.end_headers()
                    self.wfile.write(b"<html><head><meta http-equiv='refresh' content='2;url=/'></head><body style='font-family:sans-serif;text-align:center;padding:50px;background:#e6fffa;'><h1>Code Sent!</h1><p>Checking connection...</p></body></html>")
                except Exception as e:
                    self.send_error(500, f"Error writing to FIFO: {e}")
            else:
                self.send_error(400, "No callback_url found")

os.chdir("/var/www/html")
# Allow address reuse to prevent 'Address already in use' on restarts
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"Serving Web Interface on port {PORT}")
    httpd.serve_forever()
EOF

# 3. Create Initial Loading Page
echo "<html><head><meta http-equiv='refresh' content='5'></head><body style='font-family:sans-serif;text-align:center;padding:50px;'><h1>VPN Status: <span style='color:orange;'>Booting...</span></h1><p>Waiting for gpclient...</p></body></html>" > /var/www/html/index.html
chown -R gpuser:gpuser /var/www/html

# 4. Start the Web Server (Background)
echo "Starting Web Interface..."
su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"

# 5. Start VPN Service (Headless Display)
echo "Starting GlobalProtect Service..."
su - gpuser -c "xvfb-run -a /usr/bin/gpservice &"
sleep 5

# --- Stream logs to Docker Output (for debugging) ---
tail -f /tmp/gp-logs/vpn.log &

# 6. Connection Monitor Loop
echo "Starting Connection Monitor..."
su - gpuser -c "
    LOG_FILE=\"/tmp/gp-logs/vpn.log\"
    VPN_PORTAL=\"$VPN_PORTAL\"

    while true; do
        echo \"Attempting connection to \$VPN_PORTAL...\" >> \$LOG_FILE

        # Connect using the FIFO for input
        gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote < /tmp/gp-stdin >> \$LOG_FILE 2>&1 &
        CLIENT_PID=\$!

        # Monitor the active client process
        while kill -0 \$CLIENT_PID 2>/dev/null; do

            # A. Check for 'Connected' State
            if grep -q \"Connected\" \$LOG_FILE; then
                cat <<HTML > /var/www/html/index.html
<html><head><meta http-equiv=\"refresh\" content=\"60\"></head>
<body style=\"background:#e6fffa;font-family:sans-serif;text-align:center;padding:50px;\">
<h1 style=\"color:green;\">✅ VPN CONNECTED</h1>
<p>Proxy running on port 1080</p>
<p><small>Refreshes every 60s</small></p>
</body></html>
HTML

            # B. Check for Authentication Request (HTTP or HTTPS)
            #    We use grep -E to catch http OR https
            elif grep -qE \"https?://.*/.*\" \$LOG_FILE; then

                # 1. Extract the LOCAL internal link (e.g., http://172.22.0.2:41959/...)
                LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \$LOG_FILE | tail -1)

                # 2. RESOLVE the Real SSO Link
                #    We curl the local link to get the 'Location:' redirect header.
                #    This turns the unreachable internal IP into the reachable public SSO URL.
                REAL_URL=\$(curl -s -I \"\$LOCAL_URL\" | grep -i \"Location:\" | awk '{print \$2}' | tr -d '\r')

                # Fallback: If extraction fails, show local URL (better than nothing)
                if [ -z \"\$REAL_URL\" ]; then
                    REAL_URL=\"\$LOCAL_URL\"
                fi

                # 3. Generate the Dashboard
                cat <<HTML > /var/www/html/index.html
<html>
<head>
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <style>
        body { font-family: sans-serif; text-align: center; padding: 40px; background: #fff0f0; }
        .card { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 600px; margin: 0 auto; }
        input[type=text] { width: 100%; padding: 12px; margin: 10px 0; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
        input[type=submit] { width: 100%; padding: 12px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; font-weight: bold; }
        input[type=submit]:hover { background: #0056b3; }
        .btn-link { display: inline-block; padding: 12px 24px; background: #28a745; color: white; text-decoration: none; border-radius: 4px; font-weight: bold; margin-bottom: 20px; }
        .debug { text-align: left; background: #eee; padding: 10px; margin-top: 30px; overflow-x: auto; font-size: 12px; }
    </style>
</head>
<body>
    <div class=\"card\">
        <h2 style=\"color: #d9534f;\">⚠️ Authentication Required</h2>

        <h3>Step 1</h3>
        <a href=\"\$REAL_URL\" target=\"_blank\" class=\"btn-link\">Click to Login (SSO)</a>

        <h3>Step 2</h3>
        <p>After logging in, copy the full URL (starting with <code>globalprotectcallback:</code>) and paste it here:</p>

        <form action=\"/submit\" method=\"POST\">
            <input type=\"text\" name=\"callback_url\" placeholder=\"Paste callback code here...\" required autocomplete=\"off\">
            <input type=\"submit\" value=\"Submit Code\">
        </form>
    </div>

    <div class=\"debug\">
        <strong>Debug Log:</strong><br>
        \$(tail -n 3 \$LOG_FILE)
    </div>
</body>
</html>
HTML
            fi

            sleep 2
        done

        echo \"gpclient process exited. Retrying in 5 seconds...\" >> \$LOG_FILE
        sleep 5
    done
" &

wait