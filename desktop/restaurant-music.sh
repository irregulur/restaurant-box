#!/usr/bin/env bash
# The "Music" button. Opens mympd in its own app window: play/pause, volume,
# playlist — nothing else on screen.
#
# Windowed on purpose: employees still need the desktop to press "Cameras",
# and a fullscreen app hides the taskbar. /etc/restaurant-music.conf can put it
# back:
#   MUSIC_FULLSCREEN=1
#   MYMPD_URL="http://127.0.0.1:8080"
set -uo pipefail

URL="${MYMPD_URL:-http://127.0.0.1:8080}"
FULLSCREEN="${MUSIC_FULLSCREEN:-0}"
[ -f /etc/restaurant-music.conf ] && . /etc/restaurant-music.conf
say() { kdialog --title "Music" --error "$1" 2>/dev/null ||
        zenity --error --title "Music" --text="$1" 2>/dev/null ||
        printf '%s\n' "$1" >&2; }

BROWSER=""
for b in chromium chromium-browser google-chrome-stable brave; do
    if command -v "$b" >/dev/null 2>&1; then BROWSER="$b"; break; fi
done
[ -n "$BROWSER" ] || { say "No web browser installed.

Ask the owner to run:  sudo pacman -S chromium"; exit 1; }

# If mympd is down, say so instead of showing a blank error page — but give it time:
# this also runs from autostart at login, when mympd may still be starting.
if command -v curl >/dev/null 2>&1; then
    tries="${MUSIC_WAIT:-20}"
    up=0
    for _ in $(seq 1 "$tries"); do
        if curl -fs -o /dev/null --max-time 3 "$URL"; then up=1; break; fi
        sleep 2
    done
    if [ "$up" != 1 ]; then
        say "The music player is not responding.

Try again in a minute — it restarts itself. If this keeps happening, tell the owner."
        exit 1
    fi
fi

flags=(--app="$URL" --no-first-run --no-default-browser-check --disable-features=Translate)
if [ "$FULLSCREEN" = 1 ]; then
    flags+=(--start-fullscreen)
else
    flags+=(--window-size=1100,760)
fi
exec "$BROWSER" "${flags[@]}"
