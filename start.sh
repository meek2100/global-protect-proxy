#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"

# --- GATEWAY SETUP (Run as Root) ---
echo "=== Network Setup ==="

# 1. Smart IP Forwarding Check
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo "IP Forwarding is already enabled (via docker-compose)."
else
    echo "Attempting to enable IP Forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward || echo "WARNING: Could not write to ip_forward. Ensure 'sysctls -net.ipv4.ip_forward=1' is set in docker-compose."
fi

# 2. Firewall Rules (Explicitly Allow Ports)
iptables -F
iptables -t nat -F

# Allow Local Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow Incoming Web (8001) and SOCKS5 (1080)
echo "Allowing inbound traffic on ports 8001 and 1080..."
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT
iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
iptables -A INPUT -p udp --dport 1080 -j ACCEPT

# NAT/Masquerade for Gateway Mode
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "NAT and Firewall configured."

# --- HELPER: Write JSON State ---
write_state() {
    STATE="$1"
    URL="$2"
    TEXT="$3"
    SAFE_URL=$(echo "$URL" | sed 's/"/\\"/g')
    SAFE_TEXT=$(echo "$TEXT" | sed 's/"/\\"/g')
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
    su - gpuser -c "python3 /var/www/html/server.py >> \"$LOG_FILE\" 2>&1 &"
else
    echo "WARNING: server.py missing!"
fi

echo "Starting GlobalProtect Service (Headless)..."
su - gpuser -c "/usr/bin/gpservice &"
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
if [ -z "$VPN_PORTAL" ]; then
    echo "ERROR: VPN_PORTAL environment variable is not set!" >> "$LOG_FILE"
fi

su - gpuser -c "
    # Pass env var to user session
    export VPN_PORTAL=\"$VPN_PORTAL\"

    exec 3<> /tmp/gp-stdin
    > \"$LOG_FILE\"

    while true; do
        echo \"Attempting connection to \$VPN_PORTAL...\" >> \"$LOG_FILE\"

        CMD=\"gpclient --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote\"
        script -q -c \"\$CMD\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
        CLIENT_PID=\$!

        while kill -0 \$CLIENT_PID 2>/dev/null; do
            if grep -q \"Connected\" \"$LOG_FILE\"; then
                cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"connected\", \"log\": \"VPN Connected Successfully\" }
JSON
                mv $STATUS_FILE.tmp $STATUS_FILE

            # CHECK FOR URL (Ignoring prelogin.esp)
            elif grep -oE \"https?://[^ ]+\" \"$LOG_FILE\" | grep -v \"prelogin.esp\" | grep -q \"http\"; then

                 # 1. Extract the raw dirty URL (might have parens/quotes)
                 LOCAL_URL=\$(grep -oE \"https?://[^ ]+\" \"$LOG_FILE\" | grep -v \"prelogin.esp\" | tail -1)

                 # 2. Clean it safely using Python arguments (No syntax errors!)
                 REAL_URL=\$(export http_proxy=; export https_proxy=; python3 -c \"
import sys
try:
    if len(sys.argv) > 1:
        # Strip trailing punctuation: ) . \\\" '
        url = sys.argv[1].rstrip(').\\\",\\'')
        print(url)
except:
    pass
\" \"\$LOCAL_URL\")

                 if [ -z \"\$REAL_URL\" ]; then REAL_URL=\"\$LOCAL_URL\"; fi

                 LINK_TEXT=\"Open Login Page (SSO)\"
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