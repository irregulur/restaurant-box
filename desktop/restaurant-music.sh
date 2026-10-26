#!/usr/bin/env bash
# The "Music" button. Opens mympd in a full-screen app window: play/pause,
# volume, playlist — nothing else on screen.
set -uo pipefail

URL="${MYMPD_URL:-http://127.0.0.1:8080}"
say() { kdialog --title "Music" --error "$1" 2>/dev/null ||
        zenity --error --title "Music" --text="$1" 2>/dev/null ||
        printf '%s\n' "$1" >&2; }

BROWSER=""
for b in chromium chromium-browser google-chrome-stable brave; do
    if command -v "$b" >/dev/null 2>&1; then BROWSER="$b"; break; fi
done
[ -n "$BROWSER" ] || { say "No web browser installed.

Ask the owner to run:  sudo pacman -S chromium"; exit 1; }

# If mympd is down, say so instead of showing a blank error page.
if command -v curl >/dev/null 2>&1 && ! curl -fs -o /dev/null --max-time 3 "$URL"; then
    say "The music player is not responding.

Try again in a minute — it restarts itself. If this keeps happening, tell the owner."
    exit 1
fi

exec "$BROWSER" --app="$URL" --start-fullscreen \
    --no-first-run --no-default-browser-check --disable-features=Translate
