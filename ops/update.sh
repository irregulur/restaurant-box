#!/usr/bin/env bash
# restaurant-update: pull the latest version from GitHub and re-run the installer.
# Made to be typed from a phone over ssh:   sudo restaurant-update
# The installer is idempotent; your /etc/mpd.conf (sound card) and music are kept.
set -euo pipefail
REPO="${REPO:-irregulur/restaurant-box}"
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
cd /   # the installer uses local files if run from a checkout; we want GitHub's
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" | bash
echo
echo "updated. music: $(MPD_HOST=127.0.0.1 mpc status 2>/dev/null | head -2 | tr '\n' ' ')"
