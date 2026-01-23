#!/bin/bash
set -e

# 1. Start SOCKS5 Proxy (Port 1080)
echo "Starting Microsocks..."
microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &

# 2. Start Status Dashboard (Port 8000)
# Create a placeholder page initially
cat <<EOF > /var/www/html/index.html
<html><head><meta http-equiv="refresh" content="5"></head>
<body style="font-family:sans-serif;text-align:center;padding:50px;">
<h1>VPN Status: <span style="color:orange;">Booting...</span></h1></body></html>
EOF

python3 -m http.server 8000 --directory /var/www/html > /dev/null 2>&1 &

# 3. Start VPN Service
echo "Starting GlobalProtect Service..."
gpservice &
SERVICE_PID=$!
sleep 2

# 4. Connection Loop (The "Captive Portal" Logic)
echo "Starting Connection Monitor..."
(
    LOG_FILE="/tmp/vpn.log"
    while true; do
        # Try to connect. This blocks until auth is needed or connection succeeds.
        gpclient connect "$VPN_PORTAL" --browser remote --fix-openssl > "$LOG_FILE" 2>&1 &
        CLIENT_PID=$!

        # Monitor the client process
        while kill -0 $CLIENT_PID 2>/dev/null; do
            # Check for Auth URL
            if grep -q "https://" "$LOG_FILE"; then
                AUTH_URL=$(grep -o "https://[^ ]*" "$LOG_FILE" | head -1)

                # Update Web Page to RED with Link
                cat <<EOF > /var/www/html/index.html
<html><head><meta http-equiv="refresh" content="5"></head>
<body style="background:#ffe6e6;font-family:sans-serif;text-align:center;padding:50px;">
<h1 style="color:red;">⚠️ VPN NEEDS LOGIN</h1>
<div style="border:2px solid red;padding:20px;background:white;display:inline-block;">
<h2><a href="$AUTH_URL" target="_blank">CLICK HERE TO AUTHENTICATE</a></h2>
<p>Log in using the new tab, then wait for this page to turn green.</p>
</div><br><br><pre>$(tail -n 5 $LOG_FILE)</pre></body></html>
EOF
            fi

            # Check for Success
            if grep -q "Connected" "$LOG_FILE"; then
                cat <<EOF > /var/www/html/index.html
<html><head><meta http-equiv="refresh" content="60"></head>
<body style="background:#e6fffa;font-family:sans-serif;text-align:center;padding:50px;">
<h1 style="color:green;">✅ VPN CONNECTED</h1>
<p>Proxy active at port 1080</p></body></html>
EOF
            fi
            sleep 2
        done
        sleep 5
    done
) &

# Keep container alive
wait $SERVICE_PID