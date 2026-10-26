#!/usr/bin/env bash
# The "Cameras" button. Starts the Waydroid Android layer if needed, then opens
# the DVR app (RXCamView / XMEye family) full screen so one tap shows the other
# restaurant's cameras — no phone, no laptop.
set -uo pipefail

PKG="${CAM_PKG:-}"
# Optional:  echo 'CAM_PKG=com.xmeye.rxcamview' | sudo tee /etc/restaurant-cams.conf
[ -f /etc/restaurant-cams.conf ] && . /etc/restaurant-cams.conf
PKG="${CAM_PKG:-$PKG}"

say() { kdialog --title "Cameras" --error "$1" 2>/dev/null ||
        zenity --error --title "Cameras" --text="$1" 2>/dev/null ||
        printf '%s\n' "$1" >&2; }

command -v waydroid >/dev/null 2>&1 || { say "Cameras are not set up on this machine yet.

Ask the owner to run:  sudo pacman -S waydroid waydroid-image"; exit 1; }

running() { waydroid status 2>/dev/null | grep -qi 'Session:.*RUNNING'; }

if ! running; then
    waydroid session start >/dev/null 2>&1 &
    for _ in $(seq 1 30); do running && break; sleep 1; done
fi
running || { say "The camera app did not start.

Try again once — the first start after boot can take 30 seconds."; exit 1; }

# Find the DVR app if we were not told its package name.
if [ -z "$PKG" ]; then
    PKG=$(waydroid app list 2>/dev/null |
          grep -iE 'rxcam|xmeye|gcmob|vmeye|kemye|meanew' |
          head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
fi

if [ -n "$PKG" ]; then
    waydroid app launch "$PKG" >/dev/null 2>&1 && exit 0
fi
exec waydroid show-full-ui
