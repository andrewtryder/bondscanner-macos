#!/bin/bash
# Build Bond Scanner from the maintainable project source.
# Does not run or modify ~/Downloads/bondscan_v2.command.
# Does not overwrite ~/Library/Application Support/BondScanner/BondScanner.swift.
# Does not touch ~/BondScans data (photos, CSV, JSON, logs, README).
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
# Working v2 install location (the app is NOT under ~/BondScans)
APP="$HOME/Applications/BondScanner.app"
CONTENTS="$APP/Contents"
EXEC="$CONTENTS/MacOS/BondScanner"
LOG="$ROOT/build.log"

if [[ ! -f "$SRC" ]]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi
if [[ ! -f "$PLIST" ]]; then
    echo "Missing Info.plist: $PLIST" >&2
    exit 1
fi

mkdir -p "$CONTENTS/MacOS" "$HOME/Applications"

# Install Info.plist from the project (do not write a fresh README into ~/BondScans)
cp -p "$PLIST" "$CONTENTS/Info.plist"

echo "Building Bond Scanner from $SRC ..."
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
