# Build Stage
FROM rust:1.85-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libssl-dev \
    libgtk-3-dev \
    libwebkit2gtk-4.0-dev \
    libayatana-appindicator3-dev \
    liblz4-dev \
    libgnutls28-dev \
    automake \
    autoconf \
    libtool \
    pkg-config \
    libxml2-dev \
    patch \
    gettext \
    autopoint \
    bison \
    flex \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Clone source code from GitHub
RUN git clone --branch v2.5.1 --recursive https://github.com/yuezk/GlobalProtect-openconnect.git .

# Build the application
RUN make build BUILD_GUI=0 BUILD_FE=0

# Runtime Stage
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    microsocks \
    python3 \
    iproute2 \
    iptables \
    libgtk-3-0 \
    ca-certificates \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Copy binaries
COPY --from=builder /usr/src/app/target/release/gpclient /usr/local/bin/
COPY --from=builder /usr/src/app/target/release/gpservice /usr/local/bin/
COPY --from=builder /usr/src/app/target/release/gpauth /usr/local/bin/

# Setup start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Expose ports
EXPOSE 1080 8001

ENTRYPOINT ["/start.sh"]
