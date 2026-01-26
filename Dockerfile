FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Dependencies (Firefox, VNC, Window Manager)
RUN apt-get update && apt-get install -y \
    wget curl ca-certificates \
    microsocks python3 python3-numpy \
    iptables iproute2 \
    libcap2-bin vpnc-scripts gnome-keyring \
    xvfb dbus-x11 \
    firefox openbox x11vnc \
    util-linux \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 2. Install noVNC (Web-based VNC viewer)
RUN mkdir -p /opt/novnc/utils/websockify && \
    wget -qO- https://github.com/novnc/noVNC/archive/v1.4.0.tar.gz | tar xz --strip 1 -C /opt/novnc && \
    wget -qO- https://github.com/novnc/websockify/archive/v0.11.0.tar.gz | tar xz --strip 1 -C /opt/novnc/utils/websockify

# 3. Install GlobalProtect
RUN wget -q https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.1/globalprotect-openconnect_2.5.1-1_amd64.deb -O /tmp/gp.deb && \
    apt-get install -y /tmp/gp.deb && \
    rm /tmp/gp.deb

# 4. Setup User & Permissions
RUN useradd -m -s /bin/bash gpuser
RUN mkdir -p /var/lib/dbus && dbus-uuidgen > /var/lib/dbus/machine-id
RUN setcap 'cap_net_admin+ep' /usr/bin/gpservice

# 5. Setup Protocol Handler (The Automation Fix)
COPY gp-handler.sh /usr/local/bin/gp-handler.sh
RUN chmod +x /usr/local/bin/gp-handler.sh
RUN mkdir -p /usr/share/applications
# Register the handler for the specific protocol
RUN echo "[Desktop Entry]\nName=GlobalProtect Handler\nExec=/usr/local/bin/gp-handler.sh %u\nType=Application\nTerminal=false\nMimeType=x-scheme-handler/globalprotectcallback;" > /usr/share/applications/gp-handler.desktop
RUN update-desktop-database /usr/share/applications

# 6. Copy Files
RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Ports: 1080 (Proxy), 8001 (UI), 8002 (VNC)
EXPOSE 1080 8001 8002

ENTRYPOINT ["/start.sh"]