# restaurant-box

Headless setup for the restaurant mini PC (CachyOS): **background music on our speakers**,
**live view of the other site's DVR cameras**, and **remote admin from home**.

**Status:** music is done and self-healing. Cameras are one field away from done — the DVR
password, which can be *set* (not recovered) on the DVR's own monitor at site B:
`Menu → System → Users`. See Phase 2 for why the path changed.

## Install (one line, on the mini PC)

```bash
curl -fsSL https://raw.githubusercontent.com/irregulur/restaurant-box/main/install.sh | sudo bash
```

Then the only hand-edits:

```bash
aplay -l                                  # find the USB DAC's card name
sudoedit /etc/mpd.conf                    # audio_output -> device "hw:NAME,0"
sudo systemctl restart mpd
rsync -av ~/Music/restaurant/ /srv/music/  # music appears on its own within 20 s
sudo tailscale up --ssh                   # then: ssh <host>, http://<host>:9090
```

No audio files yet? Everything installs and runs, but there is silence until tracks land in
`/srv/music` — `songs.csv` is a want-list, not audio. `restaurant-wanted` tells you what to buy.

```
SITE B                                    SITE A (mini PC + speakers)
┌──────────────────┐                     ┌──────────────────────────────────────────┐
│ Cobra DVR        │  vendor P2P cloud   │ mini PC                                  │
│  (XM/XMEye OEM)  │ ◄──── phones ───────│   mpd ──► USB DAC ──► amp ──► speakers   │
│  serial RSV…     │                     │   mpv ──► full-screen cameras (Phase 2)  │
│  :34567 Sofia    │   :554 forward?     │   mympd :8080   (staff phone control)    │
│  :554 RTSP?      │ ────────────────────┼─► cockpit :9090, sshd, sunshine :47990   │
└──────────────────┘                     │   tailscale ◄──────── your home          │
                                         └──────────────────────────────────────────┘
```

**Tailscale is for remote admin of the mini PC only** — never for video. Today the phones keep
working through the DVR's own P2P cloud, and that stays true no matter what this box does.

---

## What the employees see

The box boots straight to a desktop with **two big buttons** — nothing else to learn.
Autologin is installed, so a power cut ends with the menu back on screen, no login prompt.

| Button | Opens | Needs |
|---|---|---|
| **Music** | mympd in its own window: play/pause, volume, playlist | nothing — works today |
| **Cameras** | `mpv` full screen on the DVR's video stream | the DVR password, once (Phase 2) |

Both are ordinary `.desktop` launchers, so they also appear in the app menu.

The **Music** window opens by itself when the box finishes booting (an autostart entry in
`~/.config/autostart/`), so a shift starts with the player on screen instead of an empty
desktop. If someone closes it, the **Music** button brings it straight back.

