# Poplight BLE protocol

Status: **decoded 2026-11-06** from the official Flutter app (v1.0.8) with the Blutter Dart AOT
decompiler; confirmed on hardware where marked. Keep this file language-neutral so it can be ported.

## Device

| Field | Value |
|---|---|
| Product | Poplight rechargeable wall sconce (thepoplight.com) |
| Official app | iOS `id6484317705`, Android `com.poplight.pop_light`, v1.0.9 |
| Advertised name | `POP_Light` (Lab, 2026-09-10) |
| Manufacturer data / company id | _unknown_ (check advertisement pane) |
| Advertised service UUIDs | _unknown_ |
| Chip / SDK hints | OTA service `02F00000-…-FE00` (chars FF00/FF02/FF03, FF02 reads `ntf_enable`, user description "OTA Response"); same family as Govee H5184 thermometer and Nothing CMF Watch. Vendor not yet identified. |
| ATT MTU | 23 (max write without response = 20 bytes) |
| Max simultaneous centrals | _unknown_ (assume 1) |

## Official app internals (from strings in the unencrypted Flutter `App.framework`, v1.0.8/1.0.9)

- Flutter 3.11.1 app, BLE via `flutter_blue_plus`; also Firebase, OneSignal, sqflite.
- Talks only to service `FFB0`, writes `FFB1`, subscribes `FFB2` (`ffb1`/`ffb2` literals present),
  plus the standard CCCD `2902`.
- Local DB row per light: `isOn`, `brightness`, `glow` (= colour warmth), `timer`, `colorid`.
- Debug strings: `15 cmd send`, `Write error ch in warmth`, `Error getting battery level:`,
  `indivBtrlvl`, `Error turning notifier off`, `with_msd`. Commands are built from number lists,
  so the byte formats are **not** recoverable from strings; a capture is required.
- Screens: adjust settings (brightness/warmth/timer), groups, rename/remove, battery status.

## GATT

| Service | Characteristic | Properties | Role |
|---|---|---|---|
| `FFB0` | `FFB1` "Characteristic 3" | write, write-no-rsp | command channel |
| `FFB0` | `FFB2` "Characteristic 4" | write, write-no-rsp, notify | replies (battery) |
| `02F00000-…-FE00` | `FF00`, `FF02`, `FF03` | | firmware OTA, leave alone |
| 180F | 2A19 | | **not present** – battery must come via FFB2 |

## Connection / handshake

None. Connect, discover, subscribe to `FFB2` notifications, write to `FFB1`. No auth, no key,
no checksum, no length byte. ATT MTU 23, so every command fits one packet.

## Commands (central → light)

| Action | Bytes (hex) | Notes |
|---|---|---|
| Power on | `01 01 01` | |
| Power off | `01 01 00` | |
| Brightness `n` | `01 02 n` | `n` = 1…99; the app clamps 100 → 99 and rejects 0 |
| Warmth cool / neutral / warm | `01 06 00` / `01 06 01` / `01 06 02` | mapping from the app's widget build order; confirm on hardware |
| Sleep timer `m` minutes | `02 03 00 idx` | `idx = m / 15`, 1…48 (15 min … 12 h); idx 0 is rejected ("Invalid Time") |
| Sleep timer cancel | _none known_ | the official app has no cancel; power-cycling clears it (to verify) |
| Query battery | `01 09 00` | the only command written *with* response; reply arrives on `FFB2` |
| Unknown | `01 10 00` | one of the app's two power handlers sends it right before `01 01 x`; the other does not. Purpose unknown; not needed |

All commands except the battery query are written **without response** (the app uses the
characteristic's `writeWithoutResponse` property). The app never reads any characteristic.
Groups are app-side: the same bytes are written to each selected light in turn.

## Status (light → central)

| Message | Bytes | Fields |
|---|---|---|
| Command echo | `01 01 x`, `01 02 n`, `01 06 v` | the light echoes every accepted command back on `FFB2` (seen on hardware 2026-11-06). Useful as an acknowledgement and to confirm state |
| Battery reply | `01 09 raw` | confirmed on hardware (`01 09 50` = raw 80 = 100%, `01 09 3c` = 75%). The official app only inspects byte 2; `raw` → percent: 80→100, 60→75, 40→50, 20→25, anything else passed through |

The light does **not** push state changes it makes on its own (pressing the physical button
produced no notification), so state after a button press must still be assumed client-side.

## Source of truth

Recovered with [Blutter](https://github.com/worawit/blutter) from the unencrypted
`App.framework` of the Mac-installed iOS app (Flutter 3.11.1 / Dart 3.11.1). Blutter needed
three local patches for iOS Mach-O input on Dart 3.11; the key pseudo-code lives in
`screens/adjust_settings/adjust.dart` (`Brightness.setBright`, `setTime`) and
`screens/adjust_settings/adjust_settings_home.dart` (warmth/power/timer closures,
`_BatteryState.getBatteryState`, `mapBatteryPercentage`).

## Quirks

- Grouping in the official app is app-side fan-out (each light gets its own write).
- The light stops advertising while a central is connected and resumes a few seconds after a
  clean disconnect. After an abrupt link loss (central reset or powered off mid-connection) it
  has been seen to stay silent until its power button is pressed or it is power-cycled.
- **Malformed CCCD lookup reply.** An ATT *Read By Type* request for UUID `2902` over the FFB2
  characteristic's handle range (the way noble's Linux HCI binding locates the Client
  Characteristic Configuration descriptor before subscribing) is answered with a *Read By Type
  Response* whose attribute-data length is 2: it names the descriptor handle (`0x001f`) but
  carries **no value bytes**. Spec-conforming parsers expect 4 bytes per entry and either throw
  or wait forever. Discover the descriptor with *Find Information* (`0x04`) instead and write
  `01 00` to it directly; CoreBluetooth and BlueZ already do this internally.
- Handle layout seen on hardware: FFB2 declaration `0x001d`, value `0x001e`, CCCD `0x001f`
  (last attribute of the FFB0 service).
- Right after connecting, the light asks for a connection parameter update (interval 15 ms,
  peripheral latency 0, supervision timeout 6 s) through an L2CAP signalling request; accept it.
- A held connection is expensive for the light. At 15 ms with no latency its radio wakes about
  67 times a second whether the lamp is on or off: two lights connected around the clock went
  from 100% to 50% in 24 hours (2026-11-09/10). A central that stays up for long periods
  should connect per command and disconnect when idle. After a clean disconnect the light
  resumes advertising at once and accepts a new connection in one to three seconds.
- Commands can be written back to back without waiting for each other: the light acts on
  each write and echoes it on FFB2 in order (a battery query followed immediately by two
  commands returns `01 09 xx` and then both echoes).
- Advertising uses legacy PDUs on LE 1M at a low duty cycle; weak Bluetooth 4.x receivers
  (Raspberry Pi Zero 2 W / Pi 3 B onboard radios) never heard the lights at all while a
  Bluetooth 5 dongle 15 ft away sees them at -75 to -86 dBm.
