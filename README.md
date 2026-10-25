# restaurant-box

Headless setup for the restaurant mini PC (CachyOS): **background music on our speakers**,
**live view of the other site's DVR cameras**, and **remote admin from home**.

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
│  (XM/XMEye OEM)  │                     │   mpd ──► USB DAC ──► amp ──► speakers   │
│  serial RSV…  ───┼──► RXCamView ───────┼─► Waydroid window (Android app)          │
│  :34567 Sofia    │                     │   mympd :8080   (staff phone control)    │
│  :554 RTSP?      │                     │   cockpit :9090, sshd                    │
└──────────────────┘                     │   tailscale ◄──────── your home          │
                                         └──────────────────────────────────────────┘
```

**Tailscale is for remote admin of the mini PC only.** Camera viewing already works from
anywhere through the DVR's own P2P cloud + RXCamView, so **no second box is required** —
see "Phase 2 — cameras" for when buying one would actually buy you something.

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
aplay -l                          # e.g. "card 1: CODEC [USB Audio CODEC], device 0"
sudoedit /etc/mpd.conf            # audio_output.device -> "hw:CODEC,0"  (hw:1,0 also works)

sudo systemctl enable --now mpd mympd restaurant-audio
```

`restaurant-audio` is not "start mpd once" — it is a keeper loop. Every 20 s it makes sure
mpd is running, the queue is not empty, and something is actually playing. Staff can hit
stop, the amp can lose power, mpd can crash; music comes back by itself.

Music control: `http://<mini-pc>:8080` → mympd from any phone, or `mpc` over SSH.
The queue is rebuilt and reshuffled each boot, so no infinite loop on one track.

### Turning `pandora/songs.csv` into a shopping list

```bash
python3 music/wanted.py ~/Documents/Projects/pandora/songs.csv /srv/music
# -> "have 12 / 234", writes wanted-missing.csv (artist,title still to source)
```

Buy those on Bandcamp/Qobuz/Amazon, drop them in `/srv/music`, re-run until the miss list is
short. Keep `pianobar` running at home — it's your discovery engine; the CSV is the queue.

### Licensing (the part software can't fix)

A personal Pandora/Spotify account on business speakers violates their ToS, and US public
performance technically wants ASCAP/BMI/SESAC. Cheapest legal floor: a commercial service
(Soundtrack Your Brand / Pandora for Business / Rockbot), with your owned tracks as the
curated rotation on top. Many small venues run exactly that hybrid.

---

## Phase 2 — cameras (site B, shown at A)

**Target: one screen.** Music from `mpd`, cameras from the RXCamView Android app running in
**Waydroid** on the same mini PC → `cams/waydroid.md`. Nothing to buy; CachyOS ships `waydroid`
(`extra`) and `waydroid-image` (`cachyos`), and binderfs is already built into its kernel.

Why an Android container instead of an RTSP client: `RXCamView` + the `RSV…` serial means the DVR
is an **XiongMai / XMEye (Sofia) OEM** — same family as XMEye, gCMOB, vMEyeSuper, KMEye.

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
If you can't log into that router, RTSP changes nothing for you — which is why Waydroid is the plan
and this is only a bonus check.

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
- **Only 34567 open, no RTSP** → expected for this family. **Buy nothing**, use Waydroid.

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
If you truly need the desktop: RustDesk (self-hosted) or `sunshine` + Moonlight.

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
install.sh                 music + remote side (site A)
systemd/restaurant-audio.service
music/mpd.conf             minimal headless mpd, ALSA out, replaygain
music/restaurant-audio.sh  keeper loop: mpd up, queue loaded, playing
music/wanted.py            songs.csv vs library -> what still needs buying
cams/waydroid.md           one-screen cameras: Android app on the mini PC
cams/waydroid-cam.sh       start container/session, launch the viewer app
cams/probe.sh              DVR port + RTSP path discovery
cams/install-cams.sh       go2rtc on the node that sits next to the DVR (site B)
cams/go2rtc.yaml           stream definitions
cams/go2rtc.service
ops/health.sh + .service/.timer   ntfy watchdog
```
