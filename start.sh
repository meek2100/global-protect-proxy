#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"
DEBUG_LOG="/tmp/gp-logs/debug_parser.log"

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
    echo "IP Forwarding is already enabled."
else
    echo 1 > /proc/sys/net/ipv4/ip_forward || echo "WARNING: Could not write to ip_forward."
fi

iptables -F
iptables -t nat -F
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT
iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
iptables -A INPUT -p udp --dport 1080 -j ACCEPT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "NAT and Firewall configured."

# --- HELPER: Write JSON State (Root Only) ---
write_state_root() {
    STATE="$1"
    URL="$2"
    TEXT="$3"
    DEBUG_MSG="$4"
    LOG_CONTENT=$(tail -n 15 "$LOG_FILE" 2>/dev/null | awk '{printf "%s\\n", $0}' | sed 's/"/\\"/g')

    cat <<JSON > "$STATUS_FILE.tmp"
{
  "state": "$STATE",
  "url": "$(echo "$URL" | sed 's/"/\\"/g')",
  "link_text": "$(echo "$TEXT" | sed 's/"/\\"/g')",
  "debug": "$(echo "$DEBUG_MSG" | sed 's/"/\\"/g')",
  "log": "$LOG_CONTENT"
}
JSON
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

echo "=== Container Started ==="
rm -f /tmp/gp-stdin /tmp/gp-control /var/run/gpservice.lock
mkfifo /tmp/gp-stdin /tmp/gp-control
chmod 666 /tmp/gp-stdin /tmp/gp-control
touch "$LOG_FILE" "$DEBUG_LOG"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

echo "Starting Services..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
su - gpuser -c "python3 /var/www/html/server.py >> \"$LOG_FILE\" 2>&1 &"
su - gpuser -c "/usr/bin/gpservice >> \"$LOG_FILE\" 2>&1 &"

write_state_root "idle" "" "" "Waiting for user to click connect..."

while true; do
    read _ < /tmp/gp-control
    write_state_root "connecting" "" "" "Signal received, starting gpclient..."

    # We cannot use functions inside 'su', so we inline the JSON writing logic
    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"
        exec 3<> /tmp/gp-stdin
        > \"$LOG_FILE\"
        > \"$DEBUG_LOG\"

        while true; do
            echo \"DEBUG: Launching gpclient...\" >> \"$DEBUG_LOG\"

            # Use stdbuf to force line buffering
            CMD=\"stdbuf -oL -eL gpclient --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote\"
            script -q -c \"\$CMD\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
            CLIENT_PID=\$!

            while kill -0 \$CLIENT_PID 2>/dev/null; do
                # 1. Check for success
                if grep -q \"Connected\" \"$LOG_FILE\"; then
                     cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"connected\", \"log\": \"VPN Established Successfully!\" }
JSON
                     mv $STATUS_FILE.tmp $STATUS_FILE

                # 2. Check for URL
                else
                    FOUND_URL=\$(grep -oE \"https?://[0-9a-zA-Z./:-]+\" \"$LOG_FILE\" | grep -v \"prelogin.esp\" | tail -1)

                    if [ -n \"\$FOUND_URL\" ]; then
                        CLEAN_URL=\$(echo \"\$FOUND_URL\" | tr -d '[:space:]' | sed 's/[\")\\\\\\\\\\\\]*\$//')
                        echo \"DEBUG: Found URL: \$CLEAN_URL\" >> \"$DEBUG_LOG\"

                        # Escape quotes for JSON
                        LOG_CONTENT=\$(tail -n 15 \"$LOG_FILE\" | awk '{printf \"%s\\\\\\\\n\", \$0}' | sed 's/\"/\\\\\\\\\"/g')

                        cat <<JSON > $STATUS_FILE.tmp
{
  \"state\": \"auth\",
  \"url\": \"\$CLEAN_URL\",
  \"link_text\": \"Open Login Page (SSO)\",
  \"debug\": \"Captured URL from logs\",
  \"log\": \"\$LOG_CONTENT\"
}
JSON
                        mv $STATUS_FILE.tmp $STATUS_FILE
                    else
                        # Update Log View while connecting
                        LOG_CONTENT=\$(tail -n 15 \"$LOG_FILE\" | awk '{printf \"%s\\\\\\\\n\", \$0}' | sed 's/\"/\\\\\\\\\"/g')
                        cat <<JSON > $STATUS_FILE.tmp
{
  \"state\": \"connecting\",
  \"debug\": \"Scanning for SSO URL...\",
  \"log\": \"\$LOG_CONTENT\"
}
JSON
                        mv $STATUS_FILE.tmp $STATUS_FILE
                    fi
                fi
                sleep 2
            done

            echo \"DEBUG: gpclient process died.\" >> \"$DEBUG_LOG\"
            cat <<JSON > $STATUS_FILE.tmp
{ \"state\": \"idle\", \"log\": \"Process exited. Check Logs.\", \"debug\": \"Client died.\" }
JSON
            mv $STATUS_FILE.tmp $STATUS_FILE
            sleep 5
        done
    " &
done