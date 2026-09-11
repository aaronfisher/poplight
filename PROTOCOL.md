# Poplight BLE protocol

Status: **not yet decoded**. This file is the single source of truth once the Phase 2
capture is analysed; keep it language-neutral so it can be ported.

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
| `FFB0` | `FFB1` "Characteristic 3" | write (props TBC) | command channel (assumed) |
| `FFB0` | `FFB2` "Characteristic 4" | notify | status / responses (assumed) |
| `02F00000-…-FE00` | `FF00`, `FF02`, `FF03` | | firmware OTA, leave alone |
| 180F | 2A19 | | **not present** – battery must come via FFB2 |

## Connection / handshake

Does the light require any write before it accepts commands (auth, "sync", key)?
_unknown_

## Commands (central → light)

| Action | Bytes | Notes |
|---|---|---|
| Power on | | |
| Power off | | |
| Brightness `n` (0–100) | | |
| Color temperature warm / neutral / cool | | |
| Sleep timer set `m` minutes | | |
| Sleep timer cancel | | |
| Query status / battery | | |

## Status (light → central)

| Message | Bytes | Fields |
|---|---|---|
| | | |

## Quirks

- Grouping in the official app: app-side fan-out or written to the lights? _unknown_
- Reconnect behaviour, advertising while connected, sleep/timeout: _unknown_
