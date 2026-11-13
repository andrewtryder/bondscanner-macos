#!/bin/bash
# Bond Scanner project launcher.
# Builds from ~/BondScannerProject and opens the app.
# Does not extract or overwrite source. Does not run bondscan_v2.command.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This launcher must be run on macOS." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/BondScanner.app"

"$ROOT/build.sh"
echo "Opening Bond Scanner. Output data remains in $HOME/BondScans (not modified by this launch script except via the running app)."
open "$APP"
