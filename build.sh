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
#
# Compiler output is written to a unique temp file, then copied to
# compile-log.txt. This script never tees into a log it also cats, and
# it does not write build.log (do not redirect this script into build.log).
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
SWIFT_SRCS=()
while IFS= read -r f; do
    SWIFT_SRCS+=("$f")
done < <(find "$ROOT/Sources" -name "*.swift")
PLIST="$ROOT/Info.plist"
SUMMARY="$ROOT/compile-log.txt"
TMPLOG="$(mktemp -t bondscanner-compile)"
cleanup() { rm -f "$TMPLOG"; }
trap cleanup EXIT

MODE="staging"
for arg in "$@"; do
    case "$arg" in
        --staging) MODE="staging" ;;
        --install) MODE="install" ;;
        -h|--help)
            sed -n '2,18p' "$0"
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

if [[ ${#SWIFT_SRCS[@]} -eq 0 ]]; then
    echo "Missing Swift sources in $ROOT/Sources" >&2
    exit 1
fi
if [[ ! -f "$PLIST" ]]; then
    echo "Missing Info.plist: $PLIST" >&2
    exit 1
fi

mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp "$PLIST" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/BondScanner.icns" "$CONTENTS/Resources/BondScanner.icns"

echo "Building Bond Scanner ($MODE) from ${#SWIFT_SRCS[@]} Swift source(s)"
echo "Output: $APP"

OBJC_SRC="$ROOT/Sources/ExceptionCatcher.m"
OBJC_HDR="$ROOT/Sources/ExceptionCatcher.h"
OBJC_OBJ="$ROOT/build/ExceptionCatcher.o"
if [[ ! -f "$OBJC_SRC" || ! -f "$OBJC_HDR" ]]; then
    echo "Missing ExceptionCatcher sources in $ROOT/Sources" >&2
    exit 1
fi
mkdir -p "$ROOT/build"
set +e
xcrun clang -c "$OBJC_SRC" -o "$OBJC_OBJ" -fobjc-arc -fmodules \
    -mmacosx-version-min=13.0 >"$TMPLOG" 2>&1
CLANG_STATUS=$?
if [[ $CLANG_STATUS -ne 0 ]]; then
    set -e
    cp "$TMPLOG" "$SUMMARY"
    echo "ObjC compile error. First 100 lines of $SUMMARY:" >&2
    sed -n '1,100p' "$SUMMARY" >&2
    exit 1
fi
xcrun swiftc -swift-version 5 -o "$EXEC" \
    -import-objc-header "$OBJC_HDR" \
    -framework AppKit -framework AVFoundation -framework Vision \
    -framework CoreImage -framework CoreMedia -framework CoreVideo \
    -framework QuartzCore -framework ImageIO \
    -framework AudioToolbox -framework UniformTypeIdentifiers \
    -framework Foundation \
    "${SWIFT_SRCS[@]}" "$OBJC_OBJ" >"$TMPLOG" 2>&1
SWIFTC_STATUS=$?
set -e

# Copy a finite snapshot after the compiler has finished. Never cat a file
# that is also being written by this process or a tee into the same path.
cp "$TMPLOG" "$SUMMARY"
if [[ "$SWIFTC_STATUS" -ne 0 ]]; then
    echo "Build error. First 100 lines of $SUMMARY:" >&2
    sed -n '1,100p' "$SUMMARY" >&2
    exit 1
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
chmod +x "$EXEC"
echo "Build complete: $APP"
if [[ -s "$SUMMARY" ]]; then
    echo "Compiler messages ($SUMMARY):"
    sed -n '1,80p' "$SUMMARY"
else
    echo "Compiler finished with no messages."
fi
