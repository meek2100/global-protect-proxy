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

# --- PATCH: Disable Root Check & Build with No GUI ---
# Prevents the client from panicking if capabilities make it look like root.
RUN grep -rl "cannot be run as root" . | xargs sed -i 's/if.*root.*/if false {/'
# ---------------------------------

# Force no_gui mode in source
RUN sed -i 's/let no_gui = false;/let no_gui = true;/' apps/gpservice/src/cli.rs
RUN make build BUILD_GUI=0 BUILD_FE=0

# --- Runtime Stage ---
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    microsocks python3 iptables iproute2 net-tools \
    iputils-ping traceroute dnsutils curl procps \
    vpnc-scripts ca-certificates libxml2 \
    libgnutls30t64 \
    liblz4-1 libpsl5 libsecret-1-0 file openssl \
    libgtk-3-0 libwebkit2gtk-4.1-0 \
    libjavascriptcoregtk-4.1-0 libsoup-3.0-0 \
    libayatana-appindicator3-1 librsvg2-common \
    libcap2-bin \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash gpuser
COPY --from=builder /usr/src/app/target/release/gpclient /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/bin/

# --- PERMISSIONS: Allow gpservice to manage network as gpuser ---
# We add cap_net_bind_service to allow binding to privileged/system ports if needed.
# Without this, gpservice fails to create tun0.
RUN setcap 'cap_net_admin,cap_net_bind_service+ep' /usr/bin/gpservice

RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

EXPOSE 1080 8001
ENTRYPOINT ["/entrypoint.sh"]