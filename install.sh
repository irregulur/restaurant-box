#!/usr/bin/env bash
# install.sh — site A (the mini PC with the speakers). Idempotent; safe to re-run.
#   sudo ./install.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "== packages =="
pacman -S --needed --noconfirm mpd mpc mympd ffmpeg jq curl nmap cockpit tailscale

echo "== directories =="
# group-writable so you can rsync music in as your own user; mpd only needs read
install -d -m 2775 -o root -g mpd /srv/music
install -d -o mpd -g mpd /var/lib/mpd/playlists
install -d /var/lib/restaurant-health
[ -n "${SUDO_USER:-}" ] && usermod -aG mpd "$SUDO_USER" && echo "added $SUDO_USER to group mpd (re-login for it to apply)"

echo "== mpd config =="
if [ -f /etc/mpd.conf ] && ! grep -q 'restaurant-box' /etc/mpd.conf; then
    cp -a /etc/mpd.conf "/etc/mpd.conf.bak.$(date +%s)"
    echo "kept existing /etc/mpd.conf as a backup"
fi
install -m644 "$SRC/music/mpd.conf" /etc/mpd.conf

echo "== scripts =="
install -m755 "$SRC/music/restaurant-audio.sh" /usr/local/bin/restaurant-audio
install -m755 "$SRC/ops/health.sh"            /usr/local/bin/restaurant-health
install -m755 "$SRC/music/wanted.py"          /usr/local/bin/restaurant-wanted

echo "== systemd units =="
install -m644 "$SRC/systemd/restaurant-audio.service" /etc/systemd/system/
install -m644 "$SRC/ops/health.service"               /etc/systemd/system/
install -m644 "$SRC/ops/health.timer"                 /etc/systemd/system/
systemctl daemon-reload

echo "== never sleep =="
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "== enable =="
systemctl enable --now mpd.service
systemctl enable --now mympd.service
systemctl enable --now restaurant-audio.service
systemctl enable --now cockpit.socket
systemctl enable --now health.timer

cat <<EOF

Done. Three things are still manual:

1) Pick the audio output (the only line that usually needs editing):
     aplay -l                      # find "card N: NAME [ ... ]"
     sudoedit /etc/mpd.conf        # audio_output -> device "hw:NAME,0"  (or hw:N,0)
     sudo systemctl restart mpd

2) Copy music in (FLAC/MP3/M4A/OGG):
     rsync -av ~/Music/restaurant/ $(hostname):/srv/music/

3) Remote access from home:
     sudo tailscale up --ssh
     # then: ssh $(hostname)   or   http://$(hostname):9090  (Cockpit)
     sudo systemctl enable --now sshd

Watchdog alerts need a topic:
     echo 'NTFY_URL=https://ntfy.sh/CHANGE-ME' | sudo tee /etc/restaurant-health.env
     sudo chmod 600 /etc/restaurant-health.env

Status:
     systemctl status mpd restaurant-audio mympd health.timer
     mpc status            # what is on the speakers right now
     journalctl -u restaurant-audio -f
EOF
