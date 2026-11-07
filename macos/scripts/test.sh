#!/bin/zsh
# Run PoplightKit unit tests.
set -euo pipefail
cd "$(dirname "$0")/../Packages/PoplightKit"
if [ -z "${DEVELOPER_DIR:-}" ] && [ ! -d "$(xcode-select -p)/usr/bin" -o "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer; fi
swift test "$@"
