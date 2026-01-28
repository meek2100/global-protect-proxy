#!/bin/bash
# File: entrypoint.sh
set -e

# --- FIX: Ensure administrative commands (ip, iptables) are in PATH ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# --- CONFIGURATION ---
CLIENT_LOG="/tmp/gp-logs/gp-client.log"
SERVICE_LOG="/tmp/gp-logs/gp-service.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

# Defaults
: "${TZ:=UTC}"
: "${LOG_LEVEL:=INFO}"
: "${VPN_MODE:=standard}"
: "${DNS_SERVERS:=}"
: "${GP_ARGS:=}"

# Disable ANSI colors in Rust binaries (Fixes log artifacting)
export RUST_LOG_STYLE=never

# Apply Timezone
ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" >/etc/timezone

# --- LOGGING HELPER ---
log() {
    local level="$1"
    local msg="$2"
    local should_log=false
    case "$LOG_LEVEL" in
        TRACE) should_log=true ;;
        DEBUG) [[ "$level" != "TRACE" ]] && should_log=true ;;
        INFO) [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && should_log=true ;;
        *) [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && should_log=true ;;
    esac

    if [ "$should_log" = true ]; then
        local timestamp
        timestamp=$(date +'%Y-%m-%dT%H:%M:%SZ')
        echo "[$timestamp] [$level] $msg" >>"$SERVICE_LOG"
        echo "[$timestamp] [$level] $msg" >&2
    fi
}

