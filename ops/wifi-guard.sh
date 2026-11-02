#!/usr/bin/env bash
# wifi-guard.sh — run every 5 min by wifi-guard.timer, as root.
#
# The Intel Centrino Wireless-N 2230 in these boxes (driver iwldvm) hangs now and then:
# the firmware wedges, the kernel *removes* the wlan0 link, and NetworkManager can never
# bring it back — the box stays offline until somebody walks in and reboots it. Reloading
# the driver is the only thing that recovers it, so that is all this script does.
#
# Steps: one missed ping is normal (roaming, DHCP renew) and is ignored. Two in a row:
# poke NetworkManager. Still dead ten minutes later: reload the driver, and if the card
# dropped off the PCI bus entirely, kick it so the reload can find it again.
set -uo pipefail

IFACE="${IFACE:-wlan0}"
STATE="${STATE:-/var/lib/restaurant-wifi-guard/fails}"
mkdir -p "$(dirname "$STATE")"

[ -e "/sys/class/net/$IFACE" ] && here=1 || here=0

# healthy = a gateway we can actually ping, not merely "associated"
gw=$(ip route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
if [ -n "$gw" ] && ping -c1 -W2 "$gw" >/dev/null 2>&1; then
    rm -f "$STATE"
    exit 0
fi

fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$STATE"
echo "wifi down: attempt $fails, iface present=$here, gw=${gw:-none}"

[ "$fails" -lt 2 ] && exit 0

# fast path: NetworkManager is usually fine, it just needs a poke
if [ "$here" = 1 ]; then
    conn=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')
    [ -n "$conn" ] || conn=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')
    if [ -n "$conn" ] && timeout 60 nmcli connection up "$conn" >/dev/null 2>&1; then
        sleep 3
        ping -c1 -W2 "$gw" >/dev/null 2>&1 && { rm -f "$STATE"; echo "recovered: nmcli up $conn"; exit 0; }
    fi
fi

# slow path: reload the driver — this is what a reboot does
modprobe -r iwldvm iwlwifi 2>/dev/null || modprobe -r iwlwifi 2>/dev/null
sleep 2
modprobe iwlwifi 2>/dev/null

# card vanished from the bus: remove + rescan so the fresh module probe sees it
if [ "$here" = 0 ]; then
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x8086" ] || continue
        [ "$(cat "$d/class" 2>/dev/null)" = "0x028000" ] && echo 1 > "$d/remove" 2>/dev/null
    done
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
fi

sleep 8
if ip -o link show "$IFACE" >/dev/null 2>&1; then
    echo "reloaded iwlwifi, $IFACE is back"
    rm -f "$STATE"
else
    echo "$IFACE still missing after driver reload"
fi
exit 0
