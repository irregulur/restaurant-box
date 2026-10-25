#!/usr/bin/env bash
# install-cams.sh — install go2rtc on the node that sits next to the DVR (site B).
# Usage: ./install-cams.sh                 # just install + start with the template
#        ./install-cams.sh cam1 rtsp://... # install and set a stream in one go
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

command -v ffprobe >/dev/null || { echo "installing ffmpeg..."; sudo pacman -S --needed --noconfirm ffmpeg; }

id -u go2rtc >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin go2rtc

if [ ! -x /usr/local/bin/go2rtc ]; then
    echo "fetching latest go2rtc release..."
    url=$(curl -fsSL https://api.github.com/repos/AlexxIT/go2rtc/releases/latest \
          | grep -o 'https://[^"]*go2rtc_linux_amd64[^"]*' | head -1)
    [ -n "$url" ] || { echo "could not resolve release URL; download manually from github.com/AlexxIT/go2rtc"; exit 1; }
    curl -fsSL "$url" -o /tmp/go2rtc && sudo install -m755 /tmp/go2rtc /usr/local/bin/go2rtc
fi

sudo mkdir -p /etc/go2rtc
[ -f /etc/go2rtc/go2rtc.yaml ] || sudo install -m644 "$SRC/go2rtc.yaml" /etc/go2rtc/go2rtc.yaml
sudo install -m644 "$SRC/go2rtc.service" /etc/systemd/system/go2rtc.service

if [ $# -ge 2 ]; then
    name="$1"; url="$2"
    sudo grep -q "^  $name:" /etc/go2rtc/go2rtc.yaml \
        && sudo sed -i "s|^  $name:.*|  $name: $url|" /etc/go2rtc/go2rtc.yaml \
        || sudo sed -i "/^streams:/a\\  $name: $url" /etc/go2rtc/go2rtc.yaml
    echo "stream '$name' -> $url"
fi

sudo systemctl daemon-reload
sudo systemctl enable --now go2rtc.service
sleep 1
sudo systemctl --no-pager --lines=5 status go2rtc.service || true
echo
echo "view from anywhere on the tailnet:  http://$(hostname):1984/streams.html"
echo "single stream / kiosk:              http://$(hostname):1984/stream.html?src=cam1&mode=webrtc"
