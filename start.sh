#!/bin/bash
set -e

STATUS_FILE="/var/www/html/status.json"
LOG_FILE="/tmp/gp-logs/vpn.log"
DISPLAY=:1
export DISPLAY

write_state() {
    CLEAN_LOG=$(tail -n 10 "$LOG_FILE" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
    cat <<JSON > "$STATUS_FILE.tmp"
{ "state": "$1", "log": "$CLEAN_LOG" }
JSON
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

echo "=== Container Started ==="
rm -f /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control
mkfifo /tmp/gp-stdin /tmp/gp-control
touch /var/run/gpservice.lock "$LOG_FILE"
chown gpuser:gpuser /var/run/gpservice.lock /tmp/gp-stdin /tmp/gp-control "$LOG_FILE"
chmod 666 /tmp/gp-stdin /tmp/gp-control

# 1. Start GUI Stack
Xvfb $DISPLAY -screen 0 1280x800x24 &
sleep 1
openbox &
x11vnc -display $DISPLAY -forever -shared -nopw -quiet -bg
/opt/novnc/utils/websockify/run 8002 localhost:5900 --web /opt/novnc &

# 2. Start Services
su - gpuser -c "microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &"
su - gpuser -c "python3 /var/www/html/server.py > /tmp/gp-logs/web.log 2>&1 &"
su - gpuser -c "gpservice &"
sleep 2

write_state "idle"

# 3. Wait for Connect
read _ < /tmp/gp-control
write_state "connecting"

su - gpuser -c "
    exec 3<> /tmp/gp-stdin
    VPN_PORTAL=\"$VPN_PORTAL\"
    > \"$LOG_FILE\"

    # Start Client with TTY fix
    script -q -c \"gpclient --fix-openssl connect \$VPN_PORTAL --browser remote\" /dev/null <&3 >> \"$LOG_FILE\" 2>&1 &
    CLIENT_PID=\$!

    BROWSER_LAUNCHED=0

    while kill -0 \$CLIENT_PID 2>/dev/null; do
        if [ \$BROWSER_LAUNCHED -eq 0 ] && grep -q \"https://\" \"$LOG_FILE\"; then
             AUTH_URL=\$(grep -o \"https://[^ ]*\" \"$LOG_FILE\" | head -1)
             echo \"Opening Browser...\" >> \"$LOG_FILE\"
             firefox --new-window \"\$AUTH_URL\" &
             BROWSER_LAUNCHED=1
        fi
        if grep -q \"Connected\" \"$LOG_FILE\"; then
             pkill firefox
             echo \"VPN CONNECTED\" >> \"$LOG_FILE\"
        fi
        sleep 1
    done
" &

while true; do
    if grep -q "Connected" "$LOG_FILE"; then STATE="connected";
    elif grep -q "https://" "$LOG_FILE"; then STATE="auth";
    else STATE="connecting"; fi
    write_state "$STATE"
    sleep 2
done