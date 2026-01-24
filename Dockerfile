FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install runtime dependencies
#    - vpnc-scripts & gnome-keyring: Required dependencies that caused your previous error
#    - libcap2-bin: For setting capabilities (network permissions)
#    - python3: For the status dashboard
#    - microsocks: For the proxy
RUN apt-get update && apt-get install -y \
    wget \
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
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 2. Download and Install the Pre-built .deb
#    We use '|| true' on dpkg to allow it to fail on dependencies, then 'apt-get install -f' fixes them.
#    However, installing dependencies first (above) is cleaner.
RUN wget -q https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.1/globalprotect-openconnect_2.5.1-1_amd64.deb -O /tmp/gp.deb && \
    apt-get install -y /tmp/gp.deb && \
    rm /tmp/gp.deb

# 3. Create a non-root user 'gpuser'
RUN useradd -m -s /bin/bash gpuser

# 4. Grant Network Capabilities to the binary
#    This allows 'gpservice' to manage the VPN interface (tun0) without running as root.
RUN setcap 'cap_net_admin+ep' /usr/bin/gpservice

# 5. Setup directories and permissions
RUN mkdir -p /var/www/html /tmp/gp-logs && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs

# 6. Setup start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8001

ENTRYPOINT ["/start.sh"]