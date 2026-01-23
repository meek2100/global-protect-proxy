# Use Debian Bookworm (Stable) to ensure compatibility with the .deb package
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Runtime Dependencies & Tools
# We install 'curl' to download the .deb
# We install 'libgtk-3-0' and 'libwebkit2gtk-4.0-37' because the pre-built binary
# links against them. apt will verify and pull these in automatically.
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    microsocks \
    iproute2 \
    iptables \
    python3 \
    --no-install-recommends

# 2. Download and Install the Official .deb Release (v2.5.1)
# apt-get install ./file.deb will automatically resolve all the missing GUI dependencies
WORKDIR /tmp
RUN curl -LO https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.1/globalprotect-openconnect_2.5.1-1_amd64.deb && \
    apt-get install -y ./globalprotect-openconnect_2.5.1-1_amd64.deb && \
    rm globalprotect-openconnect_2.5.1-1_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

# 3. Setup Environment
# The official package installs binaries to /usr/bin/gpclient, etc.
RUN mkdir -p /var/www/html

# Copy your existing startup script
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8000

ENTRYPOINT ["/start.sh"]