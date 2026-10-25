# Cameras on the mini PC: Waydroid

The DVR is an XiongMai/XMEye box (RXCamView + `RSV…` serial). Its only reachable
interface is the vendor's P2P cloud plus a proprietary Sofia protocol on :34567 —
so instead of trying to speak that protocol, **run the Android app itself** on the
mini PC. That is what Waydroid does: a real Android container sharing the kernel,
one window on the desktop, the cameras next to your music.

Nothing to buy. CachyOS ships everything needed:

| Package | Repo | Note |
|---|---|---|
| `waydroid` 1.6.3 | `extra` | container + session |
| `waydroid-image` | `cachyos` | Android 20 system image (no GApps — fine, we sideload) |
| binderfs | **already in the CachyOS kernel** | no DKMS, no module building |

Check the binder support on the mini PC before anything else:

```bash
grep -i binder /proc/filesystems     # expect: nodev binder
```

If that prints nothing, the kernel is missing binder → install `binder_linux-dkms`
(AUR) or use a stock kernel. On CachyOS 7.x it is built in.

---

## 1. Install the container

```bash
sudo pacman -S waydroid waydroid-image
sudo waydroid init                      # sets up /var/lib/waydroid from the image
sudo systemctl enable --now waydroid-container
waydroid status                         # Session: STOPPED, Container: RUNNING
```

## 2. Get RXCamView in as an APK

Play Store needs GApps; sideloading does not. Get the APK from APKMirror/APKPure
(or pull it off the dying phone while it still boots — see "rescue the phone" below):

```bash
waydroid app install ~/Downloads/RXCamView.apk
waydroid app list | grep -iE 'cam|rx|eye|vme'     # note the package name
```

Log in once with the same `RSV…` serial and password the phone uses. This is the
same cloud account, so it should just work.

## 3. Launch it as a window

```bash
./waydroid-cam.sh                     # lists candidate packages the first time
./waydroid-cam.sh com.example.rxcam   # launches that app
```

The desktop session must be running (Wayland — CachyOS KDE/GNOME both fine).
For a normal window that your WM can fullscreen like any other app:

```bash
waydroid prop set persist.waydroid.multi_windows true
```

Then `Alt+F11` / `Super+F` / the WM's fullscreen key, and put it on the second
monitor or a corner of the screen. `waydroid show-full-ui` gives the whole Android
launcher fullscreen instead, if you prefer that.

## 4. Autostart with the desktop

`~/.config/autostart/cameras.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Cameras
Exec=/home/user/Documents/Projects/restaurant-box/cams/waydroid-cam.sh com.example.rxcam
X-GNOME-Autostart-enabled=true
```

Do **not** try to run this from systemd — it needs your Wayland session.

---

## The one real conflict: audio

`mpd` opens the USB DAC directly through ALSA `hw:`, which **excludes every other
client**. If Android ever produces sound, PipeWire/PulseAudio will grab the DAC and
music stops. The DVR app is normally silent, so you may never hit this. If you do:

```bash
# send desktop/Android audio to a dummy sink; mpd keeps the real hardware
pactl load-module module-null-sink sink_name=silent sink_properties=device.description=Silent
pactl set-default-sink silent
```

Persist it by dropping the same two lines into `/etc/pipewire/pipewire.conf.d/` or
`~/.config/pipewire/pipewire-pulse.conf.d/` (a `context.exec` entry), or just accept
the one-liner in a startup script. Alternatively mute Android's media volume once —
it is remembered.

---

## Expected rough edges

- **NVIDIA GPU**: Waydroid wants a Wayland compositor it can embed into and does not
  like NVIDIA's driver. Intel/AMD iGPU is the happy path. If the mini PC is NVIDIA-only,
  expect swiftshader fallback (works, uglier, fine for one 480p stream) or use the
  Android-VM fallback below.
- **Video decode** is often software in Waydroid. One sub-stream at 480p/640×360 is
  ~10 % of a modern core — acceptable. A 4-cam 1080p grid will not be.
- **Fullscreen automation is the fiddly part.** `multi_windows` + a WM rule is far more
  reliable than scripting keybinds into Android.

## Rescue the phone while it still boots

Swollen battery = fire risk. Stop charging it now; if you need the app's saved config,
`adb shell pm path <pkg>` + `adb pull` gets the APK, and `adb shell` + screenshots gets
you the serial. Otherwise the credentials are already in your notes/installer record.

## Fallbacks, in order of effort

1. **RTSP after all** — run `./probe.sh` inside site B's LAN. If a path plays *and* you
   can log into site B's router, forward :554 and use `go2rtc` natively. Better video,
   no Android layer. Needs router access, which you may not have.
2. **Android-x86 in QEMU/KVM** (`qemu-full` + `edk2-ovmf`, virtio-gpu) — heavier, but
   avoids Waydroid's GPU quirks. Boot an Android-x86 ISO, install RXCamView, GLES
   passthrough via `virtio-gpu`.
3. **HDMI capture** — $12 USB capture dongle on the mini PC, fed by any Android device
   (the iPad, a $30 TV box) showing RXCamView. Cameras become a video input window.
   Keeps everything on one screen, no protocol fighting.
