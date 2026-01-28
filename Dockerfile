# --- Build Stage ---
FROM rust:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Build Dependencies
# We include libwebkit2gtk-4.1-dev here as a safety net.
# Even though we build with --no-default-features, having the headers prevents
# 'pkg-config' errors if the build script checks environment before features.
RUN apt-get update && apt-get install -y \
    build-essential cmake git \
    libssl-dev libxml2-dev \
    libopenconnect-dev \
    libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
    patch gettext autopoint bison flex \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app
RUN git clone --branch v2.5.1 --recursive https://github.com/yuezk/GlobalProtect-openconnect.git .

# PATCH: Disable Root Check
RUN grep -rl "cannot be run as root" . | xargs sed -i 's/if.*root.*/if false {/'

# PATCH: Force no_gui mode in gpservice
# This ensures gpservice doesn't try to pop up windows.
RUN sed -i 's/let no_gui = false;/let no_gui = true;/' apps/gpservice/src/cli.rs

# --- COMPILATION (The Magic Step) ---

# 1. Build gpclient (CLI Client)
# --no-default-features: Disables "webview-auth" (cleans up help text/flags)
RUN cargo build --release --bin gpclient --no-default-features

# 2. Build gpservice (Background Service)
RUN cargo build --release --bin gpservice

# 3. Build gpauth (Authenticator)
# --no-default-features: CRITICAL. This drops Tauri/WebKit/GTK.
# Result: A tiny binary that only does CLI/SAML auth.
RUN cargo build --release --bin gpauth --no-default-features

# --- Runtime Stage ---
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# MINIMAL RUNTIME DEPENDENCIES
# We explicitly EXCLUDE libwebkit2gtk, libgtk-3, and X11 libs.
# Since we built with --no-default-features, the binaries will not link to them.
RUN apt-get update && apt-get install -y \
    microsocks python3 iptables iproute2 \
    vpnc-scripts ca-certificates \
    libxml2 libgnutls30t64 liblz4-1 libpsl5 libsecret-1-0 openssl \
    sudo \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash gpuser

# Configure passwordless sudo for gpuser
RUN echo "gpuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/gpuser && \
    chmod 0440 /etc/sudoers.d/gpuser

# Copy the binaries
COPY --from=builder /usr/src/app/target/release/gpclient /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/bin/

# Set capabilities for gpservice
RUN apt-get update && apt-get install -y libcap2-bin && \
    setcap 'cap_net_admin,cap_net_bind_service+ep' /usr/bin/gpservice && \
    apt-get remove -y libcap2-bin && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

EXPOSE 1080 8001
ENTRYPOINT ["/entrypoint.sh"]