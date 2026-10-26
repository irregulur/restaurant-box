#!/usr/bin/env bash
# install.sh — site A (the mini PC with the speakers). Idempotent; safe to re-run.
#
#   from a checkout:   sudo ./install.sh
#   one-liner:         curl -fsSL https://raw.githubusercontent.com/irregulur/restaurant-box/main/install.sh | sudo bash
set -euo pipefail

# Self-bootstrapping: when piped from curl there are no sibling files, so pull the tarball.
SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /tmp)}"
REPO="${REPO:-irregulur/restaurant-box}"
if [ ! -f "$SRC/music/mpd.conf" ]; then
    echo "== bootstrap: fetching $REPO =="
    d=$(mktemp -d)
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" | tar xz -C "$d" --strip-components=1
    exec bash "$d/install.sh" "$@"
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "== packages =="
pacman -S --needed --noconfirm mpd mpc mympd ffmpeg jq curl nmap cockpit tailscale chromium

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
install -m755 "$SRC/desktop/restaurant-music.sh" /usr/local/bin/restaurant-music
install -m755 "$SRC/desktop/restaurant-cams.sh"  /usr/local/bin/restaurant-cams

echo "== employee screen =="
# Two big buttons on the desktop (plus an entry in the app menu) and autologin, so a
# power cut brings the screen back by itself. Employees never see a login prompt.
DESKTOP_USER="${SUDO_USER:-}"
if [ -n "$DESKTOP_USER" ] && [ "$DESKTOP_USER" != root ]; then
    UHOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
    install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$UHOME/Desktop"
    for f in restaurant-music.desktop restaurant-cams.desktop; do
        install -m755 -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$SRC/desktop/$f" "$UHOME/Desktop/$f"
    done
    echo "added Music + Cameras icons to $UHOME/Desktop"
else
    echo "skipped desktop icons: no login user detected (run the installer via sudo ./install.sh as that user)"
fi
install -d /usr/share/applications
install -m644 "$SRC/desktop/restaurant-music.desktop" /usr/share/applications/
install -m644 "$SRC/desktop/restaurant-cams.desktop"  /usr/share/applications/

if [ -n "$DESKTOP_USER" ] && [ "$DESKTOP_USER" != root ] && command -v plasmalogin >/dev/null 2>&1; then
    install -d /etc/plasmalogin.conf.d
    cat > /etc/plasmalogin.conf.d/10-autologin.conf <<EOA
[Autologin]
User=$DESKTOP_USER
Session=plasma
EOA
    echo "autologin on for $DESKTOP_USER (Session=plasma) — verify with: cat /etc/plasmalogin.conf.d/10-autologin.conf"
fi

echo "== systemd units =="
install -m644 "$SRC/systemd/restaurant-audio.service" /etc/systemd/system/
install -m644 "$SRC/ops/health.service"               /etc/systemd/system/
install -m644 "$SRC/ops/health.timer"                 /etc/systemd/system/
systemctl daemon-reload

echo "== never sleep =="
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "== hostname + firewall =="
# CachyOS ships ufw default-deny-incoming, which makes ssh/rdp look 'filtered' from the LAN.
BOXNAME="${BOXNAME:-restaurant-box}"
hostnamectl hostname "$BOXNAME" 2>/dev/null || true
if command -v ufw >/dev/null 2>&1; then
    LAN="$(ip -4 -o addr show scope global | awk '{print $4}' | head -1)"
    if [ -n "$LAN" ]; then
        for p in 22 3389 9090 8080; do ufw allow from "$LAN" to any port "$p" proto tcp >/dev/null 2>&1 || true; done
    fi
    ufw --force enable >/dev/null 2>&1 || true
    ufw status | sed -n '1,10p'
fi

echo "== enable =="
systemctl enable --now mpd.service
systemctl enable --now mympd.service
systemctl enable --now restaurant-audio.service
systemctl enable --now cockpit.socket
systemctl enable --now health.timer

cat <<EOF

Done. Three things are still manual:

0) This machine's name is now $(hostname) — reach it at $(hostname).local (or its IP).

1) Pick the audio output (the only line that usually needs editing):
     aplay -l                      # find "card N: NAME [ ... ]"
     sudoedit /etc/mpd.conf        # audio_output -> device "hw:NAME,0"  (or hw:N,0)
     sudo systemctl restart mpd

2) Copy music in (FLAC/MP3/M4A/OGG):
     rsync -av ~/Music/restaurant/ $(hostname):/srv/music/

3) Cameras (Android app in a container — no phone needed on the counter):
     sudo pacman -S --needed waydroid waydroid-image
     sudo waydroid init                     # downloads the Android image once
     waydroid session start && waydroid show-full-ui
     # install RXCamView inside Android, log in once, then:
     waydroid app list                      # find its package name
     echo 'CAM_PKG=<package>' | sudo tee /etc/restaurant-cams.conf
     # the Cameras button now opens it directly

4) Screen settings (Settings -> Power / Screen Locking):
     Screen Energy Saving: off   |   Screen Locking: disabled
     Otherwise the menu goes dark while the shop is open.

5) Remote access from home:
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
