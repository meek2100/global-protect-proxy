#!/bin/bash
set -e

echo "=== Container Started ==="

# --- SETUP: Permissions ---
# Clean up stale lock
rm -f /var/run/gpservice.lock
# Pre-create lock file for gpuser
touch /var/run/gpservice.lock
chown gpuser:gpuser /var/run/gpservice.lock

# Ensure log directory and file exist
mkdir -p /tmp/gp-logs
touch /tmp/gp-logs/vpn.log
chown -R gpuser:gpuser /tmp/gp-logs
# --------------------------

# 1. Start Microsocks (Proxy)
echo "Starting Microsocks..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

# 2. Start Status Dashboard
echo "Initializing Dashboard..."
cat <<EOF > /var/www/html/index.html
<html><head><meta http-equiv="refresh" content="5"></head>
<body style="font-family:sans-serif;text-align:center;padding:50px;">
<h1>VPN Status: <span style="color:orange;">Booting...</span></h1></body></html>
EOF
chown gpuser:gpuser /var/www/html/index.html

echo "Starting Dashboard on 8001..."
su - gpuser -c "python3 -m http.server 8001 --directory /var/www/html > /dev/null 2>&1 &"

# 3. Start VPN Service (Headless)
echo "Starting GlobalProtect Service..."
# xvfb-run creates the fake display required by the GUI
su - gpuser -c "xvfb-run -a /usr/bin/gpservice &"

# Wait for service to stabilize
sleep 5

# --- CRITICAL FIX: Stream logs to Docker Output ---
# This allows you to see 'Please visit https://...' in your terminal
tail -f /tmp/gp-logs/vpn.log &
# --------------------------------------------------

# 4. Connection Loop
echo "Starting Connection Monitor..."
su - gpuser -c "
    LOG_FILE=\"/tmp/gp-logs/vpn.log\"
    VPN_PORTAL=\"$VPN_PORTAL\"

    while true; do
        echo \"Attempting connection to \$VPN_PORTAL...\" >> \$LOG_FILE

        # Connect using the flags you confirmed work
        gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote >> \$LOG_FILE 2>&1 &
        CLIENT_PID=\$!

        # Monitor the active client process
        while kill -0 \$CLIENT_PID 2>/dev/null; do
            # Check for Auth URL (Magic Link)
            if grep -q \"https://\" \$LOG_FILE; then
                AUTH_URL=\$(grep -o \"https://[^ ]*\" \$LOG_FILE | head -1)

                cat <<HTML > /var/www/html/index.html
<html><head><meta http-equiv=\"refresh\" content=\"5\"></head>
<body style=\"background:#ffe6e6;font-family:sans-serif;text-align:center;padding:50px;\">
<h1 style=\"color:red;\">⚠️ VPN NEEDS LOGIN</h1>
<div style=\"border:2px solid red;padding:20px;background:white;display:inline-block;\">
<h2><a href=\"\$AUTH_URL\" target=\"_blank\">CLICK HERE TO AUTHENTICATE</a></h2>
</div><br><br><pre>\$(tail -n 5 \$LOG_FILE)</pre></body></html>
HTML
            fi

            # Check for Success
            if grep -q \"Connected\" \$LOG_FILE; then
                cat <<HTML > /var/www/html/index.html
<html><head><meta http-equiv=\"refresh\" content=\"60\"></head>
<body style=\"background:#e6fffa;font-family:sans-serif;text-align:center;padding:50px;\">
<h1 style=\"color:green;\">✅ VPN CONNECTED</h1>
<p>Proxy active at port 1080</p></body></html>
HTML
            fi
            sleep 2
        done

        echo \"gpclient exited. Retrying in 5 seconds...\" >> \$LOG_FILE
        sleep 5
    done
" &

# Keep container alive
wait