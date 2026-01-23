# Use Debian Bookworm (Stable)
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Runtime Dependencies
# We install 'curl' to download the .deb
# apt will automatically pull in the GUI libs (libgtk-3-0) required by the binary
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    microsocks \
    iproute2 \
    iptables \
    python3 \
    --no-install-recommends

# 2. Download and Install the Official Release (v2.5.1)
# This bypasses the compilation errors entirely.
WORKDIR /tmp
RUN curl -LO https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.1/globalprotect-openconnect_2.5.1-1_amd64.deb && \
    apt-get install -y ./globalprotect-openconnect_2.5.1-1_amd64.deb && \
    rm globalprotect-openconnect_2.5.1-1_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

# 3. Setup Environment
RUN mkdir -p /var/www/html

COPY start.sh /start.sh
RUN chmod +x /start.sh

# Expose SOCKS5 (1080) and Dashboard (8001)
EXPOSE 1080 8001

ENTRYPOINT ["/start.sh"]