# Poplight – notes for Claude

- Monorepo: `macos/` (Xcode app + PoplightKit), `homebridge/` (HomeKit plugin, planned),
  `tools/`, and `PROTOCOL.md` at the root as the shared spec.
- macOS: build with `macos/scripts/build.sh`, run with `macos/scripts/run.sh` (`--lab` opens the
  Lab window), tests with `macos/scripts/test.sh`. Regenerate the Xcode project with
  `xcodegen generate` inside `macos/` after adding files; `*.xcodeproj` is git-ignored.
- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` everywhere. CoreBluetooth delegates use
  isolated conformances (`extension X: @MainActor CBPeripheralDelegate`) and the central is created
  on the main queue. Pure data types are marked `nonisolated`.
- `macos/Packages/PoplightKit/Sources/PoplightKit/Protocol` must stay free of CoreBluetooth so it
  can be ported to TypeScript/Python. `PROTOCOL.md` is the human-readable spec; update both together.
- `tools/pklg2att.py` decodes PacketLogger captures; `.pklg` files are git-ignored.
- Commits: author is Aaron only. Do not add `Co-Authored-By` or any Claude attribution lines.
