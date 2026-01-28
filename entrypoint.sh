#!/bin/bash
set -e

# --- FIX: Ensure administrative commands (ip, iptables) are in PATH ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# --- CONFIGURATION ---
LOG_FILE="/tmp/gp-logs/vpn.log"
DEBUG_LOG="/tmp/gp-logs/debug_parser.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

# Defaults
: "${LOG_LEVEL:=INFO}"
: "${VPN_MODE:=standard}"
: "${DNS_SERVERS:=}"
: "${GP_ARGS:=}"

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
        local timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        local log_entry="[$timestamp] [$level] $msg"
        echo "$log_entry" >> "$DEBUG_LOG"
        echo "$log_entry" >&2
    fi
}

log "INFO" "Entrypoint started. Level: $LOG_LEVEL, Mode: $VPN_MODE"

# --- DNS WATCHDOG ---
dns_watchdog() {
    local last_dns=""
    log "INFO" "Starting DNS Watchdog..."
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
            done < /etc/resolv.conf
        fi

        if [ -n "$current_dns" ] && [ "$current_dns" != "$last_dns" ]; then
            if [[ "$current_dns" != "8.8.8.8" && "$current_dns" != "1.1.1.1" ]]; then
                log "INFO" "VPN DNS Detected: $current_dns. Enabling Transparent Forwarding..."
                if [ -n "$last_dns" ]; then
                    iptables -t nat -D PREROUTING -i eth0 -p udp --dport 53 -j DNAT --to-destination "$last_dns" 2>/dev/null || true
                    iptables -t nat -D PREROUTING -i eth0 -p tcp --dport 53 -j DNAT --to-destination "$last_dns" 2>/dev/null || true
                fi
                iptables -t nat -A PREROUTING -i eth0 -p udp --dport 53 -j DNAT --to-destination "$current_dns"
                iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 53 -j DNAT --to-destination "$current_dns"
                last_dns="$current_dns"
                log "INFO" "DNS Forwarding Active."
            fi
        fi
        sleep 5
    done
}

# --- 1. USER IDENTITY DETECTION ---
if [ -n "$PUID" ]; then usermod -u "$PUID" gpuser; fi
if [ -n "$PGID" ]; then groupmod -g "$PGID" gpuser; fi

# --- 2. NETWORK & MODE DETECTION ---
log "INFO" "Inspecting network environment..."
IS_MACVLAN=false
# Using full path to ip just in case, but PATH export handles it
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

log "INFO" "Final Operational Mode: $VPN_MODE"

# --- 3. DNS CONFIGURATION ---
DNS_TO_APPLY=""
if [ -n "$DNS_SERVERS" ]; then
    log "INFO" "Custom DNS configuration found: $DNS_SERVERS"
    DNS_TO_APPLY=$(echo "$DNS_SERVERS" | tr ',' ' ')
elif [ "$IS_MACVLAN" = true ]; then
    log "INFO" "Macvlan detected without custom DNS. Applying fallback defaults (Google/Cloudflare)."
    DNS_TO_APPLY="8.8.8.8 1.1.1.1"
fi

if [ -n "$DNS_TO_APPLY" ]; then
    log "INFO" "Overwriting /etc/resolv.conf with: $DNS_TO_APPLY"
    echo "options ndots:0" > /etc/resolv.conf
    for ip in $DNS_TO_APPLY; do
        echo "nameserver $ip" >> /etc/resolv.conf
    done
else
    log "INFO" "Using System/Docker DNS settings (No override)."
fi

# --- 4. NETWORK SETUP (Root) ---
log "INFO" "Configuring Networking..."

if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        log "DEBUG" "IP Forwarding is already enabled."
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward || log "ERROR" "Could not write to ip_forward."
    fi
else
    log "DEBUG" "Skipping IP Forwarding (Not required for SOCKS)."
fi

iptables -F
iptables -t nat -F
iptables -A INPUT -p tcp --dport 8001 -j ACCEPT

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
    iptables -A INPUT -p udp --dport 1080 -j ACCEPT
fi

if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Applying NAT (Masquerade) rules..."
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
    iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
else
    log "DEBUG" "Skipping NAT rules."
fi

log "INFO" "Network setup complete."

# --- 5. INIT ENVIRONMENT ---
log "INFO" "Initializing Environment..."

rm -f "$PIPE_STDIN" "$PIPE_CONTROL" "$MODE_FILE"
mkfifo "$PIPE_STDIN" "$PIPE_CONTROL"
mkdir -p /tmp/gp-logs
touch "$LOG_FILE" "$DEBUG_LOG"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html "$PIPE_STDIN" "$PIPE_CONTROL"
echo "idle" > "$MODE_FILE"
chmod 644 "$MODE_FILE"

# --- 6. START SERVICES (As gpuser) ---
log "INFO" "Starting Services as gpuser..."

# Start DNS Watchdog in background
dns_watchdog &

log "INFO" "Starting GlobalProtect Service (gpservice)..."
su - gpuser -c "/usr/bin/gpservice >> \"$DEBUG_LOG\" 2>&1 &"

if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Starting Microsocks on port 1080..."
    su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
else
    log "INFO" "Microsocks disabled by mode '$VPN_MODE'."
fi

log "INFO" "Starting Python Control Server..."
su - gpuser -c "export LOG_LEVEL='$LOG_LEVEL'; python3 /var/www/html/server.py >> \"$DEBUG_LOG\" 2>&1 &"

# --- 7. MAIN CONTROL LOOP ---
while true; do
    log "DEBUG" "Waiting for start signal..."
    read _ < "$PIPE_CONTROL"

    log "INFO" "Signal received. Starting gpclient..."
    echo "active" > "$MODE_FILE"

    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"
        export GP_ARGS=\"$GP_ARGS\"
        > \"$LOG_FILE\"
        exec 3<> \"$PIPE_STDIN\"

        CMD=\"sudo stdbuf -oL -eL gpclient --fix-openssl connect \\\"\$VPN_PORTAL\\\" --browser remote \$GP_ARGS\"

        echo \"[Entrypoint] Running: \$CMD\" >> \"$DEBUG_LOG\"

        script -q -c \"\$CMD\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1
    "

    log "WARN" "gpclient process exited."
    echo "idle" > "$MODE_FILE"
    sleep 2
done