No KDE Wallet dialog at login either: the installer writes `~/.config/kwalletrc` with the
wallet disabled, and the player's browser is started with `--password-store=basic`. There
is nothing secret on this box, so there is nothing for a wallet to ask about.
If something is wrong the button says so in plain words ("The music player is not
responding — try again in a minute") instead of opening a blank page.

Make it feel like an appliance:

- **Settings → Power / Screen Locking**: screen energy saving *off*, screen locking *disabled*.
  A menu that goes dark mid-shift is the most likely "it's broken" call you will get.
- The desktop icons are auto-aligned by Plasma; drag them apart once, Plasma remembers.
- `restaurant-audio` restarts mpd and rebuilds the playlist on its own — an employee only
  ever needs the two buttons, and "try again in a minute" is genuinely the right advice.

```bash
restaurant-music          # same as the Music button, useful over ssh
restaurant-cams           # same as the Cameras button
mpc status               # what is actually playing, from a terminal
```

---

## What goes where

| Piece | Node | Why there |
|---|---|---|
| `mpd` + `mympd` | A | speakers are at A |
| `tailscale` | A (+ your home devices) | remote admin only — not needed for cameras |
| `cockpit` + `sshd` | A | browser/terminal admin from home |
| `go2rtc` | **only if** the DVR turns out to serve RTSP | it must sit on the DVR's own LAN (site B) |

---

## Phase 1 — music (site A)

```bash
sudo ./install.sh                 # mpd, mympd, tools, dirs, units, suspend masked

# 1. put audio in the library (FLAC/MP3/M4A/OGG all fine)
rsync -av ~/Music/restaurant/ mini:/srv/music/     # or copy by hand

# 2. fix the DAC device name once — this is the only thing that ever needs hand-editing
aplay -l                          # e.g. "card 1: PCH [HDA Intel PCH], device 0"
sudoedit /etc/mpd.conf            # audio_output.device -> "hw:PCH,0"  (USB DAC: hw:CODEC,0)

sudo systemctl enable --now mpd mympd restaurant-audio
```

`restaurant-audio` is not "start mpd once" — it is a keeper loop. Every 20 s it makes sure
mpd is running, the queue is not empty, and something is actually playing. Staff can hit
stop, the amp can lose power, mpd can crash; music comes back by itself.

Music control: `http://<mini-pc>:8080` → mympd from any phone, or `mpc` over SSH.
The queue is rebuilt and reshuffled each boot, so no infinite loop on one track.

#### Building the queue from the terminal

The queue is a playlist of everything in `/srv/music` — no need to add tracks one by one:

```bash
mpc update                 # scan the library for new files (also happens automatically)
mpc clear                  # empty the queue
mpc add /                  # queue every file in the library
mpc repeat 1               # loop the queue, not one track
mpc random 1               # shuffle (0 = play the queue in order)
mpc play
mpc save restaurant        # remembers it as "restaurant" -> later: mpc load restaurant
mpc status                 # [playing] + track + volume
```

`restaurant-audio` does the same thing automatically whenever the queue is empty, so this is
the manual version of what already happens after a reboot. Volume is `mpc volume +5` /
`mpc volume 70`; the whole thing is also `mympd` at `http://<mini-pc>:8080`.

#### Removing a song

There is no "hide" — mpd indexes everything under `/srv/music`, so a file is in the library.
Delete it:

```bash
mpc search -f '%file%' title 'No One in the World'   # -> the path, relative to /srv/music
rm -- /srv/music/'Anita Baker - No One in the World.m4a'
mpc update                                            # prunes it from the library
mpc clear && mpc add /                                # rebuild the queue without it
```

Also delete the line from `pandora/songs.csv`, otherwise a future `music/fetch.sh` run will
go looking for it again.

#### Making the volume even

Some tracks are mastered much louder than others (`Such a Night` next to a 1950s 78 rpm
transfer). mpd is already configured for `replaygain "track"`, but that only works once the
files carry ReplayGain tags — downloads do not have them. Scan the library once:

```bash
paru -S --needed rsgain     # AUR; or the self-contained binary from
                            # https://github.com/complexlogic/rsgain/releases (no build)
sudo ./music/tag-gain.sh /srv/music          # writes the tags, never touches audio
sudo systemctl restart mpd
```

`music/tag-gain.sh` calls `rsgain custom -s i -c p` on the files explicitly. Use it rather
than `rsgain easy`: on a flat library (no album folders) easy mode reports
"Found 1 directory... No files were scanned" and does nothing.

Check a file with `strings` — for Ogg/Opus, `ffprobe` does not show these:

```bash
strings /srv/music/*.opus[1] | grep REPLAYGAIN
```

mpd picks the tags up on the next restart (`sudo systemctl restart mpd`). If everything is
now too quiet overall, raise it in `/etc/mpd.conf`:

```
replaygain_preamp   "+3.0"
```

Re-run `tag-gain.sh` after adding music. `loudgain` is the older alternative (AUR) if rsgain
gives you trouble; mpd's own `volume_normalization "yes"` exists but it is a crude
peak-normalizer and flattens the dynamics — use ReplayGain.

### Names and cover art

yt-dlp is honest about the audio and careless about the metadata: a user upload lands as
artist `mangeldeth74`, title `Louis Jordan - Is You Is Or Is You Ain't`. `songs.csv` is the
ground truth for names, and the catalogue can supply the album and its cover:

```bash
sudo pacman -S --needed python-mutagen
./music/tags.py songs.csv /srv/music --dry     # preview, changes nothing
./music/tags.py songs.csv /srv/music           # ~225 lookups, ~3 s apart, ~11 min
sudo systemctl restart mpd
```

What it does:

- rewrites artist and title from the matching `songs.csv` row, using the same loose
  matching as `wanted.py` — so `mangeldeth74 - Louis Jordan - Is You Is ...` becomes
  `Louis Jordan / Is You Is Or Is You Ain't (My Baby)`;
- adds album, release year and track number from the catalogue entry it picks (exact
  title/artist beats fuzzy, an earlier release beats a later re-issue, karaoke and
  tribute uploads are scored out);
- downloads the 600×600 cover and embeds it in the file (`METADATA_BLOCK_PICTURE` for
  Ogg/Opus, `covr` for m4a) so mympd shows a picture instead of a placeholder;
- strips yt-dlp's `comment`/`description` blurb;
- never renames or moves files, so the mpd queue and `restaurant-audio.sh` keep working;
- is safe to re-run: files that already have a cover are skipped (`--force` redoes them,
  `--only-tags` fixes names with no network at all).

Read the output: `+` tagged with art, `-` corrected names but the catalogue had no match
(obscure 78 rpm transfers land here), `?` the file is not in `songs.csv` and was left alone.

Matching ignores everything Pandora wraps in brackets — `Cabaret (Single Version)`,
`Memphis Blues (feat. Bob Haggart ...)`, `Sway (Quien Será)` — and ignores accents, so
`Pérez Prado` and `Perez Prado` are one band. Files that genuinely have no row can be
named from a hand-written list instead of editing the original CSV:

```
music/songs-supplement.csv
```

```bash
./music/tags.py songs.csv /srv/music --extra music/songs-supplement.csv
```

The catalogue announces itself with the same bracketed noise, so names are written clean:
`Diga Diga Doo`, not `Diga Diga Doo (feat. Clint Baker, Duke Heitger, ...)`.

### Turning `pandora/songs.csv` into a shopping list

```bash
python3 music/wanted.py ~/Documents/Projects/pandora/songs.csv /srv/music
# -> "have 12 / 234", writes wanted-missing.csv (artist,title still to source)
```

Buy those on Bandcamp/Qobuz/Amazon, drop them in `/srv/music`, re-run until the miss list is
short. Keep `pianobar` running at home — it's your discovery engine; the CSV is the queue.

#### Fastest: files on disk tonight

```bash
sudo pacman -S --needed yt-dlp ffmpeg
./music/fetch.sh ~/songs.csv /srv/music --dry-run    # what would each search resolve to?
./music/fetch.sh ~/songs.csv /srv/music              # do it
```

`fetch.sh` asks `wanted.py` what is still missing, turns every missing row into a
`ytsearch1:<artist> <title>` query, and hands the list to yt-dlp. Three things keep it from
making a mess:

- `--match-filter 'duration > 90 & duration < 600'` throws out the 3-hour "smooth jazz
  compilation" uploads and 30-second previews that dominate search results.
- `--audio-format best` extracts the native stream and **re-encodes nothing**, so it is fast
  and lossless relative to the source (m4a/aac and opus are both fine for mpd).
- `--download-archive /srv/music/.ytdl-archive` remembers video ids, so a second run only
  touches what is new instead of re-fetching 200 files.

Always run `--dry-run` first: it prints the actual video title and uploader behind each
search, which is how you spot the live take or the karaoke cover before it lands in the
library. Anything skipped (no match, wrong duration, taken down) stays in the miss list —
those are the ones worth buying.

### Licensing (the part software can't fix)

A personal Pandora/Spotify account on business speakers violates their ToS, and US public
performance technically wants ASCAP/BMI/SESAC. Cheapest legal floor: a commercial service
(Soundtrack Your Brand / Pandora for Business / Rockbot), with your owned tracks as the
curated rotation on top. Many small venues run exactly that hybrid.

---

## Phase 2 — cameras (site B, shown at A)

**Target: one screen.** Music from `mpd`, cameras in `mpv` full screen, one kiosk.

The Android-app route (Waydroid) was built and worked — container, arm64 translation, app
launching — but it cannot log in, because that Android image has no DHCP client and Android 13
leaves no CLI to inject a DNS server: `ping 1.1.1.1` replies while every hostname fails. It is
**parked**, with the full post-mortem in `cams/waydroid.md`. **RTSP is the path**: one `mpv`
process on the host, iGPU decode, no Android layer, no ARM translation, no netd.

One honest caveat: RTSP listens only on the DVR's own LAN, and the mini PC is at the *other*
restaurant. So this needs **one port forward on site B's router** (you have the router; that's a
config change, not a purchase) — or a small always-on box at site B instead. The vendor cloud
exists precisely to avoid that, and it only speaks to the Android app.

