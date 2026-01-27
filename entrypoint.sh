#!/bin/bash
set -e

# --- CONFIGURATION ---
LOG_FILE="/tmp/gp-logs/vpn.log"
DEBUG_LOG="/tmp/gp-logs/debug_parser.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

# Defaults
: "${LOG_LEVEL:=INFO}"      # Options: INFO, DEBUG, TRACE
: "${VPN_MODE:=standard}"   # Options: standard, socks, gateway
: "${DNS_SERVERS:=}"        # Optional: Comma or space separated IPs (e.g. "8.8.8.8,1.1.1.1")

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
        echo "$log_entry" >> "$DEBUG_LOG"
        echo "$log_entry" >&2
    fi
}

log "INFO" "Entrypoint started. Level: $LOG_LEVEL, Mode: $VPN_MODE"

# --- 1. NETWORK & MODE DETECTION ---
log "INFO" "Inspecting network environment..."

# Detect if eth0 is a macvlan interface
IS_MACVLAN=false
if ip -d link show eth0 | grep -q "macvlan"; then
    IS_MACVLAN=true
    log "DEBUG" "Network detection: MACVLAN interface detected."
else
    log "DEBUG" "Network detection: Standard/Bridge interface detected."
fi

# --- AUTO-REVERT LOGIC ---
if [ "$VPN_MODE" == "gateway" ] || [ "$VPN_MODE" == "standard" ]; then
    if [ "$IS_MACVLAN" = false ]; then
        log "WARN" "Configuration Mismatch: '$VPN_MODE' mode requested but no Macvlan interface found."
        log "WARN" "Gateway features require a direct routable IP (Macvlan)."
        log "WARN" ">>> REVERTING TO 'socks' MODE to ensure functionality. <<<"
        VPN_MODE="socks"
    fi
fi

log "INFO" "Final Operational Mode: $VPN_MODE"

# --- 2. DNS CONFIGURATION ---
# Logic:
# 1. If DNS_SERVERS provided -> Always apply.
# 2. Else if Macvlan -> Apply Fallback (8.8.8.8).
# 3. Else -> Do nothing (Use Docker DNS).

DNS_TO_APPLY=""

if [ -n "$DNS_SERVERS" ]; then
    log "INFO" "Custom DNS configuration found: $DNS_SERVERS"
    # Replace commas with spaces for iteration
    DNS_TO_APPLY=$(echo "$DNS_SERVERS" | tr ',' ' ')
elif [ "$IS_MACVLAN" = true ]; then
    log "INFO" "Macvlan detected without custom DNS. Applying fallback defaults (Google/Cloudflare) to fix resolution."
    DNS_TO_APPLY="8.8.8.8 1.1.1.1"
fi

if [ -n "$DNS_TO_APPLY" ]; then
    log "INFO" "Overwriting /etc/resolv.conf with: $DNS_TO_APPLY"

    # Write safe options first
    echo "options ndots:0" > /etc/resolv.conf

    # Loop through IPs and append nameserver lines
    for ip in $DNS_TO_APPLY; do
        echo "nameserver $ip" >> /etc/resolv.conf
    done
else
    log "INFO" "Using System/Docker DNS settings (No override)."
fi

# --- 3. NETWORK SETUP (Root) ---
log "INFO" "Configuring Networking..."

# Enable IP Forwarding (Only needed for Gateway/Standard)
if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        log "DEBUG" "IP Forwarding is already enabled."
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward || log "ERROR" "Could not write to ip_forward."
    fi
else
    log "DEBUG" "Skipping IP Forwarding (Not required for SOCKS)."
fi

# Reset Firewall
iptables -F
iptables -t nat -F

# Allow Local Access
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT

# Allow Proxy Ports (SOCKS Mode)
if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
    iptables -A INPUT -p udp --dport 1080 -j ACCEPT
fi

# NAT Routing (Gateway/Standard Mode)
if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Applying NAT (Masquerade) rules..."
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
    iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
else
    log "DEBUG" "Skipping NAT rules."
fi

log "INFO" "Network setup complete."

# --- 4. INIT ENVIRONMENT ---
log "INFO" "Initializing Environment..."

# Cleanup old pipes/files
rm -f "$PIPE_STDIN" "$PIPE_CONTROL" "$MODE_FILE"
mkfifo "$PIPE_STDIN" "$PIPE_CONTROL"
chmod 666 "$PIPE_STDIN" "$PIPE_CONTROL"

# Ensure log dir exists and is writable by gpuser
mkdir -p /tmp/gp-logs
touch "$LOG_FILE" "$DEBUG_LOG"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

# Initialize Mode file (Writable by root, readable by gpuser)
echo "idle" > "$MODE_FILE"
chmod 644 "$MODE_FILE"

# --- 5. START SERVICES ---
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

# --- 6. MAIN CONTROL LOOP ---
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