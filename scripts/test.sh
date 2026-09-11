#!/bin/zsh
# Run PoplightKit unit tests.
set -euo pipefail
cd "$(dirname "$0")/../Packages/PoplightKit"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
swift test "$@"
