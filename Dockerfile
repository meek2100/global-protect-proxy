# --- Build Stage ---
FROM rust:trixie AS builder

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
RUN git clone --branch v2.5.1 --recursive https://github.com/yuezk/GlobalProtect-openconnect.git .
RUN sed -i 's/let no_gui = false;/let no_gui = true;/' apps/gpservice/src/cli.rs
RUN make build BUILD_GUI=0 BUILD_FE=0

# --- Runtime Stage ---
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Trixie uses updated library names (e.g., libglib2.0-0t64)
RUN apt-get update && apt-get install -y \
    microsocks python3 iptables iproute2 net-tools \
    iputils-ping traceroute dnsutils curl procps \
    vpnc-scripts ca-certificates libxml2 \
    libgnutls30t64 \
    liblz4-1 libpsl5 libsecret-1-0 file openssl \
    libgtk-3-0 libwebkit2gtk-4.1-0 \
    libjavascriptcoregtk-4.1-0 libsoup-3.0-0 \
    libayatana-appindicator3-1 librsvg2-common \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash gpuser
COPY --from=builder /usr/src/app/target/release/gpclient /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/bin/

RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Ensure the library path points to Trixie's architecture directories
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

EXPOSE 1080 8001
ENTRYPOINT ["/start.sh"]