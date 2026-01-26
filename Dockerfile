FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Setup Mozilla PPA (Fixes Firefox Snap issues)
RUN apt-get update && apt-get install -y software-properties-common wget && \
    add-apt-repository ppa:mozillateam/ppa && \
    echo 'Package: *' > /etc/apt/preferences.d/mozilla-firefox && \
    echo 'Pin: release o=LP-PPA-mozillateam' >> /etc/apt/preferences.d/mozilla-firefox && \
    echo 'Pin-Priority: 1001' >> /etc/apt/preferences.d/mozilla-firefox

# 2. Install Dependencies
#    (util-linux added for 'script' command support)
RUN apt-get update && apt-get install -y \
    curl ca-certificates \
    microsocks python3 python3-numpy \
    iptables iproute2 \
    libcap2-bin vpnc-scripts gnome-keyring \
    xvfb dbus-x11 \
    firefox openbox x11vnc \
    libgtk-3-0 \
    libwebkit2gtk-4.1-0 \
    libayatana-appindicator3-1 \
    librsvg2-common \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# 3. Install noVNC
RUN mkdir -p /opt/novnc/utils/websockify && \
    wget -qO- https://github.com/novnc/noVNC/archive/v1.4.0.tar.gz | tar xz --strip 1 -C /opt/novnc && \
    wget -qO- https://github.com/novnc/websockify/archive/v0.11.0.tar.gz | tar xz --strip 1 -C /opt/novnc/utils/websockify

# 4. Install GlobalProtect (Using wget)
RUN wget -q https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.1/globalprotect-openconnect_2.5.1-1_amd64.deb -O /tmp/gp.deb && \
    apt-get update && \
    apt-get install -y /tmp/gp.deb && \
    rm /tmp/gp.deb

# 5. Setup User
RUN useradd -m -s /bin/bash gpuser
RUN mkdir -p /var/lib/dbus && dbus-uuidgen > /var/lib/dbus/machine-id
RUN setcap 'cap_net_admin+ep' /usr/bin/gpservice

# 6. Setup Protocol Handler
COPY gp-handler.sh /usr/local/bin/gp-handler.sh
RUN chmod +x /usr/local/bin/gp-handler.sh
RUN mkdir -p /usr/share/applications
RUN echo "[Desktop Entry]\nName=GlobalProtect Handler\nExec=/usr/local/bin/gp-handler.sh %u\nType=Application\nTerminal=false\nMimeType=x-scheme-handler/globalprotectcallback;" > /usr/share/applications/gp-handler.desktop
RUN update-desktop-database /usr/share/applications

# 7. Copy Files
RUN mkdir -p /var/www/html /tmp/gp-logs /run/dbus && \
    chown -R gpuser:gpuser /var/www/html /tmp/gp-logs /run/dbus

COPY server.py /var/www/html/server.py
COPY index.html /var/www/html/index.html
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080 8001 8002
ENTRYPOINT ["/start.sh"]