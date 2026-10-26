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
import re
import subprocess
import sys
import unicodedata

AUDIO = (".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav", ".aac")


def norm(s: str) -> str:
    # Pandora writes "Cabaret (Single Version)", "Memphis Blues (feat. Bob Haggart ...)",
    # "Sway (Quien Será)" and the downloads say "Cabaret", "Memphis Blues", "Sway".
    # Every bracketed aside goes, so the two sides can meet. Accents go too, because
    # "Pérez Prado" and "Perez Prado" are the same band.
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    s = re.sub(r"[\(\[].*?[\)\]]", " ", s)
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


def cover(need: str, have: set) -> float:
    """Fraction of a want-row's words that appear in a file's text.

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
    """Which want-row this file is, if any: best word coverage of artist and title."""
    have = set(text.split())
    best, score = None, 0.0
    for row in want:
        a, t = row[0], row[1]          # (artist, title) or (artist, title, station)
        na, nt = norm(a), norm(t)
        if not nt:
            continue
        ca, ct = cover(na, have), cover(nt, have)
        # 0.75 title coverage is the normal bar. Allow one missing word of three when
        # the artist is unmistakable and two title words survive, which is what
        # "Franklin St Blues" vs "Franklin Street Blues" looks like.
        if ct < 0.75 and not (ct >= 0.6 and ca >= 0.8
                              and len(set(nt.split()) & have) >= 2):
            continue
        score_now = ca * 0.9 + ct + (0.15 if nt in text else 0.0)
        if score_now > score:
            best, score = (a, t), score_now
    return best if score >= 1.45 else None


def clean(s: str) -> str:
    """Human-readable tag: drop "(feat. ...)" and "(Single Version)" noise."""
    s = re.sub(r"[\(\[].*?[\)\]]", " ", s or "")
    return " ".join(s.split())


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

    # Which file is which row: same rule tags.py uses to name things, so "have" here
    # and "tagged" there never disagree.
    have_keys, have_full = [], []
    matched_rows = set()
    for root, _, files in os.walk(args.library):
        for fn in files:
            if not fn.lower().endswith(AUDIO):
                continue
            path = os.path.join(root, fn)
            a, t = tags(path)
            text = norm(a) + " " + norm(t) + " " + norm(os.path.splitext(fn)[0])
            have_full.append(text)
            hit = best_want(text, want)
            if hit:
                matched_rows.add((hit[0], hit[1]))
    have_keys = sorted(set(have_full))

    missing, matched = [], 0
    for a, t, station in want:
        if (a, t) in matched_rows:
            matched += 1
            continue
        missing.append((a, t, station))

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow(["artist", "title", "station"])
        w.writerows(missing)

    print(f"want {len(want)}  have {matched}  missing {len(missing)}  "
          f"library {len(have_full)}  ->  {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
