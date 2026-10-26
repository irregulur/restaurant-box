#!/usr/bin/env python3
"""wanted.py — compare pandora/songs.csv (a want-list) against the local library.

Usage:  wanted.py songs.csv /srv/music [-o wanted-missing.csv]

Matches on normalized (artist, title) with a loose fuzzy fallback, because the
Pandora title carries remaster/version suffixes ("(1990 Remaster)", "Remastered")
that library tags usually do not. Writes the still-missing rows and prints a summary.
"""
import argparse
import csv
import difflib
import os
import subprocess
import sys

AUDIO = (".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav", ".aac")


def norm(s: str) -> str:
    s = s.lower()
    # Everything below is noise that YouTube/Deezer/whatever appends to a title and
    # that the want-list never has: "(1990 Remaster)", "(Official Audio)", "- Topic" ...
    for junk in ("(1990 remaster)", "(remaster)", "- remastered", "remastered",
                 "(remastered)", "(deluxe edition)", " - deluxe edition",
                 "(official audio)", "(official video)", "(official music video)",
                 "[official audio]", "[official video]", "(official lyric video)",
                 "(lyric video)", "(lyrics)", "(audio)", "[audio]", "(hq)", "(hd)",
                 "- topic", "(topic)"):
        s = s.replace(junk, "")
    keep = "".join(c if (c.isalnum() or c == " ") else " " for c in s)
    return " ".join(keep.split())


def tags(path: str):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format_tags=artist,title",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=15).stdout.splitlines()
        out = [x for x in out if x.strip()]
        if len(out) >= 2:
            return out[0], out[1]
        if out:
            return out[0], ""
    except Exception:
        pass
    # fall back to "Artist - Title.ext"
    base = os.path.splitext(os.path.basename(path))[0]
    if " - " in base:
        a, t = base.split(" - ", 1)
        return a, t
    return "", base

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("library")
    ap.add_argument("-o", "--out", default="wanted-missing.csv")
    args = ap.parse_args()

    want = []
    with open(args.csv, newline="", encoding="utf-8", errors="replace") as f:
        for row in csv.DictReader(f):
            a, t = (row.get("artist") or "").strip(), (row.get("title") or "").strip()
            if a or t:
                want.append((a, t, row.get("station", "")))

    have = set()
    for root, _, files in os.walk(args.library):
        for fn in files:
            if fn.lower().endswith(AUDIO):
                a, t = tags(os.path.join(root, fn))
                have.add((norm(a), norm(t)))
    have_keys = sorted("|".join(k) for k in have)
    # flat "everything the file claims" string, used for containment matching
    have_full = [k[0] + " " + k[1] for k in have]

    def found(a: str, t: str) -> bool:
        """Is this want-row already on disk?

        Substring containment first: the download of a user upload often lands as
        "mangeldeth74 - Louis Jordan - Is You Is ...", where the artist tag is the
        channel name. Both halves still appear somewhere in the file's text, so
        containment catches what an exact key never will. Fuzzy ratio second, for
        spelling drift ("Barry 'Kid' Martyn" vs "Barry Martyn").
        """
        na, nt = norm(a), norm(t)
        if na and nt:
            for full in have_full:
                if na in full and nt in full:
                    return True
        key = na + "|" + nt
        return bool(difflib.get_close_matches(key, have_keys, n=1, cutoff=0.86))

    missing, matched = [], 0
    for a, t, station in want:
        if found(a, t):
            matched += 1
            continue
        missing.append((a, t, station))

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow(["artist", "title", "station"])
        w.writerows(missing)

    print(f"want {len(want)}  have {matched}  missing {len(missing)}  "
          f"library {len(have)}  ->  {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
