#!/bin/bash
set -e

echo "=== Container Started ==="

# --- SETUP: Permissions & Pipes ---
rm -f /var/run/gpservice.lock /tmp/gp-stdin
touch /var/run/gpservice.lock
chown gpuser:gpuser /var/run/gpservice.lock

mkfifo /tmp/gp-stdin
chown gpuser:gpuser /tmp/gp-stdin
chmod 600 /tmp/gp-stdin

mkdir -p /tmp/gp-logs
touch /tmp/gp-logs/vpn.log
chown -R gpuser:gpuser /tmp/gp-logs
# ----------------------------------

# 1. Start Microsocks (Proxy)
echo "Starting Microsocks..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

# 2. Create Initial Loading Page
echo "<html><head><meta http-equiv='refresh' content='5'></head><body style='font-family:sans-serif;text-align:center;padding:50px;'><h1>VPN Status: <span style='color:orange;'>Booting...</span></h1><p>Waiting for gpclient...</p></body></html>" > /var/www/html/index.html
chown -R gpuser:gpuser /var/www/html

# 3. Start the Web Server
echo "Starting Web Interface..."
su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"

# 4. Start VPN Service
echo "Starting GlobalProtect Service..."
su - gpuser -c "xvfb-run -a /usr/bin/gpservice &"
sleep 5

# --- Stream logs to Docker Output ---
tail -f /tmp/gp-logs/vpn.log &

# 5. Connection Monitor Loop
echo "Starting Connection Monitor..."
su - gpuser -c "
    exec 3<> /tmp/gp-stdin

    LOG_FILE=\"/tmp/gp-logs/vpn.log\"
    VPN_PORTAL=\"$VPN_PORTAL\"

    while true; do
        echo \"Attempting connection to \$VPN_PORTAL...\" >> \$LOG_FILE

        # Connect using the persistent pipe (fd 3)
        gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote <&3 >> \$LOG_FILE 2>&1 &
        CLIENT_PID=\$!

        # Monitor the active client process
        while kill -0 \$CLIENT_PID 2>/dev/null; do

            # A. Connected
            if grep -q \"Connected\" \$LOG_FILE; then
                cat <<HTML > /var/www/html/index.html
<html><head><meta http-equiv=\"refresh\" content=\"60\"></head>
<body style=\"background:#e6fffa;font-family:sans-serif;text-align:center;padding:50px;\">
<h1 style=\"color:green;\">VPN CONNECTED</h1>
<p>Proxy running on port 1080</p>
<p><small>Refreshes every 60s</small></p>
</body></html>
HTML

            # B. Needs Auth (Resolve URL)
            elif grep -qE \"https?://.*/.*\" \$LOG_FILE; then

                # Extract LOCAL URL
                LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \$LOG_FILE | tail -1)

                # === DEBUG BLOCK ===
                # 1. Log what we found
                echo \"DEBUG: Found Internal URL: \$LOCAL_URL\" >> \$LOG_FILE

                # 2. Attempt Resolution with Error Capture
                # We intentionally unset http_proxy here to ensure we don't hit microsocks
                REAL_URL=\$(export http_proxy=; export https_proxy=; python3 -c \"
import urllib.request
import sys
try:
    url = '\$LOCAL_URL'
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as response:
        print(response.geturl())
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
\" 2>> \$LOG_FILE)

                # 3. Log the Result
                if [ -z \"\$REAL_URL\" ]; then
                     echo \"DEBUG: Resolution FAILED. See stderr above.\" >> \$LOG_FILE
                     LINK_TEXT=\"Click to Login (Internal IP - Might Fail)\"
                     REAL_URL=\"\$LOCAL_URL\"
                else
                     echo \"DEBUG: Resolution SUCCESS: \$REAL_URL\" >> \$LOG_FILE
                     LINK_TEXT=\"Click to Login (SSO)\"
                fi
                # ===================

                # Update Dashboard
                cat <<HTML > /var/www/html/index.html
<html>
<head>
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <style>
        body { font-family: sans-serif; text-align: center; padding: 40px; background: #fff0f0; }
        .card { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 600px; margin: 0 auto; }
        .btn-link { display: inline-block; padding: 12px 24px; background: #28a745; color: white; text-decoration: none; border-radius: 4px; font-weight: bold; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class=\"card\">
        <h2 style=\"color: #d9534f;\">Authentication Required</h2>

        <h3>Step 1</h3>
        <a href=\"\$REAL_URL\" target=\"_blank\" class=\"btn-link\">\$LINK_TEXT</a>

        <h3>Step 2</h3>
        <p>After logging in, copy the full URL (starting with <code>globalprotectcallback:</code>) and paste it here:</p>

        <form action=\"/submit\" method=\"POST\">
            <input type=\"text\" name=\"callback_url\" placeholder=\"Paste callback code here...\" required autocomplete=\"off\">
            <input type=\"submit\" value=\"Submit Code\">
        </form>
    </div>
    <div style=\"text-align:left; background:#eee; padding:10px; margin-top:30px; overflow-x:auto;\">
        <strong>Debug Log:</strong><br>
        <pre>\$(tail -n 10 \$LOG_FILE)</pre>
    </div>
</body>
</html>
HTML
            fi

            sleep 2
        done
        sleep 5
    done
" &

wait