# homebridge-poplight (planned)

Homebridge plugin exposing Poplight sconces to Apple HomeKit as dimmable lights with
battery service. Not started yet.

Plan:
- TypeScript, `@stoprocent/noble` for BLE (macOS and Linux/Raspberry Pi).
- Port `PoplightProtocol` from `../macos/Packages/PoplightKit/Sources/PoplightKit/Protocol/`
  using `../PROTOCOL.md` as the spec: three/four-byte writes to `FFB1`, battery reply on `FFB2`.
- One accessory per light (On, Brightness 1–99, ColorTemperature as warm/neutral/cool steps,
  BatteryLevel); optional group accessories.
- Keep client-side state like the Mac app does: the light never pushes state.