# --- GRACEFUL SHUTDOWN ---
cleanup() {
    log "WARN" "Received Shutdown Signal"
    sudo pkill gpclient || true
    kill "$(jobs -p)" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- LOG ROTATION ---
check_log_size() {
    # Limit logs to 10MB to prevent container disk exhaustion
    local max_size=10485760
    for logfile in "$CLIENT_LOG" "$SERVICE_LOG"; do
        if [ -f "$logfile" ]; then
            local size
            size=$(stat -c%s "$logfile")
            if [ "$size" -gt "$max_size" ]; then
                echo "[$(date)] Log truncated due to size limit." >"$logfile"
            fi
        fi
    done
}

# --- WATCHDOG ---
check_services() {
    # 1. Web UI Check
    if ! pgrep -f server.py >/dev/null; then
        log "ERROR" "CRITICAL: Web UI (server.py) died."
        exit 1
    fi

    # 2. GlobalProtect Service Check
    if ! pgrep -f "gpservice" >/dev/null; then
        log "ERROR" "CRITICAL: gpservice died."

        # DEBUG: Dump process list to see what IS running
        log "ERROR" "--- PROCESS LIST (DEBUG) ---"
        ps aux >&2

        log "ERROR" "--- DUMPING LOGS (Last 50 lines) ---"
        tail -n 50 "$SERVICE_LOG" >&2
    fi
}

# --- DNS WATCHDOG ---
dns_watchdog() {
    local last_dns=""
    while true; do
        local current_dns=""
        if [ -f /etc/resolv.conf ]; then
            while read -r line; do
                if [[ "$line" =~ ^nameserver\ +([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    local ip="${BASH_REMATCH[1]}"
                    if [[ "$ip" != "127.0.0.1" ]]; then
                        current_dns="$ip"
                        break
                    fi
                fi
            done </etc/resolv.conf
        fi

        if [ -n "$current_dns" ] && [ "$current_dns" != "$last_dns" ]; then
            if [[ "$current_dns" != "8.8.8.8" && "$current_dns" != "1.1.1.1" ]]; then
                log "INFO" "VPN DNS Detected: $current_dns. Enabling Forwarding..."
                if [ -n "$last_dns" ]; then
                    iptables -t nat -D PREROUTING -i eth0 -p udp --dport 53 -j DNAT --to-destination "$last_dns" 2>/dev/null || true
                    iptables -t nat -D PREROUTING -i eth0 -p tcp --dport 53 -j DNAT --to-destination "$last_dns" 2>/dev/null || true
                fi
                iptables -t nat -A PREROUTING -i eth0 -p udp --dport 53 -j DNAT --to-destination "$current_dns"
                iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 53 -j DNAT --to-destination "$current_dns"
                last_dns="$current_dns"
            fi
        fi
        sleep 5
    done
}

# --- 1. SETUP ---
if [ -n "$PUID" ]; then usermod -u "$PUID" gpuser; fi
if [ -n "$PGID" ]; then groupmod -g "$PGID" gpuser; fi

# --- 2. NETWORK & MODE DETECTION ---
log "INFO" "Inspecting network environment..."
IS_MACVLAN=false
if ip -d link show eth0 | grep -q "macvlan"; then
    IS_MACVLAN=true
    log "DEBUG" "Network detection: MACVLAN interface detected."
else
    log "DEBUG" "Network detection: Standard/Bridge interface detected."
fi

if [ "$VPN_MODE" == "gateway" ] || [ "$VPN_MODE" == "standard" ]; then
    if [ "$IS_MACVLAN" = false ]; then
        log "WARN" "Configuration Mismatch: '$VPN_MODE' mode requested but no Macvlan interface found."
        log "WARN" "Gateway features require a direct routable IP (Macvlan)."
        log "WARN" ">>> REVERTING TO 'socks' MODE to ensure functionality. <<<"
        VPN_MODE="socks"
    fi
fi

# --- 3. DNS CONFIGURATION ---
DNS_TO_APPLY=""
if [ -n "$DNS_SERVERS" ]; then
    log "INFO" "Custom DNS configuration found: $DNS_SERVERS"
    DNS_TO_APPLY=$(echo "$DNS_SERVERS" | tr ',' ' ')
elif [ "$IS_MACVLAN" = true ]; then
    log "INFO" "Macvlan detected. Applying fallback defaults."
    DNS_TO_APPLY="8.8.8.8 1.1.1.1"
fi

if [ -n "$DNS_TO_APPLY" ]; then
    log "INFO" "Overwriting /etc/resolv.conf"
    echo "options ndots:0" >/etc/resolv.conf
    for ip in $DNS_TO_APPLY; do
        echo "nameserver $ip" >>/etc/resolv.conf
    done
fi

# --- 4. NETWORK SETUP ---
iptables -F
iptables -t nat -F
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT

if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        echo 1 >/proc/sys/net/ipv4/ip_forward
    fi
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
    iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
    iptables -A INPUT -p udp --dport 1080 -j ACCEPT
fi

# --- 5. INIT ENVIRONMENT ---
rm -f "$PIPE_STDIN" "$PIPE_CONTROL" "$MODE_FILE"
mkfifo "$PIPE_STDIN" "$PIPE_CONTROL"
mkdir -p /tmp/gp-logs
touch "$CLIENT_LOG" "$SERVICE_LOG"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html "$PIPE_STDIN" "$PIPE_CONTROL"
echo "idle" >"$MODE_FILE"
chmod 644 "$MODE_FILE"

# --- 6. START SERVICES ---
log "INFO" "Starting Services..."
dns_watchdog &

# FIX: Start gpservice via bash pipe to filter out benign error noise.
runuser -u gpuser -- bash -c "
    /usr/bin/gpservice 2>&1 | \
    grep --line-buffered -v -E 'Failed to start WS server|Error: No such file or directory \(os error 2\)' \
    >> \"$SERVICE_LOG\"
" &

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    runuser -u gpuser -- microsocks -i 0.0.0.0 -p 1080 >/dev/null 2>&1 &
fi

# Pass configuration to Server
runuser -u gpuser -- env VPN_MODE="$VPN_MODE" LOG_LEVEL="$LOG_LEVEL" \
    python3 -u /var/www/html/server.py >>"$SERVICE_LOG" 2>&1 &

# FIX: Stream logs to Docker stdout in background
tail -F "$SERVICE_LOG" "$CLIENT_LOG" &

# Grace period for services to settle before we start checking them
sleep 3

# --- 7. MAIN LOOP ---
while true; do
    check_services
    check_log_size

    if read -r -t 2 _ <"$PIPE_CONTROL"; then
        log "INFO" "Signal received. Starting gpclient..."
        echo "active" >"$MODE_FILE"

        runuser -u gpuser -- bash -c "
            export VPN_PORTAL=\"$VPN_PORTAL\"
            export GP_ARGS=\"$GP_ARGS\"
            > \"$CLIENT_LOG\"
            exec 3<> \"$PIPE_STDIN\"

            # Using sudo for gpclient to allow full network access
            CMD=\"sudo gpclient --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote \$GP_ARGS\"

            echo \"[Entrypoint] Executing: \$CMD\" >> \"$SERVICE_LOG\"
            script -q -c \"\$CMD\" /dev/null <&3 >> \"$CLIENT_LOG\" 2>&1
        "

        log "WARN" "gpclient exited."
        echo "idle" >"$MODE_FILE"
    fi
done
