# Stage 1: Build the headless client (approx 5-10 mins build time)
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

# Clone the repo and build ONLY the CLI (skipping GUI to save deps)
RUN git clone https://github.com/yuezk/GlobalProtect-openconnect.git . && \
    make build BUILD_GUI=0 BUILD_FE=0

# Stage 2: Runtime image (Small Debian Trixie)
FROM debian:trixie-slim

# Install runtime libs and microsocks
RUN apt-get update && apt-get install -y \
    libopenconnect5 \
    ca-certificates \
    microsocks \
    curl \
    iproute2 \
    iptables \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Copy the compiled binary
COPY --from=builder /usr/src/app/target/release/gpclient /usr/local/bin/gpclient

# Copy startup script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Expose SOCKS5 port
EXPOSE 1080

ENTRYPOINT ["/start.sh"]