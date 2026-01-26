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

            # B. Needs Auth (Extract URL)
            elif grep -qE \"https?://.*/.*\" \$LOG_FILE; then

                # Extract LOCAL URL (The 172.x.x.x link)
                LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \$LOG_FILE | tail -1)

                # Resolve to PUBLIC URL using curl's internal redirect parser
                # This hits the internal server ONCE (which kills it) and grabs the redirect header.
                REAL_URL=\$(curl -s -o /dev/null -w \"%{redirect_url}\" \"\$LOCAL_URL\")

                # Fallback: If extraction fails, warn the user.
                if [ -z \"\$REAL_URL\" ]; then
                     # If curl failed, the link is likely already dead or parsing failed.
                     # We display a helpful error instead of the broken 172 link.
                     LINK_HTML=\"<p style='color:red'><strong>Error:</strong> Could not auto-resolve SSO link.</p><p>Please check container logs for the 'Location' header.</p>\"
                else
                     LINK_HTML=\"<a href='\$REAL_URL' target='_blank' class='btn-link'>Click to Login (SSO)</a>\"
                fi

                # Update Dashboard
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
        <h2 style=\"color: #d9534f;\">Authentication Required</h2>

        <h3>Step 1</h3>
        \$LINK_HTML

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