#!/bin/bash
set -euo pipefail

# Ensure Homebrew and local tools are available
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

AUTO_FIX=false
SKIP_TESTS=false

for arg in "$@"; do
    case "$arg" in
        --fix|-f)
            AUTO_FIX=true
            ;;
        --skip-tests|-s)
            SKIP_TESTS=true
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --fix, -f         Auto-format code and apply safe SwiftLint fixes"
            echo "  --skip-tests, -s  Skip running xcodebuild tests"
            echo "  --help, -h        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

echo "============================================="
echo "  BondScanner Local CI Pipeline"
echo "============================================="

# 1. Check prerequisites
if ! command -v swiftformat >/dev/null 2>&1; then
    echo "❌ swiftformat is not installed. Run 'brew install swiftformat'." >&2
    exit 1
fi

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "❌ swiftlint is not installed. Run 'brew install swiftlint'." >&2
    exit 1
fi

# 2. Formatting & Linting
if [ "$AUTO_FIX" = true ]; then
    echo "--> [1/4] Applying safe SwiftLint fixes..."
    swiftlint --fix || true
    echo "--> [2/4] Formatting code with SwiftFormat..."
    swiftformat .
    echo "--> Checking SwiftLint and SwiftFormat..."
    swiftlint lint
    swiftformat . --lint
else
    echo "--> [1/4] Checking code formatting (SwiftFormat)..."
    if ! swiftformat . --lint; then
        echo "" >&2
        echo "❌ SwiftFormat lint check failed." >&2
        echo "💡 Run './scripts/local-ci.sh --fix' or 'swiftformat .' to format automatically." >&2
        exit 1
    fi

    echo "--> [2/4] Linting code (SwiftLint)..."
    if ! swiftlint lint; then
        echo "❌ SwiftLint checks failed." >&2
        exit 1
    fi
fi

# 3. Build Staging App
echo "--> [3/4] Building staging application..."
"$ROOT/build.sh" --staging

# 4. Tests
if [ "$SKIP_TESTS" = false ]; then
    echo "--> [4/4] Running test suite..."
    RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bondscanner-xcresult.XXXXXX")"
    RESULT_BUNDLE="$RESULT_DIR/tests.xcresult"
    cleanup_results() { rm -rf "$RESULT_DIR"; }
    trap cleanup_results EXIT
    xcodebuild test \
        -project "$ROOT/BondScanner.xcodeproj" \
        -scheme BondScanner \
        -destination "platform=macOS" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -quiet
    SUMMARY="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE")"
    if ! command -v jq >/dev/null 2>&1; then
        echo "❌ jq is required to verify structured XCTest results." >&2
        exit 1
    fi
    TOTAL="$(printf '%s' "$SUMMARY" | jq -r '.totalTestCount // 0')"
    FAILED="$(printf '%s' "$SUMMARY" | jq -r '.failedTests // 0')"
    PASSED="$(printf '%s' "$SUMMARY" | jq -r '.passedTests // 0')"
    if [ "$TOTAL" -le 0 ] || [ "$PASSED" -le 0 ] || [ "$FAILED" -ne 0 ]; then
        echo "❌ XCTest result invalid: total=$TOTAL passed=$PASSED failed=$FAILED" >&2
        exit 1
    fi
    TESTS="$(xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE")"
    for suite in ReviewWorkflowTests BondValidationTests BondScannerTests; do
        SUITE="$(printf '%s' "$TESTS" | jq -c --arg suite "$suite" '.. | objects | select(.name? == $suite and .nodeType? == "Test Suite")' | head -n 1)"
        if [ -z "$SUITE" ]; then
            echo "❌ Expected XCTest suite missing: $suite" >&2
            exit 1
        fi
        SUITE_PASSED="$(printf '%s' "$SUITE" | jq '[.. | objects | select(.nodeType? == "Test Case" and .result? == "Passed")] | length')"
        SUITE_FAILED="$(printf '%s' "$SUITE" | jq '[.. | objects | select(.nodeType? == "Test Case" and (.result? == "Failed" or .result? == "Expected Failure"))] | length')"
        if [ "$SUITE_PASSED" -le 0 ] || [ "$SUITE_FAILED" -ne 0 ]; then
            echo "❌ XCTest suite invalid: $suite passed=$SUITE_PASSED failed=$SUITE_FAILED" >&2
            exit 1
        fi
    done
    echo "✅ Unit tests passed."
else
    echo "--> [4/4] Skipping tests (--skip-tests specified)."
fi

echo "============================================="
echo "🎉 All local CI checks passed successfully!"
echo "============================================="
