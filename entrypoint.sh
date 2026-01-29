#!/bin/bash
# File: entrypoint.sh
set -e

# --- FIX: Ensure administrative commands (ip, iptables) are in PATH ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ==============================================================================
# 1. ROBUST CONFIGURATION PARSING
# ==============================================================================

# Helper: Find env var value case-insensitively
get_env_value() {
    local val=""

    # FIX SC2124: Iterate over arguments directly instead of assigning $@ to string
    for key in "$@"; do
        # 1. Check exact match (Fast)
        if [ -n "${!key}" ]; then
            val="${!key}"
            break
        fi

        # 2. Check case-insensitive match in environment
        # Uses grep to find "KEY=" case-insensitively at start of line
        local match_line
        match_line=$(env | grep -i "^${key}=" | head -n 1)
        if [ -n "$match_line" ]; then
            # Extract value after the first '='
            val="${match_line#*=}"
            break
        fi
    done
    echo "$val"
}

# Helper: Strip quotes and trim whitespace
clean_val() {
    local val="$1"
    # Strip surrounding double quotes
    val="${val%\"}"
    val="${val#\"}"
    # Strip surrounding single quotes
    val="${val%\'}"
    val="${val#\'}"
    # Trim whitespace using xargs
    echo "$val" | xargs
}

# --- Resolve & Normalize Variables ---

# 1. LOG_LEVEL (Aliases: log_level)
# FIX SC2155: Split assignment and export
RAW_LOG_LEVEL=$(get_env_value "LOG_LEVEL" "log_level")
CLEAN_LOG_LEVEL=$(clean_val "$RAW_LOG_LEVEL")
# Default to INFO, normalize to UPPERCASE
LOG_LEVEL="${CLEAN_LOG_LEVEL^^}"
[ -z "$LOG_LEVEL" ] && LOG_LEVEL="INFO"
export LOG_LEVEL

# 2. VPN_MODE (Aliases: vpn_mode)
RAW_VPN_MODE=$(get_env_value "VPN_MODE" "vpn_mode")
CLEAN_VPN_MODE=$(clean_val "$RAW_VPN_MODE")
# Default to standard, normalize to lowercase
VPN_MODE="${CLEAN_VPN_MODE,,}"
[ -z "$VPN_MODE" ] && VPN_MODE="standard"
export VPN_MODE

# 3. VPN_PORTAL (Aliases: vpn_portal)
RAW_VPN_PORTAL=$(get_env_value "VPN_PORTAL" "vpn_portal")
VPN_PORTAL=$(clean_val "$RAW_VPN_PORTAL")
export VPN_PORTAL

# 4. DNS_SERVERS (Aliases: dns_servers, VPN_DNS, vpn_dns)
RAW_DNS=$(get_env_value "DNS_SERVERS" "dns_servers" "VPN_DNS" "vpn_dns")
CLEAN_DNS=$(clean_val "$RAW_DNS")
# Robust DNS parsing: Replace commas with spaces, squash multiple spaces
DNS_SERVERS=$(echo "$CLEAN_DNS" | tr ',' ' ' | xargs)
export DNS_SERVERS

# 5. GP_ARGS (Aliases: gp_args)
RAW_GP_ARGS=$(get_env_value "GP_ARGS" "gp_args")
GP_ARGS=$(clean_val "$RAW_GP_ARGS")
export GP_ARGS

# 6. TIMEZONE (Aliases: TZ, tz, timezone)
RAW_TZ=$(get_env_value "TZ" "tz" "timezone")
CLEAN_TZ=$(clean_val "$RAW_TZ")
TZ="${CLEAN_TZ:-UTC}"
export TZ

# 7. PUID/PGID (Aliases: puid, pgid)
RAW_PUID=$(get_env_value "PUID" "puid")
PUID=$(clean_val "$RAW_PUID")
export PUID

RAW_PGID=$(get_env_value "PGID" "pgid")
PGID=$(clean_val "$RAW_PGID")
export PGID

# ==============================================================================
# 2. RUNTIME SETUP
# ==============================================================================

CLIENT_LOG="/tmp/gp-logs/gp-client.log"
SERVICE_LOG="/tmp/gp-logs/gp-service.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

