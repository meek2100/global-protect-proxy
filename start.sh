#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"

# --- 1. DNS FIX FOR MACVLAN/PORTAINER ---
echo "Force-updating /etc/resolv.conf..."
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
options ndots:0
EOF

# --- 2. NETWORK SETUP (Root) ---
echo "=== Network Setup ==="

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo "IP Forwarding is already enabled (via docker-compose)."
else
    echo "Attempting to enable IP Forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward || echo "WARNING: Could not write to ip_forward. Ensure 'sysctls -net.ipv4.ip_forward=1' is set in docker-compose."
fi

iptables -F
iptables -t nat -F

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

echo "Allowing inbound traffic on ports 8001 and 1080..."
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT
iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
iptables -A INPUT -p udp --dport 1080 -j ACCEPT

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
    # Escape backslashes for JSON compatibility
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

rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control

if ! touch /var/run/gpservice.lock; then
    echo "CRITICAL ERROR: Could not create lock file."
    exit 1
fi
chown gpuser:gpuser /var/run/gpservice.lock

mkfifo /tmp/gp-stdin /tmp/gp-control
chown gpuser:gpuser /tmp/gp-stdin /tmp/gp-control
chmod 666 /tmp/gp-stdin /tmp/gp-control

mkdir -p /tmp/gp-logs
touch "$LOG_FILE"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

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

tail -f "$LOG_FILE" &

write_state "idle" "" ""
echo "State: IDLE. Waiting for user..."

# --- MAIN LOOP ---
while true; do
    # 2. WAIT FOR USER SIGNAL FROM WEB UI
    read _ < /tmp/gp-control

    write_state "connecting" "" ""
    echo "State: CONNECTING..."

    if [ -z "$VPN_PORTAL" ]; then
        echo "ERROR: VPN_PORTAL environment variable is not set!" >> "$LOG_FILE"
    fi

    su - gpuser -c "
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
                    # Manually update state to connected
                    cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"connected\", \"log\": \"VPN Connected Successfully\" }
JSON
                    mv $STATUS_FILE.tmp $STATUS_FILE

                # NEW REGEX: Matches both http/https and includes port numbers and hyphens
                elif grep -oE \"https?://[0-9a-zA-Z./:-]+\" \"$LOG_FILE\" | grep -v \"prelogin.esp\" | grep -q \"http\"; then

                     RAW_URL=\$(grep -oE \"https?://[0-9a-zA-Z./:-]+\" \"$LOG_FILE\" | grep -v \"prelogin.esp\" | tail -1)

                     # Clean any trailing punctuation or terminal artifacts
                     CLEAN_URL=\$(echo \"\$RAW_URL\" | tr -d '[:space:]' | sed 's/[\")\\\\\\\\\\\\]*\$//')

                     if [ -n \"\$CLEAN_URL\" ]; then
                         LINK_TEXT=\"Open Login Page (SSO)\"
                         LOG_CONTENT=\$(tail -n 20 \"$LOG_FILE\" | awk '{printf \"%s\\\\\\\\\\\\\\\\n\", \$0}' | sed 's/\"/\\\\\\\\\\\\\\\\\"/g')

                         cat <<JSON > $STATUS_FILE.tmp
{
  \"state\": \"auth\",
  \"url\": \"\$CLEAN_URL\",
  \"link_text\": \"\$LINK_TEXT\",
  \"log\": \"\$LOG_CONTENT\"
}
JSON
                         mv $STATUS_FILE.tmp $STATUS_FILE
                     fi
                fi
                sleep 1
            done

            # If client dies, notify UI and wait before retry
            cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"idle\", \"log\": \"Connection lost or failed. Re-click Connect.\" }
JSON
            mv $STATUS_FILE.tmp $STATUS_FILE
            sleep 5
        done
    " &
done