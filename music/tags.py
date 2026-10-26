#!/usr/bin/env python3
"""tags.py — give the library real artist/title/album/cover art.

The downloads are honest about audio and careless about metadata: a user upload
lands as artist="mangeldeth74", title="Louis Jordan - Is You Is Or Is You Ain't".
This fixes the names from songs.csv (the want-list is the ground truth) and then
asks the iTunes catalogue for the album and its cover, embedding the picture into
the file so mympd/mpd can show it.

    ./music/tags.py ~/songs.csv /srv/music --dry     # show what would change
    ./music/tags.py ~/songs.csv /srv/music           # do it
    sudo systemctl restart mpd

Needs python-mutagen (in extra). No file is moved or renamed, so the mpd queue and
restaurant-audio.sh keep working; only tags change.
"""
import argparse
import base64
import csv
import difflib
import json
import os
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wanted import (AUDIO, best_want, clean, norm,  # noqa: E402
                    tags as probe_tags)

from mutagen.flac import Picture  # noqa: E402
from mutagen.id3 import APIC, ID3  # noqa: E402
from mutagen.mp3 import MP3  # noqa: E402
from mutagen.mp4 import MP4, MP4Cover  # noqa: E402
from mutagen.oggopus import OggOpus  # noqa: E402
from mutagen.oggvorbis import OggVorbis  # noqa: E402

UA = {"User-Agent": "restaurant-box/1.0 (+https://github.com/irregulur/restaurant-box)"}
ART_MIN = 4000           # bytes; anything smaller is a placeholder, not a cover
RATE_HITS = []           # lookups the catalogue refused; reported at the end


def _get(url: str, timeout: int = 30) -> bytes:
    """GET with backoff. iTunes throttles at roughly 20 requests/minute and answers
    HTTP 429 once you cross it, which would otherwise silently cost a file its album."""
    import time as _t
    import urllib.error
    for attempt, wait in enumerate((0, 20, 45, 90)):
        if wait:
            _t.sleep(wait)
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 3:
                raise
    raise RuntimeError("unreachable")


def itunes(artist: str, title: str):
    """Best catalogue entry for this track, or None.

    Scored, not "first hit": the search happily returns a 40-track compilation
    with a karaoke version of the same name. Exact normalized matches win, then
    the earliest release wins, because for this library the original pressing is
    the useful answer and the 2011 re-issue is not.
    """
    q = urllib.parse.urlencode({"term": f"{artist} {title}", "entity": "song",
                                "limit": 10, "country": "US"})
    results = json.loads(_get(f"https://itunes.apple.com/search?{q}", 20)).get("results", [])

    want_a, want_t = norm(artist), norm(title)
    best = None
    for r in results:
        ra, rt = norm(r.get("artistName", "")), norm(r.get("trackName", ""))
        if not rt:
            continue
        if rt == want_t:
            score = 2.0
        else:
            score = difflib.SequenceMatcher(None, rt, want_t).ratio() * 1.5
        if ra == want_a:
            score += 1.0
        elif want_a and (want_a in ra or ra in want_a):
            score += 0.6
        else:
            score += difflib.SequenceMatcher(None, ra, want_a).ratio() * 0.4
        # a karaoke/tribute/cover-band upload is never the answer
        if any(w in ra for w in ("karaoke", "tribute", "cover", "made famous",
                                 "originally performed", "in the style of")):
            score -= 2.0
        if score < 1.6:
            continue
        key = (score, r.get("releaseDate", "9999"))
        # prefer higher score; on a tie prefer the older release
        if best is None or key[0] > best[0][0] or (
                abs(key[0] - best[0][0]) < 1e-6 and key[1] < best[0][1]):
            best = (key, r)
    return best[1] if best else None


def fetch_cover(url: str):
    if not url:
        return None
    # 100x100bb -> 600x600bb; the mzstatic CDN serves any size off the same id
    big = url.replace("100x100bb", "600x600bb").replace("60x60bb", "600x600bb")
    data = _get(big)
    return data if len(data) >= ART_MIN else None


def embed(path: str, img: bytes, mime: str = "image/jpeg") -> None:
    ext = os.path.splitext(path)[1].lower()
    if ext in (".opus", ".ogg"):
        f = OggOpus(path) if ext == ".opus" else OggVorbis(path)
        pic = Picture()
        pic.type, pic.mime, pic.desc = 3, mime, "Cover"
        pic.data = img
        f["metadata_block_picture"] = [base64.b64encode(pic.write()).decode("ascii")]
    elif ext in (".m4a", ".aac", ".mp4"):
        f = MP4(path)
        f["covr"] = [MP4Cover(img, imageformat=MP4Cover.FORMAT_JPEG)]
    elif ext == ".mp3":
        f = MP3(path)
        f.tags = f.tags or ID3()
        f.tags.delall("APIC")
        f.tags.add(APIC(encoding=3, mime=mime, type=3, desc="Cover", data=img))
    else:
        return
    f.save()


