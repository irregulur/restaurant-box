# restaurant-box

Headless setup for the restaurant mini PC (CachyOS): **background music on our speakers**,
**live view of the other site's DVR cameras**, and **remote admin from home**.

```
SITE B                                    SITE A (mini PC + speakers)
┌──────────────────┐                     ┌──────────────────────────────────────────┐
│ Cobra DVR        │  vendor P2P cloud   │ mini PC                                  │
│  (XM/XMEye OEM)  │                     │   mpd ──► USB DAC ──► amp ──► speakers   │
│  serial RSV…  ───┼──► RXCamView ───────┼─► old Samsung phone (works today)        │
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

## Phase 2 — cameras (site B)

**You already have a working solution: RXCamView + the serial (`RSV…`) + the old Samsung at A.**
`RXCamView` means the DVR is an **XiongMai / XMEye (Sofia protocol) OEM** — same family as
XMEye, gCMOB, vMEyeSuper, KMEye. Practical consequences:

| | |
|---|---|
| Live view from anywhere | ✅ already works (P2P cloud, no ports, no Tailscale) |
| RTSP | **maybe** — many XM firmwares do serve it on :554, many don't. Test, don't assume |
| Local protocol | :34567 Sofia (proprietary, ffmpeg/go2rtc cannot speak it) |
| ONVIF | sometimes, on :8899 and often no auth on snapshots |
| Cloud reality | vendor relay sees your video; the serial + password is all anyone needs |

So the question is not "how do I view the cameras" — that's solved. It's "do I want them
*inside my own tooling*" (one screen, recording, no vendor cloud, snapshots). That costs money;
viewing does not.

### Should you buy the $25 thin client?

Only if a `probe.sh` run at site B finds RTSP. Test it on a laptop plugged into the DVR's switch:

```bash
./cams/probe.sh 192.168.1.50 admin 'password'
```

- **Some path plays** → worth the thin client: `./cams/install-cams.sh cam1 'rtsp://…'`, then view at
  `http://<node-b>:1984/streams.html` from A or home, or on a kiosk screen at A.
- **Only 34567 open, no RTSP** → **buy nothing.** The Samsung phone is the correct answer. If you
  later want a kiosk instead of a phone, the cheap path is a used thin client + $12 USB HDMI
  capture of the DVR's monitor output, feeding an RTSP server — *not* a protocol reverse-engineering
  project.

Use the **sub stream** (`stream=1` / `subtype=1` / `102`) for remote viewing — a 4-cam main-stream
is 30 Mbit and will stutter over WAN; sub streams are ~1 Mbit each and look fine at kiosk size.
If the DVR only emits H.265, append `#video=h264` to the stream URL and go2rtc transcodes.

### Alternatives to the phone at A (all free)

1. **Waydroid** on the mini PC — runs the RXCamView Android APK in a container; the P2P app is
   simple enough that it often works. Experimental, requires Wayland, expect a weekend of fiddling.
2. **Older iPad/tablet in Guided Access** — slightly nicer than a phone on a charger; you already
   have iPads.
3. **Scrcpy over USB** from the mini PC to an Android device — mirrors the app into the PC's screen,
   so the "phone on the wall" becomes part of the desktop. Needs the device anyway; neat, not urgent.

Low-bandwidth idea if you ever get a node at B: `http://<dvr>/webcapture.jpg?command=snap&channel=1`
returns a JPEG on most XM/Dahua OEMs. Eight channels of 1 frame / 3 s is ~10 Kbit/s total — a
"wall of snapshots" page that works over a terrible link, where video would not.

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
cams/probe.sh              DVR port + RTSP path discovery
cams/install-cams.sh       go2rtc on the node that sits next to the DVR (site B)
cams/go2rtc.yaml           stream definitions
cams/go2rtc.service
ops/health.sh + .service/.timer   ntfy watchdog
```
