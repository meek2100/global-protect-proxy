# File: Dockerfile
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
RUN git clone --branch v2.5.1 https://github.com/yuezk/GlobalProtect-openconnect.git . && \
    git submodule init && \
    git config submodule.crates/openconnect/deps/libxml2.url https://github.com/GNOME/libxml2.git && \
    git submodule update --recursive

# Set shell to bash with pipefail for safety in next commands
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# PATCH: Disable Root Check
RUN grep -rl "cannot be run as root" . | xargs sed -i 's/if.*root.*/if false {/'

# PATCH: Force no_gui mode in gpservice
RUN sed -i 's/let no_gui = false;/let no_gui = true;/' apps/gpservice/src/cli.rs

# --- COMPILATION (Optimized) ---
ENV CARGO_PROFILE_RELEASE_LTO=thin \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_PANIC=abort

# Create a tiny healthcheck binary
RUN echo 'fn main() { if std::net::TcpStream::connect("127.0.0.1:8001").is_ok() { std::process::exit(0); } else { std::process::exit(1); } }' > healthcheck.rs && \
    rustc -O healthcheck.rs -o healthcheck

# Build all binaries and strip in one layer
RUN cargo build --release --bin gpclient --no-default-features && \
    cargo build --release --bin gpservice && \
    cargo build --release --bin gpauth --no-default-features && \
    strip target/release/gpclient target/release/gpservice target/release/gpauth

# --- Runtime Stage ---
# CHANGED: Use official Python 3.14 image
FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive
# OPTIMIZATION: Prevent Python from writing .pyc files to disk
ENV PYTHONDONTWRITEBYTECODE=1

# MINIMAL RUNTIME DEPENDENCIES
# - python3: Already provided by base image
# - microsocks: Required for SOCKS5 proxy
# - vpnc-scripts: Required by openconnect
# - iptables/iproute2: Required for networking
# - sudo: Required for privilege escalation wrapper
RUN apt-get update && apt-get install -y \
    microsocks iptables iproute2 util-linux procps tzdata \
    vpnc-scripts ca-certificates \
    libxml2 libgnutls30t64 liblz4-1 libpsl5 libsecret-1-0 openssl \
    sudo \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash gpuser

# Configure strict passwordless sudo for gpuser
# Only allow gpclient and pkill, not ALL
RUN echo "gpuser ALL=(root) NOPASSWD: /usr/bin/gpclient, /usr/bin/pkill" > /etc/sudoers.d/gpuser && \
    chmod 0440 /etc/sudoers.d/gpuser

# Combine COPY instructions
COPY --from=builder \
    /usr/src/app/target/release/gpclient \
    /usr/src/app/target/release/gpservice \
    /usr/src/app/target/release/gpauth \
    /usr/bin/

# Copy the binary
COPY --from=builder /usr/src/app/healthcheck /usr/bin/healthcheck

# Set capabilities and refresh library cache
# 'ldconfig' is crucial here so gpservice finds libs without LD_LIBRARY_PATH
# OPTIMIZATION: Install libcap, apply caps, then UNINSTALL it in one layer
RUN apt-get update && apt-get install -y --no-install-recommends libcap2-bin && \
    setcap 'cap_net_admin,cap_net_bind_service+ep' /usr/bin/gpservice && \
    apt-get remove -y libcap2-bin && \
    apt-get autoremove -y && \
    ldconfig && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

# OPTIMIZATION: Combine App file copies
COPY server.py index.html /var/www/html/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

# Update Healthcheck instruction
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD /usr/bin/healthcheck || exit 1

EXPOSE 1080 8001
ENTRYPOINT ["/entrypoint.sh"]
