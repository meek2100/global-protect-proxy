#!/bin/bash
set -e

# --- CONFIGURATION ---
LOG_FILE="/tmp/gp-logs/vpn.log"
DEBUG_LOG="/tmp/gp-logs/debug_parser.log"
MODE_FILE="/tmp/gp-mode"
PIPE_STDIN="/tmp/gp-stdin"
PIPE_CONTROL="/tmp/gp-control"

# Defaults
: "${LOG_LEVEL:=INFO}"
: "${VPN_MODE:=standard}"
: "${DNS_SERVERS:=}"        # Optional: Comma or space separated IPs (e.g. "8.8.8.8,1.1.1.1")
: "${GP_ARGS:=}" # New: Allows passing custom arguments to gpclient

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

# --- 1. USER IDENTITY DETECTION ---
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

# Auto-revert logic
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

# Enable IP Forwarding
if [ "$VPN_MODE" = "gateway" ] || [ "$VPN_MODE" = "standard" ]; then
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        log "DEBUG" "IP Forwarding is already enabled."
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward || log "ERROR" "Could not write to ip_forward."
    fi
else
    log "DEBUG" "Skipping IP Forwarding (Not required for SOCKS)."
fi

# Firewall Rules
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

# --- 2. GLOBAL OPENSSL FIX (The "Sudo" equivalent) ---
# Since 'setcap' strips environment variables (breaking --fix-openssl),
# we must enable legacy renegotiation in the SYSTEM config.
log "INFO" "Applying system-wide OpenSSL Legacy Renegotiation fix..."
ssl_conf="/etc/ssl/openssl.cnf"

# Ensure the config has the legacy option enabled in the default section
if ! grep -q "UnsafeLegacyRenegotiation" "$ssl_conf"; then
    # Append the option to the [system_default_sect] if it exists, or the end of file
    if grep -q "\[system_default_sect\]" "$ssl_conf"; then
        sed -i '/\[system_default_sect\]/a Options = UnsafeLegacyRenegotiation' "$ssl_conf"
    else
        # Fallback: simpler append if section missing (Debian specific)
        echo -e "\n[system_default_sect]\nOptions = UnsafeLegacyRenegotiation" >> "$ssl_conf"
    fi
    log "INFO" "OpenSSL config patched."
fi

# --- 3. PERMISSIONS & CAPABILITIES (The "Anti-Root" Bypass) ---
log "INFO" "Setting up permissions..."

# A. Create Pipes & Logs
rm -f "$PIPE_STDIN" "$PIPE_CONTROL" "$MODE_FILE"
mkfifo "$PIPE_STDIN" "$PIPE_CONTROL"
mkdir -p /tmp/gp-logs
touch "$LOG_FILE" "$DEBUG_LOG"
chmod 666 "$PIPE_STDIN" "$PIPE_CONTROL" "$LOG_FILE" "$DEBUG_LOG" "$MODE_FILE"
chown -R gpuser:gpuser /tmp/gp-logs /var/www/html

# B. Fix VPNC Directory (Critical for 'mkdir permission denied' error)
mkdir -p /var/run/vpnc
chown -R gpuser:gpuser /var/run/vpnc

# C. Apply Capabilities (Allows gpuser to modify network/tun0)
# We apply to both /usr/bin and /usr/local/bin to be safe
for bin in /usr/bin/gpclient /usr/local/bin/gpclient /usr/bin/gpservice /usr/local/bin/gpservice; do
    if [ -f "$bin" ]; then
        log "DEBUG" "Setting capabilities on $bin"
        setcap 'cap_net_admin+ep' "$bin"
    fi
done

# --- 4. START SERVICES ---
log "INFO" "Starting Services..."

# Start gpservice (Run as ROOT is safer for dbus, but setcap might allow user)
# We run as root here to ensure the daemon is unhindered.
/usr/bin/gpservice >> "$DEBUG_LOG" 2>&1 &

# 2. Start Microsocks
if [ "$VPN_MODE" = "socks" ] || [ "$VPN_MODE" = "standard" ]; then
    log "INFO" "Starting Microsocks on port 1080..."
    su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
else
    log "INFO" "Microsocks disabled by mode '$VPN_MODE'."
fi

# 3. Start Python Server
log "INFO" "Starting Python Control Server..."
su - gpuser -c "export LOG_LEVEL='$LOG_LEVEL'; python3 /var/www/html/server.py >> \"$DEBUG_LOG\" 2>&1 &"

# --- 5. MAIN LOOP ---
echo "idle" > "$MODE_FILE"
while true; do
    log "DEBUG" "Waiting for start signal..."
    read _ < "$PIPE_CONTROL"
    log "INFO" "Signal received. Starting gpclient..."
    echo "active" > "$MODE_FILE"

    # RUN AS GPUSER
    # 1. We rely on 'setcap' to allow network changes (tun0).
    # 2. We rely on the /etc/ssl/openssl.cnf patch for the SSL fix.

    > "$LOG_FILE"
    chown gpuser:gpuser "$LOG_FILE"

    su - gpuser -c "
        export VPN_PORTAL=\"$VPN_PORTAL\"
        export GP_ARGS=\"$GP_ARGS\"
        exec 3<> \"$PIPE_STDIN\"

        # Note: We do NOT need --fix-openssl anymore as we patched the system config
        CMD=\"stdbuf -oL -eL gpclient connect \\\"\$VPN_PORTAL\\\" --browser remote \$GP_ARGS\"

        echo \"[Entrypoint Subshell] Launching: \$CMD\" >> \"$DEBUG_LOG\"
        script -q -c \"\$CMD\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1
    "

    log "WARN" "gpclient process exited."
    echo "idle" > "$MODE_FILE"
    sleep 2
done