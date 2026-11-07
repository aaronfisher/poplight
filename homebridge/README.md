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
  "batteryPollMinutes": 5,
  "lights": [
    { "id": "8cc00fe3-…", "name": "Bedroom left" }
  ]
}
```

- `autoDiscover` (default `true`): add every `POP_Light` that comes into range. The id of each
  light is logged when it is found; use it in `lights` to give it a name, or set
  `autoDiscover` to `false` to add only the listed lights.
- `batteryPollMinutes` (default 5): how often to ask each light for its battery level.

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
