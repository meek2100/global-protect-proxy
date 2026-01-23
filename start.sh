#!/bin/bash
set -e

# 1. Start SOCKS Proxy
echo "Starting Microsocks..."
microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &

# 2. Start a Status Dashboard (Python HTTP Server)
# This will serve a page at http://<VM-IP>:8000
mkdir -p /var/www/html
echo "<html><h1>VPN Starting...</h1></html>" > /var/www/html/index.html
cd /var/www/html
python3 -m http.server 8000 &

# 3. Start VPN Service
echo "Starting GlobalProtect Service..."
gpservice &
SERVICE_PID=$!
sleep 2

# 4. Connect Loop with "Captive" Status Page
echo "Initializing Connection..."

# Generate the Auth URL but capture it to a file so we can show it on the web page
# Note: This is a best-effort wrapper.
gpclient connect "$VPN_PORTAL" --browser remote --fix-openssl > /tmp/vpn.log 2>&1 &
CLIENT_PID=$!

# Monitor the log for the Auth URL and update index.html
(
    while true; do
        if grep -q "https://" /tmp/vpn.log; then
            AUTH_URL=$(grep -o "https://[^ ]*" /tmp/vpn.log | head -1)
            echo "<html><head><meta http-equiv='refresh' content='5'></head><body>" > /var/www/html/index.html
            echo "<h1>⚠️ VPN Action Required</h1>" >> /var/www/html/index.html
            echo "<p>The VPN needs you to login. Click the link below to authenticate on your laptop:</p>" >> /var/www/html/index.html
            echo "<h2><a href='$AUTH_URL' target='_blank'>CLICK HERE TO LOGIN</a></h2>" >> /var/www/html/index.html
            echo "<pre>$(tail -n 10 /tmp/vpn.log)</pre></body></html>" >> /var/www/html/index.html
        fi
        sleep 5
    done
) &

# Wait for the client to finish (it usually stays running)
wait $CLIENT_PID