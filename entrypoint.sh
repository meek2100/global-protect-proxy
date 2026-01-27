#!/bin/bash
set -e

# --- CONFIG ---
LOG_FILE="/tmp/gp-logs/vpn.log"
DEBUG_LOG="/tmp/gp-logs/debug_parser.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

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

# Reset Firewall
iptables -F
iptables -t nat -F

# Allow Local Access (Web UI & Proxy)
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT
iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
iptables -A INPUT -p udp --dport 1080 -j ACCEPT

# NAT Routing for VPN
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "NAT and Firewall configured."

# --- 3. INIT ENVIRONMENT ---
echo "=== Container Started ==="

# Cleanup old pipes/files
rm -f "$PIPE_STDIN" "$PIPE_CONTROL" "$MODE_FILE"
mkfifo "$PIPE_STDIN" "$PIPE_CONTROL"
chmod 666 "$PIPE_STDIN" "$PIPE_CONTROL"

# Ensure log dir exists and is writable by gpuser
mkdir -p /tmp/gp-logs
touch "$LOG_FILE" "$DEBUG_LOG"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

# Initialize Mode
echo "idle" > "$MODE_FILE"
chown gpuser:gpuser "$MODE_FILE"

# --- 4. START SERVICES ---
echo "Starting Services..."

# 1. Microsocks (SOCKS5 Proxy)
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"

# 2. Python Web Server (The Brain)
# We run this in background; it handles the UI and logic.
su - gpuser -c "python3 /var/www/html/server.py >> \"$DEBUG_LOG\" 2>&1 &"

# --- 5. MAIN CONTROL LOOP ---
# Waits for signal from Python to start gpclient
while true; do
    echo "Waiting for start signal..." >> "$DEBUG_LOG"

    # Block until "START" is written to the pipe
    read _ < "$PIPE_CONTROL"

    echo "Signal received. Starting gpclient..." >> "$DEBUG_LOG"
    echo "active" > "$MODE_FILE"

    # Run gpclient as gpuser
    # We use 'stdbuf' to ensure output is flushed immediately to the log file
    # so Python can read it in real-time.
    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"

        # Clear log for fresh run
        > \"$LOG_FILE\"

        echo \"DEBUG: Launching gpclient binary...\" >> \"$DEBUG_LOG\"

        # Launch gpclient with input pipe
        # 'stdbuf -oL' forces line buffering
        stdbuf -oL -eL gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote < \"$PIPE_STDIN\" >> \"$LOG_FILE\" 2>&1
    "

    # When gpclient exits (crash or disconnect):
    echo "gpclient exited." >> "$DEBUG_LOG"
    echo "idle" > "$MODE_FILE"

    # Small backoff to prevent tight loop if it crashes instantly
    sleep 2
done