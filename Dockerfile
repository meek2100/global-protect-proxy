# Stage 1: Build (The "Kitchen Sink" Builder)
FROM rust:1.85-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install ALL build dependencies, including GUI libs to satisfy the compiler
RUN apt-get update && apt-get install -y \
    libopenconnect-dev \
    build-essential \
    git \
    clang \
    cmake \
    libssl-dev \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libappindicator3-dev \
    --no-install-recommends

WORKDIR /usr/src/app

# Clone the STABLE release (v2.5.1) to avoid unstable 'master' patch errors
RUN git clone --branch v2.5.1 --depth 1 https://github.com/yuezk/GlobalProtect-openconnect.git .

# Build everything (we build 'release' to optimize size)
# We STILL use --no-default-features to try and minimize runtime linking
RUN cargo build --release -p gpclient --no-default-features
RUN cargo build --release -p gpauth --no-default-features
RUN cargo build --release -p gpservice

# Stage 2: Runtime (Minimal)
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies required for VPN + Headerless Browser Support
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

RUN mkdir -p /etc/gpservice

EXPOSE 1080 8000

ENTRYPOINT ["/start.sh"]