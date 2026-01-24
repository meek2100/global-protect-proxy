#!/bin/bash
set -e

echo "=== Container Started ==="

# --- FIX: Permissions for Lock File ---
# The gpservice binary tries to write to /var/run/gpservice.lock
# Since we run as 'gpuser', we must pre-create this file and give ownership.
touch /var/run/gpservice.lock
chown gpuser:gpuser /var/run/gpservice.lock
# --------------------------------------

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

# 3. Start VPN Service
#    We run this as gpuser. It will now be able to write to /var/run/gpservice.lock
echo "Starting GlobalProtect Service..."
su - gpuser -c "gpservice &"

# Wait briefly for service to initialize
sleep 3

# 4. Connection Loop
echo "Starting Connection Monitor..."
su - gpuser -c "
    LOG_FILE=\"/tmp/gp-logs/vpn.log\"
    VPN_PORTAL=\"$VPN_PORTAL\"

    # Ensure log file exists
    touch \$LOG_FILE

    while true; do
        # Connect
        gpclient connect \"\$VPN_PORTAL\" --browser remote --fix-openssl > \"\$LOG_FILE\" 2>&1 &
        CLIENT_PID=\$!

        # Monitor loop
        while kill -0 \$CLIENT_PID 2>/dev/null; do
            # Check for Auth URL (Magic Link)
            if grep -q \"https://\" \"\$LOG_FILE\"; then
                AUTH_URL=\$(grep -o \"https://[^ ]*\" \"\$LOG_FILE\" | head -1)

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
            if grep -q \"Connected\" \"\$LOG_FILE\"; then
                cat <<HTML > /var/www/html/index.html
<html><head><meta http-equiv=\"refresh\" content=\"60\"></head>
<body style=\"background:#e6fffa;font-family:sans-serif;text-align:center;padding:50px;\">
<h1 style=\"color:green;\">✅ VPN CONNECTED</h1>
<p>Proxy active at port 1080</p></body></html>
HTML
            fi
            sleep 2
        done
        sleep 5
    done
" &

# Keep container alive
wait