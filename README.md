# restaurant-box

Headless setup for the restaurant mini PC (CachyOS): **background music on our speakers**,
**live view of the other site's DVR cameras**, and **remote admin from home**.

Two nodes, split by where the hardware physically is:

```
SITE B (restaurant with the DVR)          SITE A (restaurant with the mini PC + speakers)
┌───────────────────────────┐             ┌──────────────────────────────────────────┐
│ Cobra DVR (own drives)    │             │ mini PC                                  │
│   └─ RTSP :554            │             │   mpd ──► USB DAC ──► amp ──► speakers   │
│ tiny node (RPi/N100)      │             │   mympd  :8080   (staff phone control)   │
│   └─ go2rtc :1984 ────────┼──tailscale──┼─► browser kiosk (or any phone/laptop)    │
│   └─ tailscale            │             │   cockpit :9090  sshd   tailscale        │
└───────────────────────────┘             └──────────────────────────────────────────┘
```

No port forwarding anywhere. Everything rides the Tailscale tunnel, so the DVR never
sees the internet and you can watch the cameras from the restaurant *or* from home.

---

## What goes where

| Piece | Node | Why there |
|---|---|---|
| `mpd` + `mympd` | A | speakers are at A |
| `go2rtc` | **B** | it must reach the DVR over its own LAN; A's browser just opens B's web UI over Tailscale |
| `tailscale` | both | the only network plumbing |
| `cockpit` + `sshd` | A (and B) | browser/terminal admin from home |

If you'd rather not add a node at B, two fallbacks (worse, in order):
1. DVR port-forward to a nonstandard port + strong password → A pulls `rtsp://` over WAN. Works, but exposes the DVR; only accept if nothing better exists.
2. DVR vendor's cloud app on a tablet at A. Zero engineering, zero privacy, usually fine for "is the fry cook still there" checks.

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

First find out what that DVR speaks. On the node at B:

```bash
./cams/probe.sh 192.168.1.50 admin 'password'     # tries ports + common RTSP paths
```

Decision tree:

- **A path plays** → `./cams/install-cams.sh cam1 rtsp://admin:pw@192.168.1.50:554/cam/realmonitor?channel=1&subtype=1`
  (repeat per channel). View at `http://<tailscale-name-b>:1984/streams.html`.
- **Only 34567 answers (Sofia/XMEye OEM)** → no RTSP. Use the vendor app, or the DVR's HDMI monitor
  output → cheap HDMI-to-RTSP encoder.
- **Nothing** → cloud P2P only; vendor app at A is your answer.

Use the **sub stream** (`subtype=1` / `102`) for remote viewing — a 4-cam main-stream grid is
30 Mbit and will stutter over WAN; sub streams are ~1 Mbit each and look fine at kiosk size.
If the DVR only emits H.265, append `#video=h264` to the stream URL and go2rtc transcodes (costs CPU).

Kiosk screen at A (optional): `chromium --kiosk --noerrdialogs http://<node-b>:1984/streams.html`

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