The password is needed either way. `RXCamView` + the `RSV…` serial means the DVR is an
**XiongMai / XMEye (Sofia) OEM** — same family as XMEye, gCMOB, vMEyeSuper, KMEye.

| | |
|---|---|
| Live view from anywhere | ✅ P2P cloud, no ports, no Tailscale needed |
| RTSP | **maybe** — many XM firmwares do serve it on :554, many don't. Test, don't assume |
| Local protocol | :34567 Sofia (proprietary — ffmpeg/go2rtc cannot speak it) |
| ONVIF | sometimes, on :8899, often unauthenticated snapshots |
| Cloud reality | vendor relay sees your video; the serial + password is all anyone needs |

### Plain terms: what RTSP is and why we care

Right now the video only exists **inside the vendor's cloud**. The phone app connects out to
`RXCamView`'s servers using the `RSV…` serial, and those servers relay the stream to you — that's
why it works from home with no setup, and also why nothing else can show the picture.

**RTSP** is just a generic video URL (`rtsp://…`). Many DVRs offer one *in addition* to the app.
If this DVR does, any program can open it — VLC, `go2rtc`, a recorder — and the cameras stop being
a phone-only thing. Benefit: no Android layer, less CPU, a better picture, and recording becomes
possible later. Cost: RTSP only listens on the DVR's own network, so to watch from the *other*
restaurant you must either forward a port on site B's router or put a small always-on device there.
If you can't log into that router, RTSP changes nothing for you — which is why the Android-app
path was tried first.

