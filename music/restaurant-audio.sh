#!/usr/bin/env bash
# restaurant-audio: keep background music playing, forever.
# Runs as a systemd service (Restart=always). Every tick:
#   1. mpd running?             start it
#   2. queue empty?             rebuild a shuffled playlist from /srv/music and load it
#   3. not playing?             play
# Staff may hit stop; it resumes on the next tick. That is intentional.
# Outside opening hours (restaurant-hours) it stops the music once at closing time and
# then leaves mpd alone, so staff can still put something on while they clean up.
set -uo pipefail

MUSIC="${MUSIC_DIR:-/srv/music}"
PL="${PLAYLIST:-restaurant}"
export MPD_HOST=127.0.0.1 MPD_PORT=6600
INTERVAL="${INTERVAL:-20}"
HEARTBEAT="${HEARTBEAT:-/run/restaurant-audio.heartbeat}"
MPC="${MPC:-/usr/bin/mpc}"

log() { echo "restaurant-audio: $*"; }
# Every mpd call is time-boxed. Without this, one half-open socket to mpd wedges the loop
# forever: no stop at closing, no start at opening, and systemd still calls the unit fine.
mpc() { timeout 10 "$MPC" "$@"; }
open_now() { "${HOURS:-/usr/local/bin/restaurant-hours}"; }
# The watchdog (restaurant-health) alarms when this goes stale, so a stuck loop is visible.
beat() { printf '%s\n' "$(date +%s)" > "$HEARTBEAT" 2>/dev/null || true; }
was_open=1   # so a boot after hours also stops anything mpd resumed on its own
mpd_fails=0  # consecutive 'mpd not answering' ticks: restart it instead of poking a hung unit

rebuild_playlist() {
    local out="/var/lib/mpd/playlists/$PL.m3u" n
    n=$(find "$MUSIC" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
            -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aac' \) -printf '%P\n' 2>/dev/null | wc -l)
    if [ "$n" -eq 0 ]; then
        log "no audio files in $MUSIC — nothing to play"
        return 1
    fi
    find "$MUSIC" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
        -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aac' \) -printf '%P\n' \
        | shuf > "$out"
    log "playlist rebuilt: $n tracks"
}

while :; do
    beat
    # mpc has no `ping`; `status` exits non-zero only when mpd can't be reached
    if ! st=$(mpc status 2>/dev/null); then
        mpd_fails=$((mpd_fails + 1))
        if [ "$mpd_fails" -ge 2 ]; then
            log "mpd not responding twice, restarting it"
            timeout 60 systemctl restart mpd.service
            mpd_fails=0
        else
            log "mpd not responding, starting it"
            timeout 60 systemctl start mpd.service
        fi
        sleep 3
        continue
    fi
    mpd_fails=0

    if ! open_now; then
        if [ "$was_open" = 1 ]; then
            mpc stop >/dev/null 2>&1
            log "closed: music stopped until opening time"
            was_open=0
        fi
        sleep "$INTERVAL"
        continue
    fi
    [ "$was_open" = 0 ] && log "open: starting music"
    was_open=1

    # queue empty -> (re)load
    if [ "$(mpc playlist 2>/dev/null | wc -l)" -eq 0 ]; then
        mpc clear >/dev/null 2>&1
        if ! mpc load "$PL" >/dev/null 2>&1 || [ "$(mpc playlist | wc -l)" -eq 0 ]; then
            rebuild_playlist || { sleep "$INTERVAL"; continue; }
            mpc clear >/dev/null 2>&1
            mpc load "$PL" >/dev/null 2>&1
        fi
        mpc repeat 1 >/dev/null 2>&1
        mpc random 1 >/dev/null 2>&1   # shuffle: never the same order twice
        mpc play >/dev/null 2>&1
        log "started: $(mpc current 2>/dev/null)"
        sleep "$INTERVAL"
        continue
    fi

    if ! printf '%s\n' "$st" | grep -q '\[playing\]'; then
        mpc play >/dev/null 2>&1
        log "resumed playback"
    fi
    sleep "$INTERVAL"
done
