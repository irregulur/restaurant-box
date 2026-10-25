#!/usr/bin/env bash
# health.sh — watchdog for the unattended box. Run by health.timer every 5 min.
# Checks only what is installed on this node. Alerts via ntfy, with a cooldown so a
# dead service does not spam you every 5 minutes; a recovery message closes the loop.
#
# Configure: /etc/restaurant-health.env
#   NTFY_URL=https://ntfy.sh/your-secret-topic
#   DISK_MAX=90
set -uo pipefail

[ -f /etc/restaurant-health.env ] && . /etc/restaurant-health.env
NTFY_URL="${NTFY_URL:-}"
DISK_MAX="${DISK_MAX:-90}"
STATE="${STATE:-/var/lib/restaurant-health/state}"
COOLDOWN="${COOLDOWN:-21600}"   # 6h between repeats of the same problem
mkdir -p "$(dirname "$STATE")"

problems=()
export MPD_HOST=127.0.0.1

if systemctl list-unit-files mpd.service >/dev/null 2>&1; then
    if ! systemctl is-active --quiet mpd.service; then
        problems+=("mpd is not running")
    elif ! mpc status 2>/dev/null | grep -q '\[playing\]'; then
        problems+=("mpd is up but not playing")
    fi
fi

if [ -x /usr/local/bin/go2rtc ]; then
    systemctl is-active --quiet go2rtc.service || problems+=("go2rtc is not running")
    curl -fsS --max-time 5 http://127.0.0.1:1984/api/streams >/dev/null 2>&1 \
        || problems+=("go2rtc API not answering on :1984")
fi

if command -v tailscale >/dev/null; then
    tailscale status >/dev/null 2>&1 || problems+=("tailscale is not up")
fi

if command -v cockpit.socket >/dev/null 2>&1 || systemctl list-unit-files cockpit.socket >/dev/null 2>&1; then
    systemctl is-active --quiet cockpit.socket || problems+=("cockpit.socket is not active")
fi

use=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ -n "$use" ] && [ "$use" -ge "$DISK_MAX" ] && problems+=("disk ${use}% full (>${DISK_MAX}%)")

notify() {
    [ -n "$NTFY_URL" ] || { echo "$1"; return; }
    curl -fsS --max-time 10 -H "Title: ${HOSTNAME}" -H "Priority: high" \
         -d "$1" "$NTFY_URL" >/dev/null 2>&1 || true
    echo "notified: $1"
}

now=$(date +%s)
last=$(cat "$STATE" 2>/dev/null || echo 0)

if [ ${#problems[@]} -eq 0 ]; then
    if [ -f "$STATE.err" ]; then
        notify "recovered: ${HOSTNAME} healthy again"
        rm -f "$STATE.err"
    fi
    echo ok
    exit 0
fi

msg="PROBLEM on ${HOSTNAME}: $(printf '%s; ' "${problems[@]}")"
printf '%s\n' "$msg" > "$STATE.err"
if [ $((now - last)) -ge "$COOLDOWN" ] || [ ! -f "$STATE.err.orig" ] || [ "$(cat "$STATE.err.orig")" != "$msg" ]; then
    echo "$now" > "$STATE"
    printf '%s\n' "$msg" > "$STATE.err.orig"
    notify "$msg"
fi
exit 1
