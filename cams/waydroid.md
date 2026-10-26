# Cameras on the mini PC: Waydroid — **PARKED**

Status: installed, app runs, **cannot reach the network**. Not because of us — this
Android image has no working DHCP client and no CLI way to hand it a DNS server.
Kept here so nobody repeats the experiment, and in case a future Waydroid image fixes it.

Verdict: **RTSP is the path.** See "Phase 2" in the README. The blocker there is the DVR
password, which can be *set* (not recovered) from the DVR's own monitor:
`Menu → System → Users`.

---

## Why Waydroid was tried

The DVR is an XiongMai/XMEye OEM (`RXCamView`, serial `RSV…`). Its local protocol is
proprietary Sofia on `:34567` — ffmpeg, mpv and go2rtc cannot speak it. RTSP on `:554`
exists only on some firmwares. So: run the vendor's own Android app instead of fighting
the protocol.

Two things made that plausible on CachyOS: `waydroid` (`extra`) + `waydroid-image`
(`cachyos`), and binderfs already built into the kernel (`grep binder /proc/filesystems`
→ `nodev binder`), so no DKMS and no module rebuilds.

## What worked

```bash
sudo pacman -S waydroid waydroid-image
sudo waydroid init
sudo systemctl enable --now waydroid-container
waydroid session start &
waydroid show-full-ui &
```

The APK is **arm64-only** (`bsdtar -tf rxcamview.apk` shows just `lib/arm64-v8a/`:
`libIOTCAPIs.so`, `libRSNet.so`, `libRSPlay.so` …), and the image is x86_64, so a plain
`waydroid app install` is a silent no-op. It needs ARM translation:

```bash
sudo pacman -S --needed git python python-virtualenv lzip patchelf unzip wget
git clone https://github.com/casualsnek/waydroid_script
cd waydroid_script
sudo python3 -m venv venv
sudo venv/bin/pip install -r requirements.txt
sudo venv/bin/python3 main.py install libndk
```

After that, `waydroid app install rxcamview.apk` works and the app opens
(`com.client.rxcamview`). Everything up to the login screen is fine.

## Where it died: no DNS inside the container

`eth0` comes up with only a link-local IPv6 address — Android's DHCP client never runs, so
netd never receives a lease and the network object has no DNS:

```
NetworkAgentInfo{network{100} ni{Ethernet CONNECTED …
  DnsAddresses: [ ] Domains: null
  Routes: [ fe80::/64 -> :: eth0, 192.168.240.0/24 -> 0.0.0.0 eth0 ]}}
```

The host side is correct and was never the problem: `waydroid0` = `192.168.240.1/24`,
dnsmasq running with `--dhcp-range 192.168.240.2,192.168.240.254`, `ip_forward=1`,
ufw allowing routed traffic. Bouncing `eth0` inside Android doesn't trigger a lease either.

Address and routing *can* be forced by hand, and this part genuinely works:

```bash
sudo waydroid shell ip addr add 192.168.240.112/24 dev eth0
# the default must go in the per-network table, not `main` — Android policy-routes to it
sudo waydroid shell ip route add default via 192.168.240.1 dev eth0 table eth0
timeout 8 sudo waydroid shell ping 1.1.1.1        # replies
timeout 8 sudo waydroid shell ping google.com     # "unknown host"
```

DNS is where every door closes on Android 13:

| Attempt | Result |
|---|---|
| `setprop net.dns1 …` | ignored, that's pre-Android-10 plumbing |
| `ndc resolver setnetdns eth0 "" 192.168.240.1` | `500 0 Command not recognized` — resolver subcommand removed from `ndc` |
| `dhcptool eth0` | not shipped in this image |
| `cmd ethernet …` | `No shell command implementation` |
| `dumpsys dnsresolver` | `NetId: 100`, `No DNS servers defined` |

So `ping 1.1.1.1` works and any hostname fails. The vendor login needs hostnames.

## CLI gotchas worth keeping

- `waydroid`'s own argument parser eats flags meant for Android:
  `waydroid shell ping -c 2 1.1.1.1` → `unrecognized arguments: -c 2`. Same for
  `sh -c …` and `logcat -d`. Work around with `timeout N waydroid shell ping 1.1.1.1`.
- `sudo waydroid …` fails with `Using X11 for dbus-daemon autolaunch was disabled at
  compile time` — sudo drops the session bus. Only `shell` actually needs root.
- `waydroid app install` is a **silent** no-op when the session is not running or the file
  path is wrong.
- `waydroid adb` only does `connect`/`disconnect`; it is not an adb passthrough.

## If someone revisits this

The cheapest test is not the app at all — put the vendor's hostnames in
`/system/etc/hosts` instead of giving Android a resolver (CDN addresses, so it decays).
Better: get the DVR password, run `./probe.sh <dvr-ip> admin '<pass>'`, and if `:554`
answers, delete this file and use mpv. Keep the audio conflict in mind too: `mpd` owns the
USB DAC through ALSA `hw:`, so anything else that wants to make sound needs to be muted or
routed to a dummy sink.
