#!/bin/bash
set -e

# --- CONFIGURATION ---
LOG_FILE="/tmp/gp-logs/vpn.log"
DEBUG_LOG="/tmp/gp-logs/debug_parser.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

# Defaults
: "${LOG_LEVEL:=INFO}"   # Options: INFO, DEBUG, TRACE
: "${VPN_MODE:=standard}" # Options: standard, socks, gateway

# --- LOGGING HELPER ---
declare -A LOG_PRIORITY
LOG_PRIORITY=( ["TRACE"]=10 ["DEBUG"]=20 ["INFO"]=30 ["WARN"]=40 ["ERROR"]=50 )

log() {
    local level="$1"
    local msg="$2"

    local should_log=false
    case "$LOG_LEVEL" in
        TRACE) should_log=true ;;
        DEBUG) [[ "$level" != "TRACE" ]] && should_log=true ;;
        INFO)  [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && should_log=true ;;
        *)     [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && should_log=true ;;
    esac

    if [ "$should_log" = true ]; then
        local timestamp
        timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        local log_entry="[$timestamp] [$level] $msg"

        # 1. Write to internal file (For the Web UI)
        echo "$log_entry" >> "$DEBUG_LOG"

        # 2. Write to Container StdErr (For Docker Logs/You)
        # We use >&2 (stderr) so it appears in 'docker logs' immediately.
        echo "$log_entry" >&2
    fi
}

log "INFO" "Entrypoint started. Level: $LOG_LEVEL, Mode: $VPN_MODE"

# --- 1. DNS FIX FOR MACVLAN/PORTAINER ---
echo "Force-updating /etc/resolv.conf..."
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
options ndots:0
EOF

# --- 2. NETWORK SETUP (Root) ---
log "INFO" "Configuring Networking..."

if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        log "DEBUG" "IP Forwarding is already enabled."
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward || log "ERROR" "Could not write to ip_forward."
    fi
else
    log "INFO" "Mode is '$VPN_MODE' - Skipping IP Forwarding enablement."
fi

# Reset Firewall
iptables -F
iptables -t nat -F

# Allow Local Access
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
    iptables -A INPUT -p udp --dport 1080 -j ACCEPT
fi

# NAT Routing
if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Applying NAT (Masquerade) rules..."
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
    iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
else
    log "INFO" "Skipping NAT rules (Mode: $VPN_MODE)"
fi

log "INFO" "Network setup complete."

# --- 3. INIT ENVIRONMENT ---
log "INFO" "Initializing Environment..."

# Cleanup old pipes/files
rm -f "$PIPE_STDIN" "$PIPE_CONTROL" "$MODE_FILE"
mkfifo "$PIPE_STDIN" "$PIPE_CONTROL"
chmod 666 "$PIPE_STDIN" "$PIPE_CONTROL"

# Ensure log dir exists and is writable by gpuser
mkdir -p /tmp/gp-logs
touch "$LOG_FILE" "$DEBUG_LOG"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

# Initialize Mode
# Root owns it (writer), gpuser reads it.
echo "idle" > "$MODE_FILE"
chmod 644 "$MODE_FILE"

# --- 4. START SERVICES ---
log "INFO" "Starting Services..."

# 1. Microsocks
if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Starting Microsocks on port 1080..."
    su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
else
    log "INFO" "Microsocks disabled by mode '$VPN_MODE'."
fi

# 2. Python Web Server
log "INFO" "Starting Python Control Server..."
su - gpuser -c "export LOG_LEVEL='$LOG_LEVEL'; python3 /var/www/html/server.py >> \"$DEBUG_LOG\" 2>&1 &"

# --- 5. MAIN CONTROL LOOP ---
while true; do
    log "DEBUG" "Waiting for start signal..."

    # Block until "START" is written to the pipe
    read _ < "$PIPE_CONTROL"

    log "INFO" "Signal received. Starting gpclient..."

    echo "active" > "$MODE_FILE"

    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"
        > \"$LOG_FILE\"
        echo \"[Entrypoint Subshell] Launching gpclient binary...\" >> \"$DEBUG_LOG\"
        stdbuf -oL -eL gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote < \"$PIPE_STDIN\" >> \"$LOG_FILE\" 2>&1
    "

    log "WARN" "gpclient process exited."
    echo "idle" > "$MODE_FILE"

    sleep 2
done