#!/bin/bash
# Triggered by the OS when a globalprotectcallback:// link is opened
echo "Received Protocol: $1" >> /tmp/gp-logs/vpn.log
echo "$1" > /tmp/gp-stdin