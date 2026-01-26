# --- Build Stage (Heavy) ---
FROM rust:bookworm AS builder

# Install build dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
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

# Clone source (v2.5.1)
RUN git clone --branch v2.5.1 --recursive https://github.com/yuezk/GlobalProtect-openconnect.git .

# Build CLI only (Headless)
RUN make build BUILD_GUI=0 BUILD_FE=0


# --- Runtime Stage (Slim) ---
# Using Debian Trixie Slim as requested (or use bookworm-slim for stable)
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install ABSOLUTE MINIMUM runtime dependencies
#    - microsocks: Proxy
#    - python3: Web interface & URL resolution
#    - iptables/iproute2: Network/VPN routing
#    - vpnc-scripts: Required by OpenConnect for setting DNS/Routes
#    - ca-certificates: For SSL
#    - libxml2: Likely required by gpclient
#    Note: NO libwebkit or libgtk!
RUN apt-get update && apt-get install -y \
    microsocks \
    python3 \
    iptables \
    iproute2 \
    libcap2-bin \
    vpnc-scripts \
    ca-certificates \
    libxml2 \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 2. Create User
RUN useradd -m -s /bin/bash gpuser

# 3. Copy Only CLI Binaries
COPY --from=builder /usr/src/app/target/release/gpclient /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/bin/

# 4. OPTIMIZATION: Mock the GUI Helper
#    The real binary requires 500MB+ of GTK/WebKit libraries.
#    We replace it with a dummy script that simply exits successfully.
#    This satisfies the 'check_version' and 'launch' checks in gpservice.
RUN echo '#!/bin/sh\nexit 0' > /usr/bin/gpgui-helper && \
    chmod +x /usr/bin/gpgui-helper

# 5. Setup Permissions (One-layer optimization)
#    - Create directories
#    - Set capabilities
#    - Cleanup libcap2-bin to save space
RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus && \
    setcap 'cap_net_admin+ep' /usr/bin/gpservice && \
    apt-get purge -y libcap2-bin && \
    apt-get autoremove -y

# 6. Copy Scripts
COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8001
ENTRYPOINT ["/start.sh"]