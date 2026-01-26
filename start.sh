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

# --- INITIALIZATION ---
echo "=== Container Started ==="
mkdir -p /tmp/gp-logs
touch "$LOG_FILE"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

# Permissions & Pipes
rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control
mkfifo /tmp/gp-stdin /tmp/gp-control
chown gpuser:gpuser /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control
chmod 666 /tmp/gp-stdin /tmp/gp-control

# 1. Start Services
echo "Starting Microsocks..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

echo "Starting Web Interface..."
# Ensure server.py is running to serve the static files and status.json
su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"

echo "Starting GlobalProtect Service..."
su - gpuser -c "xvfb-run -a /usr/bin/gpservice &"
sleep 1

# Stream logs
tail -f "$LOG_FILE" &

# --- STATE: IDLE ---
write_state "idle" "" ""
echo "State: IDLE. Waiting for user..."

# Wait for "Connect" signal from Python
read _ < /tmp/gp-control

# --- STATE: CONNECTING ---
write_state "connecting" "" ""
echo "State: CONNECTING..."

# Start Connection Loop
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
                # We use a python one-liner to call the write_state logic purely via file overwrite
                # simpler to just overwrite the file here manually since we are in a sub-shell
                cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"connected\", \"log\": \"VPN Connected Successfully\" }
JSON
                mv $STATUS_FILE.tmp $STATUS_FILE

            # 2. CHECK AUTH REQUIRED
            elif grep -qE \"https?://.*/.*\" \"$LOG_FILE\"; then
                 LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \"$LOG_FILE\" | tail -1)

                 # Resolve URL
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