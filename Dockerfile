# --- Build Stage ---
FROM rust:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Build Dependencies
RUN apt-get update && apt-get install -y \
    build-essential cmake git binutils \
    libssl-dev libxml2-dev \
    libopenconnect-dev \
    libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
    patch gettext autopoint bison flex \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# --- FIX: Use GitHub Mirror for libxml2 ---
# The upstream server (gitlab.gnome.org) is returning 502 errors.
# We clone the main repo, then manually point libxml2 to the GitHub mirror before updating submodules.
RUN git clone --branch v2.5.1 https://github.com/yuezk/GlobalProtect-openconnect.git . && \
    git submodule init && \
    git config submodule.crates/openconnect/deps/libxml2.url https://github.com/GNOME/libxml2.git && \
    git submodule update --recursive

# PATCH: Disable Root Check
RUN grep -rl "cannot be run as root" . | xargs sed -i 's/if.*root.*/if false {/'

# PATCH: Force no_gui mode in gpservice
RUN sed -i 's/let no_gui = false;/let no_gui = true;/' apps/gpservice/src/cli.rs

# --- COMPILATION (Optimized) ---
# Use 'thin' LTO to avoid OOM crashes on GitHub Runners
ENV CARGO_PROFILE_RELEASE_LTO=thin \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_PANIC=abort

# 1. Build gpclient
RUN cargo build --release --bin gpclient --no-default-features

# 2. Build gpservice
RUN cargo build --release --bin gpservice

# 3. Build gpauth (Headless)
RUN cargo build --release --bin gpauth --no-default-features

# OPTIMIZATION: Strip debug symbols (Reduces size by ~30-40%)
RUN strip target/release/gpclient target/release/gpservice target/release/gpauth

# --- Runtime Stage ---
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# MINIMAL RUNTIME DEPENDENCIES
# Explicitly install iproute2 and ensure it stays.
RUN apt-get update && apt-get install -y \
    microsocks python3 iptables iproute2 util-linux \
    vpnc-scripts ca-certificates \
    libxml2 libgnutls30t64 liblz4-1 libpsl5 libsecret-1-0 openssl \
    sudo \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash gpuser

# Configure passwordless sudo for gpuser
RUN echo "gpuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/gpuser && \
    chmod 0440 /etc/sudoers.d/gpuser

# Combine COPY instructions
COPY --from=builder \
    /usr/src/app/target/release/gpclient \
    /usr/src/app/target/release/gpservice \
    /usr/src/app/target/release/gpauth \
    /usr/bin/

# Set capabilities for gpservice
# FIX: Do NOT run 'autoremove' here. It deletes iproute2.
# We simply install setcap, use it, and leave it (it's tiny).
RUN apt-get update && apt-get install -y libcap2-bin && \
    setcap 'cap_net_admin,cap_net_bind_service+ep' /usr/bin/gpservice && \
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