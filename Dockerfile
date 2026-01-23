# Stage 1: Build the headless client and service
FROM rust:1.85-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    libopenconnect-dev \
    build-essential \
    git \
    clang \
    cmake \
    libssl-dev \
    --no-install-recommends

WORKDIR /usr/src/app

# Clone repo
RUN git clone https://github.com/yuezk/GlobalProtect-openconnect.git .

# ---------------------------------------------------------------------
# FIX: Build manually to control features
# ---------------------------------------------------------------------

# 1. Build the main VPN engine and CLI (Standard release build)
RUN cargo build --release -p gpclient -p gpservice

# 2. Build the Authentication module WITHOUT the GUI/Webview dependencies.
#    --no-default-features: Disables 'webview-auth' (GTK/GDK requirement)
#    This allows 'gpauth' to still handle the SAML handshake via external browser.
RUN cargo build --release -p gpauth --no-default-features

# Stage 2: Runtime image
FROM debian:trixie-slim

# Install runtime libs, proxy, and networking tools
# libopenconnect5 is required for the actual VPN tunnel
RUN apt-get update && apt-get install -y \
    libopenconnect5 \
    ca-certificates \
    microsocks \
    curl \
    iproute2 \
    iptables \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# COPY ALL THREE BINARIES
# We include the modified gpauth so the client can perform the SAML login
COPY --from=builder /usr/src/app/target/release/gpclient /usr/local/bin/gpclient
COPY --from=builder /usr/src/app/target/release/gpservice /usr/local/bin/gpservice
COPY --from=builder /usr/src/app/target/release/gpauth /usr/local/bin/gpauth

# Copy startup script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Create configuration directory for gpservice
RUN mkdir -p /etc/gpservice

EXPOSE 1080

ENTRYPOINT ["/start.sh"]