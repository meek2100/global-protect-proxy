#!/bin/bash
# This script is triggered by the OS when a globalprotectcallback:// link is opened
# It dumps the full URL (containing the token) into the pipe the VPN client is reading.
echo "Received Protocol: $1" >> /tmp/gp-logs/vpn.log
echo "$1" > /tmp/gp-stdin