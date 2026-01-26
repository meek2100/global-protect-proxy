#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"
DISPLAY=:1
export DISPLAY

# --- HELPER: Write State ---
write_state() {
    cat <<JSON > "$STATUS_FILE.tmp"
{
  "state": "$1",
  "log": "$(tail -n 10 $LOG_FILE | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')"
}
JSON
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

echo "=== Container Started ==="

# 1. Setup Files & Perms
rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control
mkfifo /tmp/gp-stdin /tmp/gp-control
touch /var/run/gpservice.lock "$LOG_FILE"
chown gpuser:gpuser /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control "$LOG_FILE"
chmod 666 /tmp/gp-stdin /tmp/gp-control

# 2. Start X11 / Window Manager / VNC
echo "Starting Display Server..."
Xvfb $DISPLAY -screen 0 1280x800x24 &
sleep 1
openbox &  # Minimal window manager for the browser

echo "Starting VNC Server..."
# -forever: keep listening
# -shared: allow multiple viewers
x11vnc -display $DISPLAY -forever -shared -nopw -quiet -bg

echo "Starting noVNC Bridge..."
# Proxy localhost:5900 (VNC) to 0.0.0.0:8002 (Websocket)
/opt/novnc/utils/websockify/run 8002 localhost:5900 --web /opt/novnc &

# 3. Start VPN Services
echo "Starting VPN Services..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"
su - gpuser -c "gpservice &" # No xvfb-run needed, DISPLAY is exported globally
sleep 2

write_state "idle"

# 4. Main Logic Loop
echo "Ready. Waiting for user..."
read _ < /tmp/gp-control

write_state "connecting"

su - gpuser -c "
    exec 3<> /tmp/gp-stdin
    VPN_PORTAL=\"$VPN_PORTAL\"
    > \"$LOG_FILE\"

    # 1. Start VPN Client (Background)
    #    We use 'script' to fake TTY
    script -q -c \"gpclient --fix-openssl connect \$VPN_PORTAL --browser remote\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
    CLIENT_PID=\$!

    # 2. Monitor Log for SSO URL
    BROWSER_LAUNCHED=0

    while kill -0 \$CLIENT_PID 2>/dev/null; do

        # Check for URL to open
        if [ \$BROWSER_LAUNCHED -eq 0 ] && grep -q \"https://\" \"$LOG_FILE\"; then
             # Extract the AUTH URL
             AUTH_URL=\$(grep -o \"https://[^ ]*\" \"$LOG_FILE\" | head -1)
             echo \"Opening Browser to: \$AUTH_URL\" >> \"$LOG_FILE\"

             # LAUNCH FIREFOX INSIDE THE CONTAINER
             # It will appear on the VNC screen
             firefox --new-window \"\$AUTH_URL\" &
             BROWSER_LAUNCHED=1

             # Notify UI we are in Auth mode
             # (We invoke write_state via a temp file hack or similar,
             # but here we rely on the loop updating logs)
        fi

        # Check for Success
        if grep -q \"Connected\" \"$LOG_FILE\"; then
             # Close Firefox to save RAM
             pkill firefox
             echo \"VPN CONNECTED SUCCESSFULLY\" >> \"$LOG_FILE\"
        fi

        sleep 1
    done
" &

# Monitoring Loop to update JSON status
while true; do
    if grep -q "Connected" "$LOG_FILE"; then STATE="connected";
    elif grep -q "https://" "$LOG_FILE"; then STATE="auth";
    else STATE="connecting"; fi

    write_state "$STATE"
    sleep 2
done