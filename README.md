# Poplight

Local, app-free control of [Poplight](https://thepoplight.com) rechargeable Bluetooth wall
sconces. The Bluetooth protocol was reverse-engineered from the official app and is documented
in [PROTOCOL.md](PROTOCOL.md); everything else in this repo builds on that.

| Folder | What | Status |
|---|---|---|
| [`macos/`](macos/) | Native macOS app: Dock window + menu bar, per-light and group controls, GATT Lab | Working |
| [`homebridge/`](homebridge/) | Homebridge plugin for Apple HomeKit | Planned |
| [`tools/`](tools/) | `pklg2att.py`, PacketLogger capture → ATT timeline | Working |
| [`PROTOCOL.md`](PROTOCOL.md) | Language-neutral protocol spec | Decoded, hardware-verified |

## Protocol in one paragraph

Each light advertises as `POP_Light` and exposes service `FFB0` with `FFB1` (write) and
`FFB2` (notify). Commands are 3–4 raw bytes with no checksum or handshake: power `01 01 x`,
brightness `01 02 n` (1–99), warmth `01 06 v` (0 cool, 1 neutral, 2 warm), sleep timer
`02 03 00 idx` (15-minute steps), battery query `01 09 00` answered on `FFB2` as `01 09 raw`.
The light accepts one connection at a time and never pushes state changes.

## macOS app

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd macos
./scripts/run.sh          # build + launch (add --lab to open the Lab window)
./scripts/test.sh         # PoplightKit unit tests
xcodegen generate && open Poplight.xcodeproj
```

- **Window**: an *All Lights* card, your named groups, then one card per light with power,
  brightness, warm/neutral/cool, sleep timer and battery. Groups fan commands out
  per light, so individual control keeps working.
- **Menu bar**: the same controls in compact form; toggle it in Settings.
- **Lab** (toolbar): scan, connect, browse the full GATT database, write raw hex, and see every
  byte in a log that is also saved under `~/Library/Application Support/Poplight/logs/`.
- Lights and groups persist in `~/Library/Application Support/Poplight/`. Known lights
  reconnect automatically.

Layout under `macos/`:

```
project.yml                   XcodeGen spec (macOS 26, Swift 6, MainActor default isolation)
Poplight/                     app target: App, Views/{Control,MenuBar,Lab}, Models, Resources
Packages/PoplightKit/         Swift package, no UI
  Protocol/                   pure byte codec, no CoreBluetooth – the part to port elsewhere
  Transport/                  CoreBluetooth central, connection, light controller, log
  Lab/                        hex helpers, well-known GATT names
scripts/{build,run,test}.sh
```

Quit the official Poplight app (phone or Mac) before connecting; the light only takes one
central.

## Capturing traffic

If you ever need a live capture (for example to decode a new firmware), Apple's PacketLogger
does not capture the Mac's own Bluetooth on recent macOS. Use an iPhone with Apple's Bluetooth
logging profile and PacketLogger's *New iOS Trace*, then:

```sh
python3 tools/pklg2att.py capture.pklg
```

## How the protocol was recovered

The official app is Flutter. Its Dart code ships unencrypted in `App.framework`, so it was
decompiled with [Blutter](https://github.com/worawit/blutter) (with local patches for iOS
Mach-O input on Dart 3.11) and the byte lists were read straight out of the pseudo-code.
Details and source references are in [PROTOCOL.md](PROTOCOL.md).
