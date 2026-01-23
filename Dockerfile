# Stage 1: Build the headless client and service
FROM rust:1.85-bookworm AS builder

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
# libgtk-3-dev is REQUIRED for linking gpclient/gpauth, even if we disable the GUI.
RUN apt-get update && apt-get install -y \
    libopenconnect-dev \
    build-essential \
    git \
    clang \
    cmake \
    libssl-dev \
    libgtk-3-dev \
    --no-install-recommends

WORKDIR /usr/src/app

# Clone the specific STABLE release tag (v2.5.1)
# Using 'master' causes patch failures as upstream changes break the build.
RUN git clone --branch v2.5.1 --depth 1 https://github.com/yuezk/GlobalProtect-openconnect.git .

# ---------------------------------------------------------------------
# BUILD STEPS
# ---------------------------------------------------------------------

# 1. Build gpclient
#    --no-default-features: Disables 'webview-auth' (embedded browser window).
RUN cargo build --release -p gpclient --no-default-features

# 2. Build gpauth
#    --no-default-features: Disables embedded webview, forcing external browser auth.
RUN cargo build --release -p gpauth --no-default-features

# 3. Build gpservice
#    The background daemon that manages the interface.
RUN cargo build --release -p gpservice

# Stage 2: Runtime image
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime libs
# libgtk-3-0 is required for the binaries to start (shared library linking)
RUN apt-get update && apt-get install -y \
    libopenconnect5 \
    ca-certificates \
    microsocks \
    curl \
    iproute2 \
    iptables \
    libgtk-3-0 \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Copy binaries
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