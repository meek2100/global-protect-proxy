FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install runtime dependencies
#    - curl: REQUIRED for start.sh to resolve the SSO URL (Fixes "command not found")
#    - dbus-x11: Fixes "No such file" errors for D-Bus
#    - xvfb: Virtual display for the GUI
#    - vpnc-scripts & gnome-keyring: GlobalProtect dependencies
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    ca-certificates \
    microsocks \
    python3 \
    iptables \
    iproute2 \
    libcap2-bin \
    libgtk-3-0 \
    libwebkit2gtk-4.1-0 \
    libayatana-appindicator3-1 \
    librsvg2-common \
    vpnc-scripts \
    gnome-keyring \
    xvfb \
    dbus-x11 \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 2. Download and Install the Pre-built .deb
RUN wget -q https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.1/globalprotect-openconnect_2.5.1-1_amd64.deb -O /tmp/gp.deb && \
    apt-get install -y /tmp/gp.deb && \
    rm /tmp/gp.deb

# 3. Create a non-root user 'gpuser'
RUN useradd -m -s /bin/bash gpuser

# 4. Generate Machine ID for D-Bus
RUN mkdir -p /var/lib/dbus && dbus-uuidgen > /var/lib/dbus/machine-id

# 5. Grant Network Capabilities
RUN setcap 'cap_net_admin+ep' /usr/bin/gpservice

# 6. Setup directories and permissions
RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

# 7. Copy Server Script
COPY server.py /var/www/html/server.py

# 8. Setup start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8001

ENTRYPOINT ["/start.sh"]