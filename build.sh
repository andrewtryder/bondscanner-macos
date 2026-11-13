#!/bin/bash
# Build Bond Scanner from the maintainable project source.
# Does not run or modify ~/Downloads/bondscan_v2.command.
# Does not overwrite ~/Library/Application Support/BondScanner/BondScanner.swift.
# Does not touch ~/BondScans data (photos, CSV, JSON, logs, README).
#
# Usage:
#   ./build.sh            Build to ./build/BondScanner.app (staging; default)
#   ./build.sh --staging  Same as default
#   ./build.sh --install  Install to ~/Applications/BondScanner.app
#                         (do not use while the installed app is being tested)
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This build must be run on macOS." >&2
    exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple Command Line Tools / Xcode are required (xcrun swiftc not found)." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources/BondScanner.swift"
PLIST="$ROOT/Info.plist"
LOG="$ROOT/build.log"

MODE="staging"
for arg in "$@"; do
    case "$arg" in
        --staging) MODE="staging" ;;
        --install) MODE="install" ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--staging|--install]" >&2
            exit 1
            ;;
    esac
done

if [[ "$MODE" == "staging" ]]; then
    APP="$ROOT/build/BondScanner.app"
else
    APP="$HOME/Applications/BondScanner.app"
    echo "WARNING: installing over $APP" >&2
fi

CONTENTS="$APP/Contents"
EXEC="$CONTENTS/MacOS/BondScanner"

if [[ ! -f "$SRC" ]]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi
if [[ ! -f "$PLIST" ]]; then
    echo "Missing Info.plist: $PLIST" >&2
    exit 1
fi

mkdir -p "$CONTENTS/MacOS"

# Install Info.plist from the project (do not write a fresh README into ~/BondScans)
cp "$PLIST" "$CONTENTS/Info.plist"

echo "Building Bond Scanner ($MODE) from $SRC"
echo "Output: $APP"
# Same compiler flags and frameworks as the v2 launcher
if ! xcrun swiftc -swift-version 5 -o "$EXEC" \
    -framework AppKit -framework AVFoundation -framework Vision \
    -framework CoreImage -framework CoreMedia -framework CoreVideo \
    -framework QuartzCore -framework ImageIO \
    -framework AudioToolbox -framework UniformTypeIdentifiers \
    "$SRC" >"$LOG" 2>&1; then
    echo "Build error. First 100 lines of $LOG:" >&2
    sed -n '1,100p' "$LOG" >&2
    exit 1
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
chmod +x "$EXEC"
echo "Build complete: $APP"
echo "Compiler output is in $LOG"
if [[ -s "$LOG" ]]; then
    echo "----- build.log -----"
    cat "$LOG"
fi
