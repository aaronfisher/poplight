#!/usr/bin/env bash
# One-shot setup of homebridge-poplight on a Raspberry Pi (Zero 2 W or newer) running
# Raspberry Pi OS Lite. Installs Homebridge (official apt repo) if missing, builds this plugin
# from the repo, installs it into Homebridge, grants Node raw Bluetooth access, frees the
# adapter from bluetoothd, and adds the Poplight platform to config.json.
#
#   curl -fsSL https://raw.githubusercontent.com/aaronfisher/poplight/main/homebridge/scripts/pi-install.sh | sudo bash
# or, from a clone:   sudo ./scripts/pi-install.sh
#
# To install a branch instead of main (for testing a fix), fetch the script from that branch
# and name it in BRANCH:
#   curl -fsSL https://raw.githubusercontent.com/aaronfisher/poplight/<branch>/homebridge/scripts/pi-install.sh | sudo BRANCH=<branch> bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/aaronfisher/poplight.git}
BRANCH=${BRANCH:-main}
SRC_DIR=${SRC_DIR:-/opt/poplight}
HB_DIR=/var/lib/homebridge
HB_NODE=/opt/homebridge/bin/node
HB_NPM=/opt/homebridge/bin/npm

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo" >&2
  exit 1
fi

arch=$(uname -m)
if [[ "$arch" == armv6l ]]; then
  echo "This is an ARMv6 Pi (original Zero/Zero W). Homebridge no longer supports it; use a Zero 2 W or newer." >&2
  exit 1
fi

echo "==> apt packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl build-essential python3 bluez >/dev/null

if [[ ! -x "$HB_NODE" ]]; then
  echo "==> installing Homebridge from repo.homebridge.io"
  curl -sSfL https://repo.homebridge.io/KEY.gpg | gpg --dearmor | tee /usr/share/keyrings/homebridge.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/homebridge.gpg] https://repo.homebridge.io stable main" >/etc/apt/sources.list.d/homebridge.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq homebridge >/dev/null
fi
echo "    Homebridge node: $($HB_NODE --version)"

echo "==> fetching plugin source ($BRANCH) into $SRC_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" fetch -q origin "$BRANCH"
  git -C "$SRC_DIR" checkout -q -B "$BRANCH" "origin/$BRANCH"
else
  git clone -q --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

echo "==> building plugin"
cd "$SRC_DIR/homebridge"
PATH="/opt/homebridge/bin:$PATH" "$HB_NPM" install --silent --no-audit --no-fund
PATH="/opt/homebridge/bin:$PATH" "$HB_NPM" run build --silent
tarball=$(PATH="/opt/homebridge/bin:$PATH" "$HB_NPM" pack --silent 2>/dev/null | tail -1)
[[ -f "$SRC_DIR/homebridge/$tarball" ]] || { echo "npm pack did not produce a tarball" >&2; exit 1; }

echo "==> installing $tarball into Homebridge"
cd "$HB_DIR"
sudo -u homebridge env PATH="/opt/homebridge/bin:$PATH" HOME="$HB_DIR" "$HB_NPM" install --silent --no-audit --no-fund --save "$SRC_DIR/homebridge/$tarball"
rm -f "$SRC_DIR/homebridge/$tarball"

echo "==> Bluetooth: raw HCI access for the Homebridge service, adapter released from bluetoothd"
# File capabilities on the node binary get wiped by hb-service's ownership reset on every start,
# so grant the capabilities to the service via systemd instead (ambient caps are inherited by node).
# With bluetoothd disabled nothing powers the adapter on, and a freshly plugged USB dongle starts
# soft-blocked by rfkill. This unit runs whenever hci0 appears (boot or hot-plug) and fixes both.
cat >/etc/systemd/system/bt-adapter-up@.service <<'UNIT'
[Unit]
Description=Unblock and power on Bluetooth adapter %i (bluetoothd is disabled)
BindsTo=sys-subsystem-bluetooth-devices-%i.device
After=sys-subsystem-bluetooth-devices-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/sbin/rfkill unblock bluetooth
ExecStart=/usr/bin/hciconfig %i up

[Install]
WantedBy=sys-subsystem-bluetooth-devices-%i.device
UNIT
mkdir -p /etc/systemd/system/homebridge.service.d
cat >/etc/systemd/system/homebridge.service.d/bluetooth.conf <<'UNIT'
[Service]
# Cycle every adapter down and up so state left by a previous process (a running scan, a pending
# connection) cannot wedge the HCI binding, and so noble finds an adapter that is UP.
ExecStartPre=-/usr/sbin/rfkill unblock bluetooth
ExecStartPre=-/bin/sh -c 'for h in /sys/class/bluetooth/hci*; do h=$(basename $h); hciconfig $h down; sleep 1; hciconfig $h up; done'
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_SETUID CAP_SETGID CAP_KILL
UNIT
systemctl daemon-reload
# udev: power on whichever adapter appears (the dongle re-enumerates as hci1 after a firmware
# crash), and restart Homebridge if one appears while it is running, since noble stays bound to
# the adapter it started with.
cat >/etc/udev/rules.d/90-poplight-bt-adapter.rules <<'RULE'
# Adapters only: connection devices (hci0:16) share the subsystem and the hci* name; DEVTYPE
# tells them apart. Without it every new connection restarts Homebridge, in a loop.
ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", KERNEL=="hci[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="bt-adapter-up@%k.service"
ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", KERNEL=="hci[0-9]*", RUN+="/bin/systemctl --no-block try-restart homebridge.service"
RULE
systemctl disable bt-adapter-up@hci0.service >/dev/null 2>&1 || true
udevadm control --reload-rules
systemctl disable --now bluetooth >/dev/null 2>&1 || true
systemctl disable hciuart >/dev/null 2>&1 || true
rfkill unblock bluetooth 2>/dev/null || true
for h in /sys/class/bluetooth/hci*; do hciconfig "$(basename "$h")" up 2>/dev/null || true; done

echo "==> config.json platform block"
"$HB_NODE" - "$HB_DIR/config.json" <<'JS'
const fs = require('fs');
const path = process.argv[2];
const config = JSON.parse(fs.readFileSync(path, 'utf8'));
config.platforms ??= [];
if (!config.platforms.some((p) => p.platform === 'Poplight')) {
  config.platforms.push({
    platform: 'Poplight',
    autoDiscover: true,
    batteryPollMinutes: 5,
    lowBatteryThreshold: 25,
    batterySensor: true,
    lowBatterySensor: true,
    bindings: 'hci',
  });
  fs.writeFileSync(path, JSON.stringify(config, null, 4) + '\n');
  console.log('    added Poplight platform');
} else {
  console.log('    Poplight platform already present');
}
JS
chown homebridge:homebridge "$HB_DIR/config.json"

echo "==> restarting Homebridge"
hb-service restart >/dev/null

ip=$(hostname -I | awk '{print $1}')
echo
echo "Done. Homebridge UI: http://$ip:8581  (first login creates the admin user)"
echo "Pair the bridge in the Home app with the QR code shown on the UI's dashboard."
echo "Logs: hb-service logs   |   update plugin later: sudo $SRC_DIR/homebridge/scripts/pi-install.sh"
