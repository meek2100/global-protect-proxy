#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"

# --- GATEWAY SETUP (Run as Root) ---
echo "=== Network Setup ==="
# Enable IP Forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Configure NAT/Masquerade for Gateway Mode
# Traffic leaving via tun0 (VPN) should be masqueraded
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
# Allow forwarding between LAN (eth0) and VPN (tun0)
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "NAT and Forwarding configured."

# --- HELPER: Write JSON State ---
write_state() {
    STATE="$1"
    URL="$2"
    TEXT="$3"

    # Escape quotes for JSON safely
    SAFE_URL=$(echo "$URL" | sed 's/"/\\"/g')
    SAFE_TEXT=$(echo "$TEXT" | sed 's/"/\\"/g')

    # Grab last 20 lines for better debugging
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
# We export the VPN_PORTAL variable so the inner shell can see it
export VPN_PORTAL

su - gpuser -c "
    exec 3<> /tmp/gp-stdin

    # CRITICAL FIX: Clear log on new run to prevent stale URL detection
    > \"$LOG_FILE\"

    while true; do
        echo \"Attempting connection...\" >> \"$LOG_FILE\"

        # --- TTY FIX: Use 'script' to fake a TTY ---
        # We construct the command carefully to avoid quoting issues
        CMD=\"gpclient --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote\"

        # script -q (quiet) -c (command) /dev/null (output sink)
        # We pipe the FIFO (FD 3) into script's stdin, which forwards to the PTY
        script -q -c \"\$CMD\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
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