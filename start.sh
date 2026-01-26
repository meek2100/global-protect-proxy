#!/bin/bash
set -e

# --- CONFIG ---
STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"
DISPLAY=:1
export DISPLAY

# --- HELPER: Write State ---
write_state() {
    # Extract clean logs for the UI
    CLEAN_LOG=$(tail -n 10 "$LOG_FILE" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
    cat <<JSON > "$STATUS_FILE.tmp"
{
  "state": "$1",
  "log": "$CLEAN_LOG"
}
JSON
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

echo "=== Container Started ==="

# 1. Setup Files & Permissions
rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control
mkfifo /tmp/gp-stdin /tmp/gp-control
touch /var/run/gpservice.lock "$LOG_FILE"
chown gpuser:gpuser /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control "$LOG_FILE"
chmod 666 /tmp/gp-stdin /tmp/gp-control

# 2. Start X11 / Window Manager / VNC (The Visual Stack)
echo "Starting Display Server..."
Xvfb $DISPLAY -screen 0 1280x800x24 &
sleep 1
openbox &  # Minimal window manager

echo "Starting VNC Server..."
x11vnc -display $DISPLAY -forever -shared -nopw -quiet -bg

echo "Starting noVNC Bridge..."
/opt/novnc/utils/websockify/run 8002 localhost:5900 --web /opt/novnc &

# 3. Start VPN Services
echo "Starting VPN Services..."
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"
su - gpuser -c "gpservice &"
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

    # A. Start VPN Client (Background)
    #    The handler script will write to /tmp/gp-stdin (fd 3) automatically.
    #    We rely on 'script' to fake a TTY for initial output stability.
    script -q -c \"gpclient --fix-openssl connect \$VPN_PORTAL --browser remote\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
    CLIENT_PID=\$!

    # B. Monitor Log for SSO URL
    BROWSER_LAUNCHED=0

    while kill -0 \$CLIENT_PID 2>/dev/null; do

        # Check if we need to open the browser
        if [ \$BROWSER_LAUNCHED -eq 0 ] && grep -q \"https://\" \"$LOG_FILE\"; then
             # Extract the SSO URL
             AUTH_URL=\$(grep -o \"https://[^ ]*\" \"$LOG_FILE\" | head -1)
             echo \"Opening Browser to: \$AUTH_URL\" >> \"$LOG_FILE\"

             # LAUNCH FIREFOX (It will appear in VNC)
             firefox --new-window \"\$AUTH_URL\" &
             BROWSER_LAUNCHED=1
        fi

        # Check for Success
        if grep -q \"Connected\" \"$LOG_FILE\"; then
             # Close Firefox to save resources
             pkill firefox
             echo \"VPN CONNECTED SUCCESSFULLY\" >> \"$LOG_FILE\"
        fi

        sleep 1
    done
" &

# Monitoring Loop for UI updates
while true; do
    if grep -q "Connected" "$LOG_FILE"; then STATE="connected";
    elif grep -q "https://" "$LOG_FILE"; then STATE="auth";
    else STATE="connecting"; fi

    write_state "$STATE"
    sleep 2
done