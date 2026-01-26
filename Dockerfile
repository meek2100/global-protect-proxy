# --- Build Stage ---
FROM rust:bookworm AS builder

# 1. Install Build Dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    file \
    libssl-dev \
    libxml2-dev \
    libwebkit2gtk-4.1-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    libxdo-dev \
    libopenconnect-dev \
    patch \
    gettext \
    autopoint \
    bison \
    flex \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# 2. Clone source code (v2.5.1)
RUN git clone --branch v2.5.1 --recursive https://github.com/yuezk/GlobalProtect-openconnect.git .

# 3. Build the application (Headless)
#    BUILD_GUI=0: Don't build the GUI app
#    BUILD_FE=0: Don't build the frontend assets
RUN make build BUILD_GUI=0 BUILD_FE=0


# --- Runtime Stage ---
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Runtime Dependencies
#    - microsocks: For the SOCKS5 proxy functionality
#    - python3: For the local webserver (server.py)
#    - iptables/iproute2: For Gateway NAT
#    - openconnect/vpnc-scripts: Runtime support for VPN
#    - libwebkit2gtk-4.1-0: Shared library often required by the binary even in CLI mode
RUN apt-get update && apt-get install -y \
    microsocks \
    python3 \
    iptables \
    iproute2 \
    libcap2-bin \
    curl \
    ca-certificates \
    libwebkit2gtk-4.1-0 \
    libayatana-appindicator3-1 \
    vpnc-scripts \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 2. Create non-root user
RUN useradd -m -s /bin/bash gpuser

# 3. Copy Binaries
#    Crucial: We MUST copy 'gpgui-helper' even for headless use,
#    otherwise gpservice crashes on startup version check.
COPY --from=builder /usr/src/app/target/release/gpclient /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpgui-helper /usr/bin/

# 4. Grant Network Capabilities
#    Allows 'gpservice' to manage tun0 without running as full root
RUN setcap 'cap_net_admin+ep' /usr/bin/gpservice

# 5. Setup Directories & Permissions
RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

# 6. Copy Web Interface
COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html

# 7. Install Start Script
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8001
ENTRYPOINT ["/start.sh"]
