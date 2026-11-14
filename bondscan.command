#!/bin/bash
# Bond Scanner project launcher (staging).
# Builds to build/BondScanner.app and opens that copy.
# Does not overwrite ~/Applications/BondScanner.app.
# Does not extract or overwrite Application Support source.
# Does not run ~/Downloads/bondscan_v2.command.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This launcher must be run on macOS." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/BondScanner.app"

"$ROOT/build.sh" --staging
echo "Opening staging app: $APP"
echo "Scan data remains in $HOME/BondScans."
open "$APP"
