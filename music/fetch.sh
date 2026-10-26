#!/usr/bin/env bash
# fetch.sh — turn the want-list into files on disk, as fast as politely possible.
#
#   ./fetch.sh songs.csv /srv/music             # download what's missing
#   ./fetch.sh songs.csv /srv/music --dry-run   # just show what each search resolves to
#
# Nothing here is clever: wanted.py says what is missing, each missing row becomes a
# `ytsearch1:<artist> <title>` pseudo-URL, and yt-dlp resolves and downloads them.
# Audio is extracted in its native format (m4a/aac or opus) — no re-encode, so it is
# fast and loses nothing; mpd's ffmpeg plugin plays both.
set -uo pipefail

CSV="${1:-}"
MUSIC="${2:-}"
DRY="${3:-}"
if [ -z "$CSV" ] || [ -z "$MUSIC" ]; then
    echo "usage: $0 songs.csv /srv/music [--dry-run]" >&2
    exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$MUSIC/.ytdl-archive"
MISSING="$(mktemp)"
SEARCHES="$(mktemp)"
trap 'rm -f "$MISSING" "$SEARCHES"' EXIT

command -v yt-dlp  >/dev/null || { echo "need yt-dlp:   sudo pacman -S --needed yt-dlp" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "need ffmpeg:   sudo pacman -S --needed ffmpeg" >&2; exit 1; }
[ -d "$MUSIC" ] || { echo "no such music directory: $MUSIC" >&2; exit 1; }

# 1. what is still missing (normalized + fuzzy match against what is already on disk)
python3 "$HERE/wanted.py" "$CSV" "$MUSIC" -o "$MISSING" || exit 1

# 2. one search line per missing track
python3 - "$MISSING" "$SEARCHES" <<'PY'
import csv, sys
src, out = sys.argv[1], sys.argv[2]
with open(src, newline="") as f:
    rows = list(csv.reader(f))
if not rows:
    sys.exit(0)
head = [c.strip().lower() for c in rows[0]]
try:
    ai, ti = head.index("artist"), head.index("title")
    body = rows[1:]
except ValueError:                     # no header, assume artist,title first
    ai, ti, body = 0, 1, rows
with open(out, "w") as f:
    for r in body:
        if len(r) <= max(ai, ti):
            continue
        a, t = r[ai].strip(), r[ti].strip()
        if a and t:
            f.write(f"ytsearch1:{a} {t}\n")
PY

N=$(grep -c . "$SEARCHES" || true)
echo "== $N tracks missing from $MUSIC"
[ "$N" -eq 0 ] && { echo "== nothing to do"; exit 0; }

YT=(yt-dlp -a "$SEARCHES"
    --no-playlist --playlist-end 1
    --extract-audio --audio-format best
    --embed-metadata --add-metadata
    --match-filter "duration > 90 & duration < 600"
    --download-archive "$ARCHIVE"
    --retries 3 --sleep-requests 0.5
    --no-progress -i
    -o "$MUSIC/%(artist,creator,uploader)s - %(title)s.%(ext)s")

if [ "$DRY" = "--dry-run" ]; then
    echo "== dry run: search -> what yt-dlp would grab"
    "${YT[@]}" --simulate --print "%(duration_string)s  %(uploader)s — %(title)s"
    echo "== re-run without --dry-run to download"
    exit 0
fi

# Leftovers from an interrupted run (.part / .temp.m4a) look like real tracks to mpd
# and to anything that walks the library, but no decoder can open them.
stale=$(find "$MUSIC" -maxdepth 1 -type f \( -name '*.temp.*' -o -name '*.part' -o -name '*.ytdl' \) -print -delete)
[ -n "$stale" ] && echo "== removed leftover partial downloads: $(printf '%s\n' "$stale" | wc -l)"

echo "== downloading; failures are skipped and listed at the end"
"${YT[@]}"
rc=$?

# yt-dlp names WebM-wrapped Opus files ".opus"; remux them to real Ogg/Opus or the
# ReplayGain scan (rsgain/loudgain) aborts on the first one it cannot tag.
[ -x "$HERE/fix-containers.sh" ] && "$HERE/fix-containers.sh" "$MUSIC"

echo
echo "== now on disk:"
python3 "$HERE/wanted.py" "$CSV" "$MUSIC" -o "$MISSING" 2>/dev/null | tail -2
echo "== anything still listed is either not on YouTube or too long/short to trust — buy those"
exit $rc
