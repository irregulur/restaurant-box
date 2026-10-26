#!/usr/bin/env bash
# Write ReplayGain 2.0 tags across the library so mpd can even out the loud/quiet
# difference between a modern master and a 1950s 78 rpm transfer.
#
# Why not `rsgain easy`? On this box easy mode reports "Found 1 directory... No files
# were scanned" for a flat library, while custom mode reads the very same files fine.
# So we name the files explicitly and stop guessing.
#
#   ./music/tag-gain.sh /srv/music          # tag everything (writes tags, never audio)
#   ./music/tag-gain.sh /srv/music --dry    # just measure, write nothing
#
# mpd must be restarted afterwards to re-read its database/tags:
#   sudo systemctl restart mpd
set -euo pipefail

DIR="${1:-/srv/music}"
MODE="i"                       # -s i = write ReplayGain 2.0 tags
[ "${2:-}" = "--dry" ] && MODE="s"

[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 1; }
command -v rsgain >/dev/null || {
    echo "rsgain is not installed. Static binary, no AUR needed:" >&2
    echo "  https://github.com/complexlogic/rsgain/releases -> rsgain-3.8-Linux.tar.xz" >&2
    exit 1
}

mapfile -d '' files < <(find "$DIR" -type f \
    \( -name '*.opus' -o -name '*.ogg' -o -name '*.m4a' -o -name '*.mp3' \
       -o -name '*.flac' -o -name '*.webm' -o -name '*.wav' \) -print0)

count=${#files[@]}
[ "$count" -gt 0 ] || { echo "no audio files under $DIR" >&2; exit 1; }
echo "== $count file(s) under $DIR"

# -c p: clipping protection for positive gains, so quiet transfers are not pushed into
# distortion. This costs a licence plate of CPU per file; a few minutes for a library.
if [ "$MODE" = "s" ]; then
    rsgain custom -s s -c p "${files[@]}"
else
    rsgain custom -s i -c p "${files[@]}"
    echo
    echo "== done. reload the tags:  sudo systemctl restart mpd"
fi