def has_art(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext in (".opus", ".ogg"):
            f = OggOpus(path) if ext == ".opus" else OggVorbis(path)
            return bool(f.get("metadata_block_picture"))
        if ext in (".m4a", ".aac", ".mp4"):
            return bool(MP4(path).get("covr"))
        if ext == ".mp3":
            return bool(MP3(path).tags and MP3(path).tags.getall("APIC"))
    except Exception:
        pass
    return False


def read_tags(path: str):
    """Current (artist, title) from the file itself.

    ffprobe reports no format_tags at all for Ogg/Opus, so wanted.probe_tags would
    hand back the filename on most of this library. mutagen reads the real comment
    headers, which makes the change count honest.
    """
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext in (".opus", ".ogg"):
            f = OggOpus(path) if ext == ".opus" else OggVorbis(path)
            a, t = f.get("artist"), f.get("title")
        elif ext in (".m4a", ".aac", ".mp4"):
            f = MP4(path)
            a, t = f.get("\xa9ART"), f.get("\xa9nam")
        elif ext == ".mp3":
            g = MP3(path).tags or {}
            a, t = g.get("TPE1"), g.get("TIT2")
        else:
            a = t = None
        a = str(a[0]) if a else ""
        t = str(t[0]) if t else ""
        if a or t:
            return a, t
    except Exception:
        pass
    return probe_tags(path)


def write_tags(path: str, artist: str, title: str, album: str = "",
               year: str = "", track: str = "", dry: bool = False) -> None:
    ext = os.path.splitext(path)[1].lower()
    if dry:
        return
    if ext in (".opus", ".ogg"):
        f = OggOpus(path) if ext == ".opus" else OggVorbis(path)
        f["artist"] = [artist]
        f["title"] = [title]
        f["albumartist"] = [artist]
        if album:
            f["album"] = [album]
        if year:
            f["date"] = [year]
        if track:
            f["tracknumber"] = [track]
        # yt-dlp leaves the uploader's blurb behind; it is noise in mympd
        for junk in ("comment", "description", "purl", "synopsis", "channel"):
            if junk in f:
                del f[junk]
        f.save()
    elif ext in (".m4a", ".aac"):
        f = MP4(path)
        f["\xa9ART"] = [artist]
        f["\xa9nam"] = [title]
        f["aART"] = [artist]
        if album:
            f["\xa9alb"] = [album]
        if year:
            f["\xa9day"] = [year]
        if track:
            f["trkn"] = [(int(track.split("/")[0] or 0), 0)]
        for junk in ("\xa9cmt", "desc", "ldes"):
            if junk in f:
                del f[junk]
        f.save()


def read_tags(path: str):
    """Current (artist, title) from the file itself.

    ffprobe reports no format_tags at all for Ogg/Opus, so wanted.probe_tags would
    hand back the filename on most of this library. mutagen reads the real comment
    headers, which makes the change count honest.
    """
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext in (".opus", ".ogg"):
            f = OggOpus(path) if ext == ".opus" else OggVorbis(path)
            a, t = f.get("artist"), f.get("title")
        elif ext in (".m4a", ".aac", ".mp4"):
            f = MP4(path)
            a, t = f.get("\xa9ART"), f.get("\xa9nam")
        elif ext == ".mp3":
            g = MP3(path).tags or {}
            a, t = g.get("TPE1"), g.get("TIT2")
        else:
            a = t = None
        a = str(a[0]) if a else ""
        t = str(t[0]) if t else ""
        if a or t:
            return a, t
    except Exception:
        pass
    return probe_tags(path)


def write_tags(path: str, artist: str, title: str, album: str = "",
               year: str = "", track: str = "", dry: bool = False) -> None:
    ext = os.path.splitext(path)[1].lower()
    if dry:
        return
    if ext in (".opus", ".ogg"):
        f = OggOpus(path) if ext == ".opus" else OggVorbis(path)
        f["artist"] = [artist]
        f["title"] = [title]
        f["albumartist"] = [artist]
        if album:
            f["album"] = [album]
        if year:
            f["date"] = [year]
        if track:
            f["tracknumber"] = [track]
        # yt-dlp leaves the uploader's blurb behind; it is noise in mympd
        for junk in ("comment", "description", "purl", "synopsis", "channel"):
            if junk in f:
                del f[junk]
        f.save()
    elif ext in (".m4a", ".aac"):
        f = MP4(path)
        f["\xa9ART"] = [artist]
        f["\xa9nam"] = [title]
        f["aART"] = [artist]
        if album:
            f["\xa9alb"] = [album]
        if year:
            f["\xa9day"] = [year]
        if track:
            f["trkn"] = [(int(track.split("/")[0] or 0), 0)]
        for junk in ("\xa9cmt", "desc", "ldes"):
            if junk in f:
                del f[junk]
        f.save()


def cover(need: str, have: set) -> float:
    """Fraction of the want-row's words that appear in this file's text.

    Substring containment is too brittle for real uploads: the catalogue says
    "Sidney Bechet & His New Orleans Feetwarmers", the uploader wrote "by Sidney
    Bechet and his New Orleans Feetwarmers", and one inserted word breaks the test.
    Word coverage forgives the insert and still refuses a different song.
    """
    toks = set(need.split())
    if not toks:
        return 0.0
    return len(toks & have) / len(toks)


def best_want(text: str, want):
    """The want-list row this file is: best word coverage of artist and title."""
    have = set(text.split())
    best, score = None, 0.0
    for a, t in want:
        na, nt = norm(a), norm(t)
        if not nt:
            continue
        ca, ct = cover(na, have), cover(nt, have)
        # 0.75 title coverage is the normal bar. Allow one missing word out of three
        # when the artist is unmistakable and at least two title words survive, which
        # is what "Franklin St Blues" vs "Franklin Street Blues" looks like.
        if ct < 0.75 and not (ct >= 0.6 and ca >= 0.8
                              and len(set(nt.split()) & have) >= 2):
            continue                     # not the same song, whatever the artist says
        s = ca * 0.9 + ct + (0.15 if nt in text else 0.0)
        if s > score:
            best, score = (a, t), s
    return best if score >= 1.45 else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("library")
    ap.add_argument("--dry", action="store_true", help="say what would change, write nothing")
    ap.add_argument("--only-tags", action="store_true", help="fix names from the csv, no network")
    ap.add_argument("--force", action="store_true", help="re-fetch art even if already present")
    ap.add_argument("--extra", action="append", default=[], metavar="CSV",
                    help="additional artist,title list (repeatable) for rows songs.csv lacks")
    ap.add_argument("--sleep", type=float, default=3.0,
                    help="seconds between itunes calls (their limit is ~20/minute)")
    args = ap.parse_args()

    want = []
    for path in [args.csv] + args.extra:
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                a = (row.get("artist") or "").strip()
                t = (row.get("title") or "").strip()
                if a or t:
                    want.append((a, t))

    files = []
    for root, _, names in os.walk(args.library):
        for fn in sorted(names):
            if fn.lower().endswith(AUDIO):
                files.append(os.path.join(root, fn))

    renamed = albumed = arted = skipped = 0
    cache = {}
    for path in files:
        base = os.path.splitext(os.path.basename(path))[0]
        a0, t0 = read_tags(path)
        text = norm(a0) + " " + norm(t0) + " " + norm(base)
        hit = best_want(text, want)
        if not hit:
            skipped += 1
            print(f"  ?  {base}  (not in songs.csv, left alone)")
            continue
        artist, title = hit
        if (artist, title) != (a0, t0):
            renamed += 1
        if args.only_tags:
            write_tags(path, artist, title, dry=args.dry)
            print(f"  =  {artist} - {title}")
            continue

        if not args.force and has_art(path):
            write_tags(path, artist, title, dry=args.dry)
            continue

        key = (artist.lower(), title.lower())
        if key not in cache:
            try:
                cache[key] = itunes(artist, title)
            except Exception as e:                                   # noqa: BLE001
                if "429" in str(e):
                    RATE_HITS.append(key)
                print(f"  !  {artist} - {title}: lookup failed ({e})", file=sys.stderr)
                cache[key] = None
            time.sleep(args.sleep)
        res = cache[key]
        if not res:
            write_tags(path, artist, title, dry=args.dry)
            print(f"  -  {artist} - {title}  (no catalogue match, names only)")
            continue

        album = clean(res.get("collectionName"))
        year = (res.get("releaseDate") or "")[:4]
        trk = str(res.get("trackNumber") or "")
        # The catalogue spells it for humans ("Cabaret", not "Cabaret (Single
        # Version)"), and album+artist+title then agree with each other.
        title = clean(res.get("trackName")) or title
        artist = clean(res.get("artistName")) or artist
        img = None
        try:
            img = fetch_cover(res.get("artworkUrl100", ""))
        except Exception as e:                                       # noqa: BLE001
            print(f"  !  art failed for {artist} - {title}: {e}", file=sys.stderr)
        write_tags(path, artist, title, album, year, trk, dry=args.dry)
        if img:
            arted += 1
            if not args.dry:
                try:
                    embed(path, img)
                except Exception as e:                               # noqa: BLE001
                    print(f"  !  embed failed for {base}: {e}", file=sys.stderr)
        if album:
            albumed += 1
        print(f"  +  {artist} - {title}  [{album or 'no album'}{', ' + year if year else ''}]"
              f"{' +art' if img else ''}")

    print(f"\n{len(files)} file(s): {renamed} renamed, {albumed} album, {arted} with cover art,"
          f" {skipped} not in songs.csv.")
    if RATE_HITS:
        print(f"{len(RATE_HITS)} lookup(s) were rate-limited; just run it again — files that"
              f" already have art are skipped, so only these come back.")
    if not args.dry:
        print("reload:  sudo systemctl restart mpd")
    return 0


if __name__ == "__main__":
    sys.exit(main())