### The 10-minute RTSP check (optional)

Cheapest version, no laptop: on site B's DVR monitor, open **Setup → Network** and look for
`RTSP`, `ONVIF`, `Media port 554`, or a `554` next to HTTP (80). Write down what's listed.

With a laptop that can join site B's network:

```bash
./cams/probe.sh 192.168.1.50 admin 'password'
```

It prints each URL it tries, then a verdict. `OK /cam/realmonitor…[h264 1280x720]` means a video
URL answers; a wall of `--` plus a verdict means that door is closed.

- **Some path plays** + router access → forward :554 (strong password, nonstandard port) and use
  `cams/install-cams.sh` locally; skip the rest of this phase.
- **Only 34567 open, no RTSP** → expected for this family. Then it's a port-forward at site B
  plus a re-probe, or back to the parked Android route — see `cams/waydroid.md`.

### If you do end up with RTSP

Use the **sub stream** (`stream=1` / `subtype=1` / `102`) for remote viewing — a 4-cam main-stream
is 30 Mbit and will stutter over WAN; sub streams are ~1 Mbit each and look fine at kiosk size.
If the DVR only emits H.265, append `#video=h264` and go2rtc transcodes.

Low-bandwidth trick: `http://<dvr>/webcapture.jpg?command=snap&channel=1` returns a JPEG on most
XM/Dahua OEMs — eight channels of 1 frame / 3 s is ~10 Kbit/s total, a "wall of stills" that
survives a link where video would not.

