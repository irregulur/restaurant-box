#!/usr/bin/env bash
# probe.sh — find out what a DVR/NVR actually speaks before wiring anything up.
# Usage: ./probe.sh <ip> [user] [pass]
#
# Prints: open ports, which RTSP path answers, and a verdict with the next step.
# Harbor Freight / rebranded AHD kits are usually Dahua, Hikvision, Uniview or
# XMEye(Sofia) OEM boards — the four path families below cover nearly all of them.
set -uo pipefail

IP="${1:?usage: probe.sh <ip> [user] [pass]}"
USER_="${2:-admin}"
PASS="${3:-}"
[ -n "$PASS" ] && CRED="$USER_:$PASS@" || CRED=""

command -v nmap >/dev/null || { echo "need nmap: sudo pacman -S nmap"; exit 1; }
command -v ffprobe >/dev/null || { echo "need ffprobe: sudo pacman -S ffmpeg"; exit 1; }

echo "== ports on $IP =="
nmap -Pn --host-timeout 20s -p 80,554,8000,8080,8443,8554,34567,37777,9000,10080,6036,5000 "$IP" \
  | awk '/^[0-9]+\// {print}'

SOFIA=0
for p in 34567 37777; do
    nmap -Pn --host-timeout 10s -p "$p" "$IP" 2>/dev/null | grep -q "^$p/tcp *open" && SOFIA=1
done

PATHS=(
  # Dahua / Dahua-OEM (most common on cheap AHD kits)
  "/cam/realmonitor?channel=1&subtype=0"
  "/cam/realmonitor?channel=1&subtype=1"
  # Hikvision / Hik-OEM
  "/Streaming/Channels/101"
  "/Streaming/Channels/102"
  "/h264/ch1/main/av_stream"
  # Uniview
  "/media/video1"
  # AVTECH / generic
  "/live/ch0"
  "/live.sdp"
  # XiongMai boards that do expose RTSP
  "/user=$USER_&password=$PASS&channel=1&stream=0.sdp"
  "/11"
  "/onvif1"
  "/stream1"
)

echo "== RTSP probes =="
HIT=""
for path in "${PATHS[@]}"; do
    url="rtsp://${CRED}${IP}:554${path}"
    if ffprobe -v quiet -rtsp_transport tcp -timeout 6000000 \
               -show_entries stream=codec_name,width,height \
               -of csv=p=0 "$url" 2>/dev/null | head -1 | grep -q .; then
        info=$(ffprobe -v quiet -rtsp_transport tcp -timeout 6000000 \
               -show_entries stream=codec_name,width,height -of csv=p=0 "$url" 2>/dev/null | head -1)
        echo "  OK   $path   [$info]"
        [ -z "$HIT" ] && HIT="$url"
    else
        echo "  --   $path"
    fi
done

echo
if [ -n "$HIT" ]; then
    echo "VERDICT: RTSP works. Use the subtype=1 / 102 / sub path for remote viewing."
    echo "Next: ./install-cams.sh cam1 '$HIT'"
elif [ "$SOFIA" = "1" ]; then
    echo "VERDICT: looks like an XMEye/Sofia board (ports 34567/37777, no RTSP)."
    echo "RTSP is not available. Options: vendor app on a tablet, or DVR HDMI out -> encoder."
else
    echo "VERDICT: no RTSP and no Sofia port. Likely cloud-P2P only."
    echo "Options: vendor app on a tablet at the other site, or HDMI-out capture."
fi
