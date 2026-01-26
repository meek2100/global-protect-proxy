#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"

# --- HELPER: Write JSON State ---
write_state() {
    STATE="$1"
    URL="$2"
    TEXT="$3"

    # Escape quotes for JSON safely
    SAFE_URL=$(echo "$URL" | sed 's/"/\\"/g')
    SAFE_TEXT=$(echo "$TEXT" | sed 's/"/\\"/g')

    # Grab last 5 lines of log for debug, escape newlines for JSON
    LOG_CONTENT=$(tail -n 5 "$LOG_FILE" 2>/dev/null | awk '{printf "%s\\n", $0}' | sed 's/"/\\"/g')

    cat <<JSON > "$STATUS_FILE.tmp"
{
  "state": "$STATE",
  "url": "$SAFE_URL",
  "link_text": "$SAFE_TEXT",
  "log": "$LOG_CONTENT"
}
JSON
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

echo "=== Container Started ==="

# --- DEBUG: Check Disk Space ---
echo "Checking disk space..."
df -h /var/run || echo "Cannot check disk space"

# --- SETUP: Permissions & Pipes ---
# 1. Force cleanup of old files (Fixes "Disk Full" lock issues)
rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control

# 2. Create Lock File (With Error Check)
if ! touch /var/run/gpservice.lock; then
    echo "CRITICAL ERROR: Could not create lock file. Disk likely full or read-only."
    exit 1
fi
chown gpuser:gpuser /var/run/gpservice.lock

# 3. Create FIFO Pipes
mkfifo /tmp/gp-stdin /tmp/gp-control
chown gpuser:gpuser /tmp/gp-stdin /tmp/gp-control
chmod 666 /tmp/gp-stdin /tmp/gp-control

# 4. Logs
mkdir -p /tmp/gp-logs
touch "$LOG_FILE"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html
# ----------------------------------

# 1. Start Microsocks (Proxy)
echo "Starting Microsocks..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

# 2. Start Web Server
echo "Starting Web Interface..."
# Ensure server.py is running to serve status.json
if [ -f /var/www/html/server.py ]; then
    su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"
else
    echo "WARNING: server.py not found! Did you rebuild?"
fi

# 3. Start VPN Service
echo "Starting GlobalProtect Service..."
su - gpuser -c "xvfb-run -a /usr/bin/gpservice &"
sleep 1

# Stream logs to Docker stdout
tail -f "$LOG_FILE" &

# --- STATE: IDLE ---
# This updates status.json so index.html shows the "Connect" button
write_state "idle" "" ""
echo "State: IDLE. Waiting for user..."

# 4. WAIT FOR USER SIGNAL
# This blocks until you click "Connect"
read _ < /tmp/gp-control

# --- STATE: CONNECTING ---
# Updates UI to show spinner
write_state "connecting" "" ""
echo "State: CONNECTING..."

# 5. Connection Monitor Loop
su - gpuser -c "
    exec 3<> /tmp/gp-stdin
    VPN_PORTAL=\"$VPN_PORTAL\"

    while true; do
        echo \"Attempting connection...\" >> \"$LOG_FILE\"
        gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote <&3 >> \"$LOG_FILE\" 2>&1 &
        CLIENT_PID=\$!

        while kill -0 \$CLIENT_PID 2>/dev/null; do
            # 1. CHECK CONNECTED
            if grep -q \"Connected\" \"$LOG_FILE\"; then
                # --- STATE: CONNECTED ---
                # Manual write inside subshell
                cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"connected\", \"log\": \"VPN Connected Successfully\" }
JSON
                mv $STATUS_FILE.tmp $STATUS_FILE

            # 2. CHECK AUTH REQUIRED
            elif grep -qE \"https?://.*/.*\" \"$LOG_FILE\"; then
                 LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \"$LOG_FILE\" | tail -1)

                 # Resolve URL (Bypass Proxy)
                 REAL_URL=\$(export http_proxy=; export https_proxy=; python3 -c \"
import urllib.request, sys
try:
    with urllib.request.urlopen('\$LOCAL_URL') as r: print(r.geturl())
except: print('')\" 2>/dev/null)

                 if [ -z \"\$REAL_URL\" ]; then
                     REAL_URL=\"\$LOCAL_URL\"
                     LINK_TEXT=\"Internal IP (May Fail)\"
                 else
                     LINK_TEXT=\"Open Login Page (SSO)\"
                 fi

                 # --- STATE: AUTH ---
                 # Manual write inside subshell
                 cat <<JSON > $STATUS_FILE.tmp
{
  \"state\": \"auth\",
  \"url\": \"\$REAL_URL\",
  \"link_text\": \"\$LINK_TEXT\",
  \"log\": \"Waiting for authentication...\"
}
JSON
                 mv $STATUS_FILE.tmp $STATUS_FILE
            fi
            sleep 1
        done
        sleep 5
    done
" &

wait