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
pacman -S --needed --noconfirm mpd mpc mympd ffmpeg jq curl nmap cockpit tailscale chromium mpv python-mutagen

echo "== directories =="
# group-writable so you can rsync music in as your own user; mpd only needs read
install -d -m 2775 -o root -g mpd /srv/music
install -d -o mpd -g mpd /var/lib/mpd/playlists
install -d /var/lib/restaurant-health
[ -n "${SUDO_USER:-}" ] && usermod -aG mpd "$SUDO_USER" && echo "added $SUDO_USER to group mpd (re-login for it to apply)"

echo "== mpd config =="
# Never clobber a working /etc/mpd.conf: the audio device is the one machine-specific
# line in it, and the installer has no idea which card this box actually has.
if [ -f /etc/mpd.conf ] && [ "${RESET_MPDCONF:-0}" != 1 ]; then
    echo "keeping existing /etc/mpd.conf (RESET_MPDCONF=1 to overwrite with the template)"
else
    [ -f /etc/mpd.conf ] && cp -a /etc/mpd.conf "/etc/mpd.conf.bak.$(date +%s)"
    install -m644 "$SRC/music/mpd.conf" /etc/mpd.conf
fi
# Sanity-check the configured sound card, because a wrong id is silent and confusing.
dev=$(sed -n 's/.*device[[:space:]]*"hw:\([^,"]*\).*/\1/p' /etc/mpd.conf | head -1)
if [ -n "$dev" ] && command -v aplay >/dev/null 2>&1 &&
   ! aplay -l 2>/dev/null | grep -qi "card [0-9]*: $dev "; then
    echo "!! /etc/mpd.conf wants sound card '$dev', but aplay -l does not list one: silent speakers."
    echo "   aplay -l   then:  sudo sed -i 's/device *\"hw:[^\"]*\"/device \"hw:ID,0\"/' /etc/mpd.conf"
fi

echo "== scripts =="
install -m755 "$SRC/music/restaurant-audio.sh" /usr/local/bin/restaurant-audio
install -m755 "$SRC/music/restaurant-hours.sh" /usr/local/bin/restaurant-hours
install -m755 "$SRC/ops/health.sh"            /usr/local/bin/restaurant-health
install -m755 "$SRC/ops/update.sh"            /usr/local/bin/restaurant-update
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
    # The music window opens by itself at login, so the screen shows what is playing
    # without anyone double-clicking. Employees can close it; the icon brings it back.
    install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$UHOME/.config/autostart"
    install -m755 -o "$DESKTOP_USER" -g "$DESKTOP_USER" \
        "$SRC/desktop/restaurant-music.desktop" "$UHOME/.config/autostart/restaurant-music.desktop"
    echo "added Music autostart for $DESKTOP_USER"
    # No KDE Wallet prompt. The kiosk browser is told --password-store=basic, but
    # plasma itself will still offer to open a wallet; on a box with no secrets that
    # is only a password dialog in the way of the music.
    install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$UHOME/.config"
    printf '[Wallet]\nEnabled=false\nFirst Use=false\n' > "$UHOME/.config/kwalletrc"
    chown "$DESKTOP_USER:$DESKTOP_USER" "$UHOME/.config/kwalletrc"
    echo "disabled KDE Wallet for $DESKTOP_USER"
else
    echo "skipped desktop icons: no login user detected (run the installer via sudo ./install.sh as that user)"
fi
install -d /usr/share/applications /usr/local/share/icons
install -m644 "$SRC/desktop/restaurant-music.desktop" /usr/share/applications/
install -m644 "$SRC/desktop/restaurant-cams.desktop"  /usr/share/applications/
# Ship the icons ourselves — the stock theme names were missing on this box, which
# left both launchers with a blank square.
install -m644 "$SRC/desktop/icons/restaurant-music.svg" /usr/local/share/icons/
install -m644 "$SRC/desktop/icons/restaurant-cams.svg"  /usr/local/share/icons/

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
install -Dm644 "$SRC/systemd/mympd-restaurant.conf"   /etc/systemd/system/mympd.service.d/restaurant.conf
systemctl daemon-reload

echo "== never sleep =="
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "== clock =="
# The music schedule (restaurant-hours) trusts the local clock: keep it synced from the
# internet, in the restaurant's time zone (TZONE=... to override).
timedatectl set-timezone "${TZONE:-America/New_York}" 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

echo "== hostname + firewall =="
# CachyOS ships ufw default-deny-incoming, which makes ssh/rdp look 'filtered' from the LAN.
BOXNAME="${BOXNAME:-restaurant-box}"
hostnamectl hostname "$BOXNAME" 2>/dev/null || true
if command -v ufw >/dev/null 2>&1; then
    LAN="$(ip -4 -o addr show scope global | awk '{print $4}' | head -1)"
    if [ -n "$LAN" ]; then
        for p in 22 3389 9090 8080; do ufw allow from "$LAN" to any port "$p" proto tcp >/dev/null 2>&1 || true; done
        # Also the private ranges, not just the subnet we happen to be installed on: the box
        # moves to another building, and if the tailnet is ever down, a phone on that
        # building's wifi is the only way back in.
        for net in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do
            for p in 22 9090 8080; do
                ufw allow from "$net" to any port "$p" proto tcp >/dev/null 2>&1 || true
            done
        done
    fi
    # Tailscale arrives on its own interface, so the LAN rule above does not cover
    # it. Without this, ssh over the tailnet is dropped by default-deny-incoming and
    # the box looks unreachable from home even though `tailscale status` is green.
    ufw allow in on tailscale0 >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ufw status | sed -n '1,10p'
fi

echo "== enable =="
systemctl enable --now mpd.service
systemctl enable mympd.service
systemctl restart mympd.service              # apply the plain-http drop-in
systemctl enable restaurant-audio.service
systemctl restart restaurant-audio.service   # pick up a changed script on re-run
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

3) Cameras (one line, once the DVR password is known):
     # from a laptop on the DVR's own network, find a working URL:
     ./cams/probe.sh <dvr-ip> admin '<password>'
     # if a rtsp:// path answers, point the button at it:
     echo 'CAM_RTSP="rtsp://..."' | sudo tee /etc/restaurant-cams.conf

   The Android-app route (waydroid) is documented but parked - it cannot resolve DNS
   inside the container. Read cams/waydroid.md before spending an evening on it.

4) Screen settings (Settings -> Power / Screen Locking):
     Screen Energy Saving: off   |   Screen Locking: disabled
     Otherwise the menu goes dark while the shop is open.

5) Remote access from home:
     sudo tailscale up --ssh
     # then: ssh $(hostname)   or   http://$(hostname):9090  (Cockpit)
     sudo systemctl enable --now sshd

   To actually SEE this box's desktop from home (Sunshine + Moonlight, incl. the
   headless vkms trick): ops/remote-screen.md

Watchdog alerts need a topic:
     echo 'NTFY_URL=https://ntfy.sh/CHANGE-ME' | sudo tee /etc/restaurant-health.env
     sudo chmod 600 /etc/restaurant-health.env

Status:
     systemctl status mpd restaurant-audio mympd health.timer
     mpc status            # what is on the speakers right now
     journalctl -u restaurant-audio -f
EOF
