#!/bin/bash
set -e

# 1. Start SOCKS5 proxy in the background
# -i 0.0.0.0: Listen on all interfaces so Docker host can see it
# -p 1080: Port 1080
echo "Starting Microsocks Proxy on port 1080..."
microsocks -i 0.0.0.0 -p 1080 > /dev/null 2>&1 &

# 2. Connect to VPN
# --browser remote: Generates the URL you need to copy-paste
# --fix-openssl: Helps with legacy server renegotiation
echo "----------------------------------------------------------------------"
echo "Initializing GlobalProtect connection to: $VPN_PORTAL"
echo "PLEASE CHECK CONTAINER LOGS FOR THE AUTHENTICATION URL."
echo "----------------------------------------------------------------------"

# We use 'exec' so the VPN client becomes the main process (PID 1)
exec gpclient connect "$VPN_PORTAL" --browser remote --fix-openssl