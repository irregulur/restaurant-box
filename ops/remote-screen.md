# Watching the mini PC's screen from another machine

Needed because the box lives at the restaurant and you are not driving to it to see
whether the menu is on screen. Two things were tried; one works.

## What was rejected: krdp (KDE's RDP server)

`krdp` looked ideal (Plasma-native, clipboard, dynamic resolution). It never accepted a
login. The server config is `~/.config/krdpserverrc`:

```ini
[General]
Certificate=/home/<user>/.local/share/krdpserver/krdp.crt
CertificateKey=/home/<user>/.local/share/krdpserver/krdp.key
Users=<user>
```

`Users=` is an **allowlist of usernames**, and the file holds no password — krdp validates
through PAM. With a username that does not exist on the box, the client sails through NLA
and is then dropped with `ERRINFO_LOGOFF_BY_USER` ("the disconnection was initiated by the
user logging off their session"); with the real account it fails earlier at
`nla_recv_pdu` with `ERRCONNECT_LOGON_FAILURE`. RDP also requires NLA
(`HYBRID_REQUIRED_BY_SERVER` if you force `/sec:tls`), and it attaches to an *existing*
session, so autologin is mandatory.

Not worth it. Use Sunshine.

## What works: Sunshine + Moonlight

Server (the mini PC):

```bash
sudo pacman -S --needed sunshine vkms        # vkms is in the kernel, this is just insurance
```

The unit is **not** called `sunshine.service` — the package ships
`app-dev.lizardbyte.app.Sunshine.service`, and it is a **user** unit:

```bash
systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
systemctl --user reset-failed app-dev.lizardbyte.app.Sunshine.service   # after a crash loop
```

Web UI: `https://<mini-pc>:47990`. First visit fails with a CSRF error — add the origin to
`~/.config/sunshine/sunshine.conf`. A working config for this box (Intel Haswell iGPU, no
monitor attached):

```ini
csrf_allowed_origins = https://<mini-pc>:47990
capture = kms
adapter_name = /dev/dri/card0
encoder = software
```

`encoder = software` is not a preference, it is the only thing that starts: the virtual
display has no render node, and Sunshine uses one device for capture *and* encode. Letting
it auto-probe finds `h264_vulkan` and SEGVs inside `libLLVM` (`MESA-INTEL: warning: Haswell
Vulkan support is incomplete`), which takes the service down with `start-limit-hit`.
With a real monitor plugged into the DisplayPort, `vaapi` becomes available — install
`libva-intel-driver` (the legacy i965 driver; `intel-media-driver` needs Gen8+).

### The headless problem, and the free fix

With no monitor plugged in, `cat /sys/class/drm/*/status` prints `disconnected` for every
connector, KWin creates no output, and Sunshine dies with:

```
Fatal: Unable to find display or encoder during startup
Please check that a display is connected and powered on
```

No fancy encoder can fix that — there is no framebuffer to capture. `vkms`, the in-tree
virtual DRM driver, gives the machine a fake connected monitor for $0:

```bash
sudo modprobe vkms
echo vkms | sudo tee /etc/modules-load.d/vkms.conf     # survive reboots
cat /sys/class/drm/*/status                            # card0-Virtual-1 -> connected
```

Then set a sane mode (KDE tools need the session env when run over SSH — the socket is
usually `wayland-1`, not `wayland-0`):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-1
kscreen-doctor -o
kscreen-doctor output.Virtual-1.mode.1920x1080@60
```

A $8 "DisplayPort headless dummy plug" does the same job with real hardware timing; vkms
avoids buying one, at the cost of software encoding.

Client (your laptop):

```bash
sudo pacman -S --needed moonlight-qt
```

Open the web UI once to pair (it prints a 4-digit PIN). Open these on the mini PC if
`ufw` is enabled: TCP 47984 47989 47990 48010 and UDP 47998-48010 from your LAN.

Moonlight starts fullscreen; **Settings → Basic → Display mode → Windowed** makes it a
window you can move to a corner. `Ctrl+Alt+Shift+Z` toggles input capture,
`Ctrl+Alt+Shift+Q` quits the stream.

## Why this matters for the kiosk

Sunshine is how you check, from home, that the two buttons look right, that the screen is
not locked, and that the music page actually loaded — the things an employee will not be
able to describe over the phone. It is admin-only; nothing on it faces the internet.
