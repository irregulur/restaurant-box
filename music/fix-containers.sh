#!/usr/bin/env bash
# yt-dlp leaves Opus audio inside a WebM container but saves it as ".opus", which is a
# lie that matters: ReplayGain taggers (rsgain, loudgain) look at the extension, try to
# write Ogg/Opus tags, fail, and report "No files were scanned". mpd itself plays them
# fine, so nothing else complains.
#
# Remux, don't re-encode: -c copy keeps the exact same audio bits, only the wrapper
# changes. Result is a real Ogg/Opus file with a .ogg extension.
#
#   ./music/fix-containers.sh /srv/music
set -euo pipefail

DIR="${1:-/srv/music}"
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is missing: sudo pacman -S ffmpeg" >&2; exit 1; }

fixed=0 skipped=0
while IFS= read -r -d '' f; do
    # Ask ffprobe about the container instead of trusting `file` (or the extension).
    # yt-dlp's "opus" files are really matroska,webm; a genuine one is ogg.
    fmt=$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 -- "$f" 2>/dev/null || true)
    case "$fmt" in
        *webm*|*matroska*) ;;
        *) continue ;;
    esac
    tmp="$(mktemp "${TMPDIR:-/tmp}/fix-containers.XXXXXX.ogg")"
    if ffmpeg -v error -y -i "$f" -c copy "$tmp" 2>/dev/null; then
        mv -f -- "$tmp" "${f%.opus}.ogg"
        rm -f -- "$f"   # the mislabelled original must go: rsgain aborts the scan on it
        fixed=$((fixed + 1))
    else
        rm -f -- "$tmp"
        skipped=$((skipped + 1))
        echo "skipped (ffmpeg could not copy, format=$fmt): $f" >&2
    fi
done < <(find "$DIR" -type f -name '*.opus' -print0)

echo "remuxed $fixed file(s) to .ogg, skipped $skipped"
[ "$fixed" -gt 0 ] && echo "next: rsgain easy -m 4 $DIR  &&  sudo systemctl restart mpd"
exit 0
