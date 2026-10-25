#!/usr/bin/env bash
# probe.sh — find out what a DVR/NVR actually speaks before wiring anything up.
# Usage: ./probe.sh <dvr-ip> [user] [pass]
#
# Run this from a laptop plugged into the DVR's switch (same LAN — the point is
# to test the DVR, not your internet).
#
# Covers the four families that rebranded AHD kits use: Dahua, Hikvision,
# Uniview, and XiongMai/XMEye (the RXCamView / gCMOB / vMEyeSuper / KMEye
# family, Sofia protocol on :34567).
#
# Options:
#   --defaults   also try a few factory password guesses (own hardware only;
#                most DVRs lock out for ~30 min after 5 wrong tries)
set -uo pipefail

DEFAULTS=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --defaults) DEFAULTS=1 ;;
        *) ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]:-}"

IP="${1:?usage: probe.sh <ip> [user] [pass] [--defaults]}"
U="${2:-admin}"
P="${3:-}"
[ -n "$P" ] && CRED="$U:$P@" || CRED=""

command -v nmap    >/dev/null || { echo "need nmap:   sudo pacman -S nmap"; exit 1; }
command -v ffprobe >/dev/null || { echo "need ffmpeg: sudo pacman -S ffmpeg"; exit 1; }

echo "== ports on $IP =="
nmap -Pn --host-timeout 25s \
     -p 80,554,8000,8080,8443,8554,8899,34567,37777,9000,10080,6036,5000 "$IP" \
  | awk '/^[0-9]+\/tcp/ {printf "  %-14s %s\n", $1, $2}'

open() { nmap -Pn --host-timeout 8s -p "$1" "$IP" 2>/dev/null | grep -q "^$1/tcp *open"; }
SOFIA=0; open 34567 && SOFIA=1

echo "== port 34567 / 37777 =="
[ "$SOFIA" = 1 ] && echo "  OPEN  -> XiongMai/XMEye (Sofia) or similar proprietary protocol." \
                 || echo "  closed"

PATHS=(
  # --- XiongMai / XMEye (RXCamView family): the path form varies by firmware ---
  "/user=${U}&password=${P}&channel=1&stream=0.sdp?real_stream"
  "/user=${U}&password=${P}&channel=1&stream=1.sdp?real_stream"
  "/user=${U}&password=${P}&channel=0&stream=0.sdp?real_stream"
  "/0"
  "/1"
  # --- Dahua / Dahua-OEM (most common on cheap AHD kits) ---
  "/cam/realmonitor?channel=1&subtype=0"
  "/cam/realmonitor?channel=1&subtype=1"
  # --- Hikvision / Hik-OEM ---
  "/Streaming/Channels/101"
  "/Streaming/Channels/102"
  "/h264/ch1/main/av_stream"
  # --- Uniview ---
  "/media/video1"
  # --- AVTECH / generic ---
  "/live/ch0"
  "/live.sdp"
  "/11"
  "/onvif1"
  "/stream1"
)

echo "== RTSP probes (port 554) =="
HIT=""
if ! open 554; then
    echo "  port 554 closed — no RTSP listener at all"
else
    for path in "${PATHS[@]}"; do
        url="rtsp://${CRED}${IP}:554${path}"
        info=$(ffprobe -v quiet -rtsp_transport tcp -timeout 6000000 \
                       -show_entries stream=codec_name,width,height -of csv=p=0 \
                       "$url" 2>/dev/null | head -1)
        if [ -n "$info" ]; then
            echo "  OK    $path   [$info]"
            [ -z "$HIT" ] && HIT="$url"
        else
            echo "  --    $path"
        fi
    done
fi

echo "== HTTP snapshot probes (cheap fallback for a 'wall of stills') =="
SNAP=""
for port in 80 8080; do
    open "$port" || continue
    for path in \
        "/webcapture.jpg?command=snap&channel=1&user=${U}&password=${P}" \
        "/webcapture.jpg?command=snap&channel=1" \
        "/snapshot.cgi?user=${U}&pwd=${P}" \
        "/cgi-bin/snapshot.cgi" \
        "/onvifsnapshot/media_service/snapshot?channel=1&subtype=0" \
        "/ISAPI/Streaming/channels/101/picture"
    do
        out=$(curl -s --max-time 6 -u "${U}:${P}" -o /tmp/_snap.jpg -w '%{http_code} %{content_type} %{size_download}' \
              "http://${IP}:${port}${path}" 2>/dev/null)
        case "$out" in
            "200 image/"*) echo "  OK    :$port$path  [$out]"; [ -z "$SNAP" ] && SNAP="http://${IP}:${port}${path}";;
            *)             : ;;
        esac
    done
done
[ -z "$SNAP" ] && echo "  none answered"

echo
echo "== credential guesses (factory defaults) =="
if [ -n "$HIT" ]; then
    echo "  skipped — already authenticated"
elif ! open 554; then
    echo "  skipped — nothing listening on 554, no password will change that"
elif [ "$DEFAULTS" = 0 ]; then
    echo "  skipped — pass --defaults to try them"
else
    echo "  trying admin/{123456,admin,888888,blank}; expect a 30 min lockout after ~5 misses"
    for pw in 123456 admin 888888 ""; do
        for path in \
            "/user=admin&password=${pw}&channel=1&stream=1.sdp?real_stream" \
            "/user=admin&password=${pw}&channel=1&stream=0.sdp?real_stream" \
            "/cam/realmonitor?channel=1&subtype=1"
        do
            [ -z "$pw" ] && url="rtsp://admin:@${IP}:554${path}" || url="rtsp://admin:${pw}@${IP}:554${path}"
            info=$(ffprobe -v quiet -rtsp_transport tcp -timeout 4000000 \
                           -show_entries stream=codec_name,width,height -of csv=p=0 "$url" 2>/dev/null | head -1)
            if [ -n "$info" ]; then
                echo "  OK    admin / '${pw:-<blank>}'  ->  $path  [$info]"
                HIT="$url"
                break 2
            fi
        done
    done
    [ -z "$HIT" ] && echo "  none of them worked (or the DVR locked out — wait 30 min)"
fi

echo
if [ -n "$HIT" ]; then
    echo "VERDICT: RTSP works."
    echo "  use the stream=1 / subtype=1 / 102 'sub' variant for remote viewing"
    echo "  next : ./install-cams.sh cam1 '$HIT'"
elif [ "$SOFIA" = 1 ]; then
    echo "VERDICT: XiongMai/XMEye family with no RTSP — this is the RXCamView case."
    echo "  Nothing to install: the existing app + serial already views this from anywhere."
    echo "  Only if you later want it on your own screen: thin client + USB HDMI capture"
    echo "  of the DVR's monitor output, or Waydroid running the Android app on the mini PC."
elif [ -n "$SNAP" ]; then
    echo "VERDICT: no RTSP, but HTTP snapshots work."
    echo "  A 1-frame-per-few-seconds wall of stills is possible: $SNAP"
else
    echo "VERDICT: nothing found on 554/80 — cloud-P2P only."
    echo "  Vendor app is the answer. Check for an RTSP/ONVIF toggle in the DVR's"
    echo "  Network settings first; many firmwares hide it behind 'Enable ONVIF'."
fi
