#!/bin/zsh
# Build the Poplight app. Uses the selected Xcode; falls back to Xcode-beta when xcode-select points at CLT.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ ! -d "$(xcode-select -p)/usr/bin" -o "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer; fi
xcodegen generate --quiet
xcodebuild -project Poplight.xcodeproj -scheme Poplight -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning: .*\.swift|BUILD" || true
echo "app: build/DerivedData/Build/Products/Debug/Poplight.app"
