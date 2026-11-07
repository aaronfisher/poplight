#!/bin/zsh
# Build, then (re)launch the app. Pass --lab to force the Lab window open.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
pkill -x Poplight 2>/dev/null || true
open build/DerivedData/Build/Products/Debug/Poplight.app --args "$@"
