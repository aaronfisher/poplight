# Poplight – notes for Claude

- Build with `./scripts/build.sh` (uses the selected Xcode; falls back to Xcode-beta if xcode-select points at CLT).
  Run with `./scripts/run.sh --lab`. Tests: `./scripts/test.sh`.
- Regenerate the Xcode project with `xcodegen generate` after adding files; `*.xcodeproj` is git-ignored.
- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` everywhere. CoreBluetooth delegates use
  isolated conformances (`extension X: @MainActor CBPeripheralDelegate`) and the central is created
  on the main queue. Pure data types are marked `nonisolated`.
- `Packages/PoplightKit/Sources/PoplightKit/Protocol` must stay free of CoreBluetooth so it can be
  ported to TypeScript/Python. `PROTOCOL.md` is the human-readable spec; update both together.
- `tools/pklg2att.py` decodes PacketLogger captures; `.pklg` files are git-ignored.
