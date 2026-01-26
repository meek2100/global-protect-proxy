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

    # Grab last 20 lines (expanded from 5) for better debugging
    LOG_CONTENT=$(tail -n 20 "$LOG_FILE" 2>/dev/null | awk '{printf "%s\\n", $0}' | sed 's/"/\\"/g')

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
rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control

# Create Lock File
if ! touch /var/run/gpservice.lock; then
    echo "CRITICAL ERROR: Could not create lock file."
    exit 1
fi
chown gpuser:gpuser /var/run/gpservice.lock

# Create Pipes
mkfifo /tmp/gp-stdin /tmp/gp-control
chown gpuser:gpuser /tmp/gp-stdin /tmp/gp-control
chmod 666 /tmp/gp-stdin /tmp/gp-control

# Logs
mkdir -p /tmp/gp-logs
touch "$LOG_FILE"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

# 1. Start Services
echo "Starting Microsocks..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

echo "Starting Web Interface..."
if [ -f /var/www/html/server.py ]; then
    su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"
else
    echo "WARNING: server.py missing!"
fi

echo "Starting GlobalProtect Service..."
su - gpuser -c "xvfb-run -a /usr/bin/gpservice &"
sleep 1

# Stream logs
tail -f "$LOG_FILE" &

# --- STATE: IDLE ---
write_state "idle" "" ""
echo "State: IDLE. Waiting for user..."

# 2. WAIT FOR USER SIGNAL
read _ < /tmp/gp-control

# --- STATE: CONNECTING ---
write_state "connecting" "" ""
echo "State: CONNECTING..."

# 3. Connection Loop
su - gpuser -c "
    exec 3<> /tmp/gp-stdin
    VPN_PORTAL=\"$VPN_PORTAL\"

    # --- CRITICAL FIX: Clear log on new run to prevent stale URL detection ---
    > \"$LOG_FILE\"

    while true; do
        echo \"Attempting connection...\" >> \"$LOG_FILE\"
        gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote <&3 >> \"$LOG_FILE\" 2>&1 &
        CLIENT_PID=\$!

        while kill -0 \$CLIENT_PID 2>/dev/null; do
            # 1. CHECK CONNECTED
            if grep -q \"Connected\" \"$LOG_FILE\"; then
                cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"connected\", \"log\": \"VPN Connected Successfully\" }
JSON
                mv $STATUS_FILE.tmp $STATUS_FILE

            # 2. CHECK AUTH REQUIRED
            elif grep -qE \"https?://.*/.*\" \"$LOG_FILE\"; then
                 LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \"$LOG_FILE\" | tail -1)

                 # --- VERBOSE RESOLUTION SCRIPT ---
                 # We capture stderr to log file so you can see WHY it fails
                 REAL_URL=\$(export http_proxy=; export https_proxy=; python3 -c \"
import urllib.request, sys
try:
    url = '\$LOCAL_URL'
    print(f'DEBUG: Resolving {url}...', file=sys.stderr)
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=5) as r:
        final_url = r.geturl()
        print(f'DEBUG: Resolved to {final_url}', file=sys.stderr)
        print(final_url)
except Exception as e:
    print(f'DEBUG_ERROR: {e}', file=sys.stderr)
\" 2>> \"$LOG_FILE\")

                 if [ -z \"\$REAL_URL\" ]; then
                     REAL_URL=\"\$LOCAL_URL\"
                     LINK_TEXT=\"Internal IP (May Fail)\"
                 else
                     LINK_TEXT=\"Open Login Page (SSO)\"
                 fi

                 # --- STATE: AUTH ---
                 # Note: We append the debug info into the log field automatically via write_state logic
                 # but here we manually construct it to ensure atomicity
                 LOG_CONTENT=\$(tail -n 20 \"$LOG_FILE\" | awk '{printf \"%s\\\\n\", \$0}' | sed 's/\"/\\\\\"/g')

                 cat <<JSON > $STATUS_FILE.tmp
{
  \"state\": \"auth\",
  \"url\": \"\$REAL_URL\",
  \"link_text\": \"\$LINK_TEXT\",
  \"log\": \"\$LOG_CONTENT\"
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