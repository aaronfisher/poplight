# Poplight

Local, app-free control of [Poplight](https://thepoplight.com) Bluetooth wall sconces from a
Mac menu bar app, with a **Lab** window for reverse-engineering and fine-tuning the BLE
protocol. The protocol itself is documented in [PROTOCOL.md](PROTOCOL.md) so it can later be
ported to Homebridge, Home Assistant, or anything else.

Status: **Phase 1 – Lab app**. The protocol is not decoded yet; the menu bar shows
connection state only. See "Roadmap" below.

## Layout

```
project.yml                  XcodeGen spec (macOS 26, Swift 6, MainActor default isolation)
Packages/PoplightKit/        Swift package, no UI
  Protocol/                  pure byte codec – no CoreBluetooth import, portable
  Transport/                 CoreBluetooth central, connection, GATT model, log
  Lab/                       hex helpers, well-known GATT names/decoders
Poplight/                    macOS app: MenuBarExtra + Lab window
tools/pklg2att.py            PacketLogger .pklg → ATT timeline (stdlib only)
scripts/{build,run,test}.sh  build with Xcode 27 beta, run, unit tests
```

## Build & run

Requires Xcode 27 (beta is fine) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`xcode-select` may point at the Command Line Tools; the scripts set `DEVELOPER_DIR` to
`/Applications/Xcode-beta.app` for you.

```sh
./scripts/run.sh --lab     # build + launch, Lab window open
./scripts/test.sh          # PoplightKit unit tests
xcodegen generate && open Poplight.xcodeproj   # to work in Xcode
```

First launch asks for Bluetooth permission. The app is signed to run locally and is not
sandboxed. It lives only in the menu bar (`LSUIElement`); the Lab opens at launch until the
protocol is known, or with `--lab`.

## The Lab

- **Scan** lists every advertising peripheral, Poplight-looking names first. Selecting one
  shows the decoded advertisement (manufacturer/company id, service UUIDs, service data).
- **Connect** discovers every service, characteristic and descriptor, reads everything
  readable, and subscribes to everything that notifies. Each characteristic row has
  Read / Notify / Write… controls; Write takes loose hex (`01 a2 ff`, `0x01,0xa2`).
- **Log** shows every byte both ways with relative timestamps; Copy JSON / Copy text for
  pasting into notes or a chat.

Only one central can usually be connected to a light at a time: quit the official Poplight
app (phone or Mac) before connecting from the Lab, and vice versa.

## Capturing the official app (Phase 2)

1. Install the Poplight app from the Mac App Store (it is an iOS app that runs on Apple
   Silicon Macs).
2. Download *Additional Tools for Xcode* from developer.apple.com and open **PacketLogger**.
   File → New macOS Trace (or the equivalent in your version) starts capturing the Mac's own
   Bluetooth traffic.
3. Quit our app, open the official app, and with one light nearby perform a scripted
   sequence with ~5 s pauses: on, off, on, brightness 25 / 50 / 100, warm / neutral / cool,
   10-min timer, cancel timer, refresh battery, then pair the second light and try grouping.
   Note the wall-clock time of each step.
4. Save the capture (`.pklg`) and run:

   ```sh
   python3 tools/pklg2att.py capture.pklg            # reads/writes/notifications with UUIDs
   python3 tools/pklg2att.py capture.pklg --handles  # GATT handle map
   python3 tools/pklg2att.py capture.pklg --json     # for scripting
   ```

`.pklg` files are git-ignored; keep decoded findings in `PROTOCOL.md`.

## Roadmap

1. **Lab app** – done.
2. **Capture & decode** the official app's traffic → `PROTOCOL.md`, `PoplightProtocol` codec + tests.
3. **Controls** in the menu bar: per-light power, brightness, warm/neutral/cool, battery,
   sleep timer; "all lights" fan-out; remembered lights with auto-reconnect; launch at login;
   App Intents for Shortcuts/Siri.
4. **Ports**: Homebridge plugin (TypeScript, `@stoprocent/noble`) or Home Assistant (Python, `bleak`).
