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

write_state "idle" "" "" "Waiting for user to click connect..."

while true; do
    read _ < /tmp/gp-control
    write_state "connecting" "" "" "Signal received, starting gpclient..."

    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"
        exec 3<> /tmp/gp-stdin
        > \"$LOG_FILE\"
        > \"$DEBUG_LOG\"

        while true; do
            echo \"DEBUG: Launching gpclient...\" >> \"$DEBUG_LOG\"

            # Using stdbuf to ensure the log catches every line immediately
            CMD=\"gpclient --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote\"
            script -q -c \"\$CMD\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
            CLIENT_PID=\$!

            while kill -0 \$CLIENT_PID 2>/dev/null; do
                # 1. Check for success
                if grep -q \"Connected\" \"$LOG_FILE\"; then
                    write_state \"connected\" \"\" \"\" \"VPN Established!\"

                # 2. Advanced URL Detection logic
                else
                    # Scan for ANY http/https link that isn't prelogin
                    FOUND_URL=\$(grep -oE \"https?://[0-9a-zA-Z./:-]+\" \"$LOG_FILE\" | grep -v \"prelogin.esp\" | tail -1)

                    if [ -n \"\$FOUND_URL\" ]; then
                        # Clean the URL
                        CLEAN_URL=\$(echo \"\$FOUND_URL\" | tr -d '[:space:]' | sed 's/[\")\\\\\\\\\\\\]*\$//')
                        echo \"DEBUG: Found URL: \$CLEAN_URL\" >> \"$DEBUG_LOG\"

                        LINK_TEXT=\"Open Login Page (SSO)\"
                        # Explicitly call the function to update JSON
                        write_state \"auth\" \"\$CLEAN_URL\" \"\$LINK_TEXT\" \"Captured URL from logs.\"
                    else
                        # Just update the log content in the UI while waiting
                        write_state \"connecting\" \"\" \"\" \"Scanning logs for SSO URL...\"
                    fi
                fi
                sleep 2
            done

            echo \"DEBUG: gpclient process died.\" >> \"$DEBUG_LOG\"
            write_state \"idle\" \"\" \"\" \"Process exited. Check Logs.\"
            sleep 5
        done
    " &
done