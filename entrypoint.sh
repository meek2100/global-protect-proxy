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
# Maps string levels to numeric priority
declare -A LOG_PRIORITY
LOG_PRIORITY=( ["TRACE"]=10 ["DEBUG"]=20 ["INFO"]=30 ["WARN"]=40 ["ERROR"]=50 )

# Get current level priority (default to INFO=30)
CURRENT_PRIORITY=${LOG_PRIORITY[$LOG_LEVEL]}
[[ -z "$CURRENT_PRIORITY" ]] && CURRENT_PRIORITY=30

log() {
    local level="$1"
    local msg="$2"
    local priority=${LOG_PRIORITY[$level]}

    # Only log if priority is >= configured level (Standard logic is reversed: lower number = more detail?
    # Actually, usually TRACE < DEBUG < INFO. Let's filter: Print if Priority <= Configured Priority?
    # No, typically: If Config is DEBUG, we show DEBUG and INFO. If Config is INFO, we hide DEBUG.
    # Let's flip logic: TRACE=10, DEBUG=20, INFO=30.
    # We want to show if msg_priority >= current_config_priority?
    # No. If I want DEBUG (20), I want to see DEBUG (20) and INFO (30).
    # Wait, simple check:

    local should_log=false

    # Priority check: Show message if its level matches or exceeds the "verbosity" of the setting?
    # Common convention: TRACE(all) > DEBUG > INFO > WARN > ERROR(least)
    # Let's use numeric comparison:
    # TRACE=10, DEBUG=20, INFO=30
    # If Level is DEBUG(20), we show >= 20? No, we show >= 20 (Info is 30).

    # Let's simplify.
    case "$LOG_LEVEL" in
        TRACE) should_log=true ;;
        DEBUG) [[ "$level" != "TRACE" ]] && should_log=true ;;
        INFO)  [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && should_log=true ;;
        *)     [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && should_log=true ;;
    esac

    if [ "$should_log" = true ]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [$level] $msg" >> "$DEBUG_LOG"
        # Also print ERRORs to stderr for Docker logs
        if [ "$level" == "ERROR" ]; then
            echo "[$level] $msg" >&2
        fi
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

# Enable IP Forwarding only if acting as a Gateway
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

# Allow Local Access (Web UI & Proxy)
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
    iptables -A INPUT -p udp --dport 1080 -j ACCEPT
fi

# NAT Routing for VPN (Only for Gateway/Standard)
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
echo "idle" > "$MODE_FILE"
chown gpuser:gpuser "$MODE_FILE"

# --- 4. START SERVICES ---
log "INFO" "Starting Services..."

# 1. Microsocks (SOCKS5 Proxy)
if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Starting Microsocks on port 1080..."
    su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
else
    log "INFO" "Microsocks disabled by mode '$VPN_MODE'."
fi

# 2. Python Web Server (The Brain)
# Pass the log level to Python
log "INFO" "Starting Python Control Server..."
su - gpuser -c "export LOG_LEVEL='$LOG_LEVEL'; python3 /var/www/html/server.py >> \"$DEBUG_LOG\" 2>&1 &"

# --- 5. MAIN CONTROL LOOP ---
while true; do
    log "DEBUG" "Waiting for start signal..."

    # Block until "START" is written to the pipe
    read _ < "$PIPE_CONTROL"

    log "INFO" "Signal received. Starting gpclient..."
    echo "active" > "$MODE_FILE"

    # Run gpclient as gpuser
    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"

        # Clear log for fresh run
        > \"$LOG_FILE\"

        echo \"[Entrypoint Subshell] Launching gpclient binary...\" >> \"$DEBUG_LOG\"

        # Launch gpclient with input pipe
        stdbuf -oL -eL gpclient --fix-openssl connect \"\$VPN_PORTAL\" --browser remote < \"$PIPE_STDIN\" >> \"$LOG_FILE\" 2>&1
    "

    # When gpclient exits:
    log "WARN" "gpclient process exited."
    echo "idle" > "$MODE_FILE"

    sleep 2
done