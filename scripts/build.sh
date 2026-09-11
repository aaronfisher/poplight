#!/bin/zsh
# Build the Poplight app with the Xcode 27 beta toolchain (xcode-select still points at CLT).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
xcodegen generate --quiet
xcodebuild -project Poplight.xcodeproj -scheme Poplight -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning: .*\.swift|BUILD" || true
echo "app: build/DerivedData/Build/Products/Debug/Poplight.app"
