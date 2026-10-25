#!/usr/bin/env bash
# restaurant-audio: keep background music playing, forever.
# Runs as a systemd service (Restart=always). Every tick:
#   1. mpd running?             start it
#   2. queue empty?             rebuild a shuffled playlist from /srv/music and load it
#   3. not playing?             play
# Staff may hit stop; it resumes on the next tick. That is intentional.
set -uo pipefail

MUSIC="${MUSIC_DIR:-/srv/music}"
PL="${PLAYLIST:-restaurant}"
export MPD_HOST=127.0.0.1 MPD_PORT=6600
INTERVAL="${INTERVAL:-20}"

log() { echo "restaurant-audio: $*"; }

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
    if ! mpc ping >/dev/null 2>&1; then
        log "mpd not responding, starting it"
        systemctl start mpd.service
        sleep 3
        continue
    fi

    # queue empty -> (re)load
    if [ "$(mpc playlist 2>/dev/null | wc -l)" -eq 0 ]; then
        mpc clear >/dev/null 2>&1
        if ! mpc load "$PL" >/dev/null 2>&1 || [ "$(mpc playlist | wc -l)" -eq 0 ]; then
            rebuild_playlist || { sleep "$INTERVAL"; continue; }
            mpc clear >/dev/null 2>&1
            mpc load "$PL" >/dev/null 2>&1
        fi
        mpc repeat 1 >/dev/null 2>&1
        mpc random 0 >/dev/null 2>&1   # already shuffled at build time
        mpc play >/dev/null 2>&1
        log "started: $(mpc current 2>/dev/null)"
        sleep "$INTERVAL"
        continue
    fi

    if ! mpc status 2>/dev/null | grep -q '\[playing\]'; then
        mpc play >/dev/null 2>&1
        log "resumed playback"
    fi
    sleep "$INTERVAL"
done
