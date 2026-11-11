# homebridge-poplight

[Homebridge](https://homebridge.io) plugin that puts [Poplight](https://thepoplight.com)
Bluetooth wall sconces in Apple Home. Talks to the lights directly over BLE using the
reverse-engineered protocol in [../PROTOCOL.md](../PROTOCOL.md); no cloud, no official app.

Each light becomes a **Lightbulb** (on/off, brightness 1–99, colour temperature snapped to the
light's warm / neutral / cool steps) with a **Battery** service (level, low-battery flag).

## Requirements

- Homebridge 1.8+ or 2.x, Node 20+.
- A Bluetooth adapter within ~10 m of the lights: a Mac, or a Raspberry Pi / Linux box
  (BlueZ) via [`@stoprocent/noble`](https://github.com/stoprocent/noble).
- Each light accepts **one** connection. Quit the official Poplight app and the Poplight Mac
  app on any device in range while Homebridge runs.

On macOS, the process running Homebridge (Terminal, or the Node binary) must be allowed to use
Bluetooth in System Settings → Privacy & Security → Bluetooth. On Linux, give Node the raw
Bluetooth capability (`sudo setcap cap_net_raw+eip $(eval readlink -f $(which node))`) or run
as root.

## Install

```sh
npm install -g homebridge-poplight
```

or from this repo:

```sh
cd homebridge && npm install && npm run build && npm link
```

## Config

```json
{
  "platform": "Poplight",
  "autoDiscover": true,
  "connection": "onDemand",
  "idleDisconnectSeconds": 30,
  "batteryPollMinutes": 60,
  "lowBatteryThreshold": 25,
  "batterySensor": true,
  "lowBatterySensor": true,
  "lights": [
    { "id": "8cc00fe3…", "name": "Bedroom left" }
  ]
}
```

- `autoDiscover` (default `true`): add every `POP_Light` that comes into range. The id of each
  light is logged when it is found; use it in `lights` to give it a name, or set
  `autoDiscover` to `false` to add only the listed lights.
- `connection` (default `onDemand`): how the plugin holds on to the lights.
  - `onDemand` connects when a command is sent and disconnects after `idleDisconnectSeconds`
    without one. The first command after idle takes one to three seconds while the light is
    connected; HomeKit shows the new state straight away and the tile is put back if the light
    cannot be reached. This is what keeps the lights' standby battery life.
  - `persistent` holds a connection to every light. Response is instant, but the light asks
    for a 15 ms connection interval with no latency, so its radio wakes about 67 times a
    second around the clock. In testing two lights went from 100% to 50% in a day that way.
- `idleDisconnectSeconds` (default 30, on demand only): how long the connection is kept after
  the last command, so follow-up adjustments are instant.
- `batteryPollMinutes` (default 60 on demand, 5 persistent): how often to ask each light for
  its battery level. On demand each poll is a connection of a few seconds; the level is also
  read whenever a light is connected for a command.
- `bindings` (default `default`): Bluetooth driver. Leave it unless you run in Docker on
  Linux, where `hci` (raw socket, no BlueZ) is the reliable choice; `dbus` uses BlueZ. The HCI
  adapter index can be set with the `NOBLE_HCI_DEVICE_ID` environment variable.
- `lowBatteryThreshold` (default 25): at or below this the light's battery is flagged low. The
  light reports in steps of 25.
- `batterySensor` (default off): adds a "<light> Battery" tile, a humidity-style sensor whose
  value is the battery percentage, so you can see it without opening the light.
- `lowBatterySensor` (default off): adds a "<light> Battery Low" contact sensor that opens at
  the threshold. Turn on notifications for it in Home to get a push alert, or use it in
  automations. Turning either option off removes the tiles on the next restart.

**Raspberry Pi in one step**, on a fresh Raspberry Pi OS Lite with SSH:

```sh
curl -fsSL https://raw.githubusercontent.com/aaronfisher/poplight/main/homebridge/scripts/pi-install.sh | sudo bash
```

It installs Homebridge, builds and installs this plugin, grants Node raw Bluetooth access,
stops `bluetoothd` so the HCI binding owns the adapter (and installs a small unit that unblocks
and powers the adapter on whenever it appears), and adds the Poplight platform to `config.json`.
Re-run it to update. Then open `http://<pi>:8581` and pair the bridge in Home.

**Use a Bluetooth 5 dongle (tested 2026-11-07).** The onboard Bluetooth 4.x radios of a Pi
Zero 2 W and a Pi 3 Model B never received a single advertisement from a Poplight, even from one
foot away, while hearing dozens of other devices. A TP-Link UB500 (Realtek RTL8761BU) on the
same Pi 3 B hears both lights from 15 feet at -75 to -86 dBm and runs them reliably. The
Realtek firmware ships with Raspberry Pi OS, so the dongle works as soon as it is plugged in.
Then:

1. Add `dtoverlay=disable-bt` to `/boot/firmware/config.txt` so the dongle becomes `hci0`, and
   reboot. (If `lsusb` shows no devices at all, check for a leftover `dtoverlay=dwc2` line or
   `modules-load=dwc2,g_ether` in `cmdline.txt` from a USB-gadget setup: on a Pi 3 those put the
   single USB controller in peripheral mode and switch every port off.)
2. The installer's `bt-adapter-up@hci0` unit handles the rest (`rfkill unblock` and
   `hciconfig hci0 up`); a freshly plugged dongle otherwise stays soft-blocked and noble reports
   "Timeout waiting for Noble to be powered on".

Pi 4/5 onboard radios are Bluetooth 5 and should be fine, though untested.

**If a light goes quiet:** after an abrupt link loss (the Pi rebooted or the adapter was reset
mid-connection) a Poplight has been seen to stop advertising until its power button is pressed
once or it is power-cycled. Symptoms are a tile that reports "No Response" and no "Found
POPLIGHT" line in the Homebridge log.

Running on a Synology NAS with a USB dongle is possible in theory but blocked in practice on
most models (no Bluetooth kernel modules); see [docs/synology.md](docs/synology.md).

## Notes

- The light never reports on/off, brightness or warmth, so HomeKit shows the last value the
  plugin sent. Pressing the physical button is invisible to Home.
- The light's sleep timer has no HomeKit equivalent and is not exposed; use a Home automation
  instead.
- Lights reconnect automatically with backoff after going out of range or being switched off.

## Development

```sh
npm install
npm test                     # tsc + protocol unit tests
npm run homebridge           # run Homebridge from ./.homebridge with this plugin loaded
```
