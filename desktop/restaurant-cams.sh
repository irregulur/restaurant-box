#!/usr/bin/env bash
# The "Cameras" button.
#
# Preferred path: a plain RTSP URL from the DVR, played by mpv full screen — host-native,
# one process, iGPU decode, nothing to maintain. Set it in /etc/restaurant-cams.conf.
#
# Fallback: the RXCamView Android app inside Waydroid. That path is PARKED — it installs
# and runs, but Android never got a DHCP lease in the container and Android 13 offers no
# way to inject DNS by hand, so the cloud login cannot resolve. See cams/waydroid.md for
# the full post-mortem. The code is kept in case DNS is solved later.
set -uo pipefail

CAM_RTSP="${CAM_RTSP:-}"
CAM_PKG="${CAM_PKG:-}"
# /etc/restaurant-cams.conf, e.g.
#   CAM_RTSP="rtsp://admin:pass@192.168.1.50:554/user=admin&password=pass&channel=1&stream=1.sdp?real_stream"
#   CAM_PKG="com.client.rxcamview"
[ -f /etc/restaurant-cams.conf ] && . /etc/restaurant-cams.conf

say() { kdialog --title "Cameras" --error "$1" 2>/dev/null ||
        zenity --error --title "Cameras" --text="$1" 2>/dev/null ||
        printf '%s\n' "$1" >&2; }

# ---- 1. RTSP: the good path -------------------------------------------------
if [ -n "${CAM_RTSP:-}" ]; then
    if ! command -v mpv >/dev/null 2>&1; then
        say "The video player is missing.

Ask the owner to run:  sudo pacman -S mpv"
        exit 1
    fi
    # --cache=no keeps it live rather than sliding behind; tcp survives a flaky link
    mpv --fs --no-border --force-window=yes --title=Cameras \
        --rtsp-transport=tcp --cache=no --network-timeout=10 \
        "$CAM_RTSP" && exit 0
    say "The cameras did not answer.

The DVR may be rebooting, or the network may be down.
Try again in a minute."
    exit 1
fi

# ---- 2. Waydroid: parked fallback -------------------------------------------
command -v waydroid >/dev/null 2>&1 || {
    say "Cameras are not set up on this machine yet.

Ask the owner to run cams/probe.sh against the DVR — it needs the DVR password."
    exit 1
}

running() { waydroid status 2>/dev/null | grep -qi 'Session:.*RUNNING'; }

if ! running; then
    waydroid session start >/dev/null 2>&1 &
    for _ in $(seq 1 30); do running && break; sleep 1; done
fi
running || { say "The camera app did not start.

Try again once — the first start after boot can take 30 seconds."; exit 1; }

# Find the DVR app if we were not told its package name.
# `waydroid app list` prints blocks:  Name: X\n packageName: y\n categories:
if [ -z "$PKG" ]; then
    PKG=$(waydroid app list 2>/dev/null |
          awk '/^Name:/{n=$0} /^packageName:/{print $2, n}' |
          grep -iE 'rxcam|xmeye|gcmob|vmeye|kemye|meanew' |
          head -1 | cut -d' ' -f1)
fi

if [ -n "$PKG" ]; then
    waydroid app launch "$PKG" >/dev/null 2>&1 && exit 0
fi
exec waydroid show-full-ui
