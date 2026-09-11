# Poplight BLE protocol

Status: **not yet decoded**. This file is the single source of truth once the Phase 2
capture is analysed; keep it language-neutral so it can be ported.

## Device

| Field | Value |
|---|---|
| Product | Poplight rechargeable wall sconce (thepoplight.com) |
| Official app | iOS `id6484317705`, Android `com.poplight.pop_light`, v1.0.9 |
| Advertised name | _unknown_ (Lab: check scan list) |
| Manufacturer data / company id | _unknown_ |
| Advertised service UUIDs | _unknown_ |
| Chip / SDK hints (Device Information service) | _unknown_ |
| Max simultaneous centrals | _unknown_ (assume 1) |

## GATT

| Service | Characteristic | Properties | Role |
|---|---|---|---|
| _?_ | _?_ | write / write-no-rsp | command channel |
| _?_ | _?_ | notify | status / responses |
| 180F? | 2A19? | read, notify | battery level (if standard) |

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