# Disable ANSI colors in Rust binaries (Fixes log artifacting)
export RUST_LOG_STYLE=never

# Apply Timezone
if [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" >/etc/timezone
fi

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

# --- VERBOSITY MAPPING ---
# Map Container LOG_LEVEL to gpclient verbose flags
GP_VERBOSITY=""
if [ "$LOG_LEVEL" == "DEBUG" ]; then
    GP_VERBOSITY="-v"
elif [ "$LOG_LEVEL" == "TRACE" ]; then
    GP_VERBOSITY="-vv"
fi

# --- STARTUP SUMMARY ---
log "INFO" "=========================================="
log "INFO" "       GlobalProtect Proxy Startup        "
log "INFO" "=========================================="
log "INFO" "Mode:        $VPN_MODE"
log "INFO" "Log Level:   $LOG_LEVEL"
log "INFO" "Verbosity:   ${GP_VERBOSITY:-None}"
log "INFO" "Portal:      ${VPN_PORTAL:-[Not Set]}"
if [ -n "$DNS_SERVERS" ]; then
    log "INFO" "Custom DNS:  $DNS_SERVERS"
fi
log "INFO" "------------------------------------------"

# --- GRACEFUL SHUTDOWN ---
cleanup() {
    log "WARN" "Received Shutdown Signal"
    sudo pkill gpclient || true
    sudo pkill gpservice || true
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
    # 1. Web UI Check (Always required)
    if ! pgrep -f server.py >/dev/null; then
        log "ERROR" "CRITICAL: Web UI (server.py) died."
        exit 1
    fi

    # 2. GlobalProtect Service Check (Only if Active)
    # We only check gpservice if we expect it to be running (Active mode)
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "idle")

    if [ "$mode" == "active" ]; then
        if ! pgrep -f "gpservice" >/dev/null; then
            log "ERROR" "CRITICAL: gpservice died while VPN was active."

            # DEBUG: Dump process list to see what IS running
            log "ERROR" "--- PROCESS LIST (DEBUG) ---"
            ps aux >&2

            log "ERROR" "--- DUMPING LOGS (Last 50 lines) ---"
            tail -n 50 "$SERVICE_LOG" >&2
        fi
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
    # Already cleaned and space-separated by the config parser
    DNS_TO_APPLY="$DNS_SERVERS"
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

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    runuser -u gpuser -- microsocks -i 0.0.0.0 -p 1080 >/dev/null 2>&1 &
fi

# Pass configuration to Server
# We pass the robustly parsed variables here
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
        log "INFO" "Signal received. Starting Connection Sequence..."
        echo "active" >"$MODE_FILE"

        # 1. Start gpservice (On-Demand)
        # We start it here so it's fresh for the connection attempt
        log "INFO" "Starting gpservice..."
        runuser -u gpuser -- bash -c "
            /usr/bin/gpservice 2>&1 | \
            grep --line-buffered -v -E 'Failed to start WS server|Error: No such file or directory \(os error 2\)' \
            >> \"$SERVICE_LOG\"
        " &

        # Give gpservice a moment to initialize the socket
        sleep 2

        # 2. Start gpclient (With Verbosity)
        # Explicitly pass GP_VERBOSITY (e.g. -v or -vv)
        runuser -u gpuser -- bash -c "
            export VPN_PORTAL=\"$VPN_PORTAL\"
            export GP_ARGS=\"$GP_ARGS\"
            > \"$CLIENT_LOG\"
            exec 3<> \"$PIPE_STDIN\"

            # Using sudo for gpclient to allow full network access
            CMD=\"sudo gpclient $GP_VERBOSITY --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote \$GP_ARGS\"

            echo \"[Entrypoint] Executing: \$CMD\" >> \"$SERVICE_LOG\"
            script -q -c \"\$CMD\" /dev/null <&3 >> \"$CLIENT_LOG\" 2>&1
        "

        # 3. Cleanup after disconnect
        log "WARN" "gpclient exited. Cleaning up services..."
        echo "idle" >"$MODE_FILE"

        # Kill gpservice to return to 'Standby' state
        sudo pkill gpservice || true
        log "INFO" "gpservice stopped. System Idle."
    fi
done
