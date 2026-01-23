FROM rust:1.85-bookworm AS builder

# 1. Install build tools
# We must install these because the Docker container is empty.
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libssl-dev \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libappindicator3-dev \
    automake \
    autoconf \
    libtool \
    pkg-config \
    libxml2-dev \
    patch \
    --no-install-recommends

WORKDIR /usr/src/app

# 2. Clone the Stable Release (v2.5.1)
RUN git clone --branch v2.5.1 --depth 1 https://github.com/yuezk/GlobalProtect-openconnect.git .

# 3. Initialize Submodules (Critical for openconnect-sys)
RUN git submodule update --init --recursive

# 4. Build using the Official Makefile
# We disable GUI and FE to save space/time, but we installed the deps above so it won't crash.
RUN make build BUILD_GUI=0 BUILD_FE=0

# --- Runtime Stage ---
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    libopenconnect5 \
    ca-certificates \
    microsocks \
    curl \
    iproute2 \
    iptables \
    libgtk-3-0 \
    python3 \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Copy binaries
COPY --from=builder /usr/src/app/target/release/gpclient /usr/local/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/local/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/local/bin/

# Setup Environment
RUN mkdir -p /etc/gpservice /var/www/html
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8000
ENTRYPOINT ["/start.sh"]