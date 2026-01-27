# --- Build Stage ---
FROM rust:bookworm AS builder

# Install build dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential cmake git \
    libssl-dev libxml2-dev \
    libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
    libopenconnect-dev \
    patch gettext autopoint bison flex \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Clone source (v2.5.1)
RUN git clone --branch v2.5.1 --recursive https://github.com/yuezk/GlobalProtect-openconnect.git .

# --- PATCH: Force Headless Mode ---
# The source code hardcodes 'no_gui = false' for release builds.
# We use sed to flip this to 'true', preventing gpservice from ever trying to launch the GUI.
RUN sed -i 's/let no_gui = false;/let no_gui = true;/' apps/gpservice/src/cli.rs

# Build CLI only
# We don't need gpgui-helper anymore because our patch ensures gpservice won't call it.
RUN make build BUILD_GUI=0 BUILD_FE=0


# --- Runtime Stage (Slim) ---
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Runtime Dependencies
#    - microsocks, python3: Proxy & Web Server
#    - iptables, iproute2: Networking & NAT
#    - vpnc-scripts: OpenConnect routing scripts
#    - libgnutls30, liblz4-1: Required shared libraries for gpservice
RUN apt-get update && apt-get install -y \
    microsocks \
    python3 \
    iptables \
    iproute2 \
    libcap2-bin \
    vpnc-scripts \
    ca-certificates \
    libxml2 \
    libgnutls30 \
    liblz4-1 \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 2. Create User
RUN useradd -m -s /bin/bash gpuser

# 3. Copy Only Essential CLI Binaries
COPY --from=builder /usr/src/app/target/release/gpclient /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/bin/

# 4. Setup Permissions
RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus && \
    setcap 'cap_net_admin+ep' /usr/bin/gpservice && \
    apt-get purge -y libcap2-bin && \
    apt-get autoremove -y

# 5. Copy Scripts
COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8001
ENTRYPOINT ["/start.sh"]