---

## Phase 3 — remote admin

```bash
tailscale up --ssh                     # both nodes; enable Tailscale SSH
sudo systemctl enable --now sshd cockpit.socket
```

From home: `http://<mini-pc>:9090` (Cockpit: services, logs, terminal, reboots, disk) or
`ssh mini`. Cockpit covers ~95 % of "something broke" without a GUI.

Two things that make this survive a year without you thinking about it:

- **Disable key expiry for the box** in the Tailscale admin console (Machines → the box →
  *Disable key expiry*). The default is 180 days, after which the node silently drops off the
  tailnet and "remote access" quietly stops working — the failure shows up months later, at
  the worst time.
- `ufw allow in on tailscale0`. The installer does this, but check it: CachyOS ships
  default-deny-incoming, and the LAN-scoped rules do **not** cover traffic arriving on the
  tailnet. Symptom is `tailscale status` green and ssh timing out anyway.
If you truly need the desktop: **Sunshine + Moonlight**, set up and working — recipe in
`ops/remote-screen.md`, including the headless `vkms` trick that avoids buying a dummy plug.
(`krdp` was tried first and abandoned: its `Users=` allowlist plus mandatory NLA never accepted
a login.)

Bind mympd/go2rtc to the Tailscale address only, or drop this in `/etc/nftables.d/`:

```
table inet admin {
  chain input {
    type filter hook input priority 0; policy accept;
    tcp dport { 22, 8080, 9090, 1984 } ip saddr != 100.64.0.0/10 drop
  }
}
```

---

## Ops discipline for an unattended box

- **BIOS "restore on power loss" = ON**, small UPS, and a smart plug as the last-resort hard reboot
  (SSH cannot rescue a hung box).
- **`linux-lts`** kernel, and `pacman -Syu` **only by hand over SSH** — never unattended on a
  rolling release that must not surprise you at dinner service.
- **`snapper` + `snap-pac`** on btrfs; roll back from the boot menu if an update lands badly.
- `systemctl mask sleep.target suspend.target hibernate.target` (done by `install.sh`, also
  set "never blank/suspend" in the display settings if there is a screen).
- `journalctl --setup-keys` / persistent journal, and `ops/health.sh` on a 5-minute timer pushes
  ntfy alerts (mpd not playing, go2rtc down, tunnel down, disk >90 %).
- Audio: **USB DAC or the analog jack, not HDMI.** HDMI audio dies headless when the amp is off
  at boot and is the single most common "no sound" cause in this kind of build.
- Loudness: run `rsgain easy /srv/music` (AUR) once so mpd's `replaygain track` works; a quiet
  jazz track followed by a hot master is what makes restaurant music annoying.

## Files

```
install.sh                   music + remote side (site A)
systemd/restaurant-audio.service
music/mpd.conf               minimal headless mpd, ALSA out, replaygain
music/restaurant-audio.sh    keeper loop: mpd up, queue loaded, playing
music/wanted.py              songs.csv vs library -> what still needs buying
music/fetch.sh               wanted list -> yt-dlp searches -> files in /srv/music
desktop/restaurant-music.sh  the Music button (mympd, full screen)
desktop/restaurant-cams.sh   the Cameras button (mpv on RTSP; Waydroid kept as parked fallback)
desktop/*.desktop            the two icons the employees click
cams/waydroid.md             PARKED: Android app on the mini PC, and exactly why it failed
cams/waydroid-cam.sh         parked: start container/session, launch the viewer app
ops/remote-screen.md         Sunshine + vkms: watch the box's screen from home
cams/probe.sh                DVR port + RTSP path discovery
cams/install-cams.sh         go2rtc on the node that sits next to the DVR (site B)
cams/go2rtc.yaml             stream definitions
cams/go2rtc.service
ops/health.sh + .service/.timer   ntfy watchdog
```
