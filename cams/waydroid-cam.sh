#!/usr/bin/env bash
# waydroid-cam.sh — bring an Android app (the camera viewer) up on the mini PC.
#
# PARKED — see cams/waydroid.md. The app launches but cannot reach the network
# (no DHCP client in this Android image, and no CLI left to set DNS). Kept for the
# day a newer waydroid-image fixes that. The cameras now go through mpv + RTSP.
#
#   ./waydroid-cam.sh                 # list candidate packages
#   ./waydroid-cam.sh com.rxcamview   # start container/session if needed, launch app
#
# Must run inside the graphical session (Wayland); not a systemd service.
set -uo pipefail

PKG="${1:-}"

command -v waydroid >/dev/null || { echo "waydroid not installed: sudo pacman -S waydroid waydroid-image"; exit 1; }
grep -qi binder /proc/filesystems || echo "WARN: no binderfs in this kernel — Waydroid will fail (see waydroid.md)"

[[ -n "${WAYLAND_DISPLAY:-}" || -n "${XDG_SESSION_TYPE:-}" ]] || echo "WARN: no Wayland session detected"

# container (root service) then session (user)
if ! systemctl is-active --quiet waydroid-container; then
    echo "starting waydroid-container..."
    sudo systemctl start waydroid-container || exit 1
fi

if ! waydroid status 2>/dev/null | grep -q 'RUNNING'; then
    echo "starting waydroid session..."
    waydroid session start >/tmp/waydroid-session.log 2>&1 &
    for _ in $(seq 1 40); do
        waydroid status 2>/dev/null | grep -q 'RUNNING' && break
        sleep 1
    done
fi

waydroid status

if [ -z "$PKG" ]; then
    echo
    echo "Installed apps (pick the camera viewer):"
    waydroid app list 2>/dev/null | grep -iE 'cam|rx|eye|vme|surveil' || waydroid app list
    echo
    echo "Then: $0 <package.name>"
    exit 0
fi

waydroid app launch "$PKG" || { echo "launch failed; is the package name right?"; exit 1; }
echo "launched $PKG"

# A maximised/fullscreen window is WM-dependent; try the common helpers, quietly.
sleep 2
if command -v wmctrl >/dev/null; then
    wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz 2>/dev/null || true
elif command -v kdotool >/dev/null; then
    kdotool search --class waydroid windowactivate 2>/dev/null || true
fi
echo "if it is not fullscreen: Alt+F11 / Super+F, or set persist.waydroid.multi_windows true"
