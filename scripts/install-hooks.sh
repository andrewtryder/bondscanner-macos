#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_TYPE="${1:-pre-push}"

if [ "$HOOK_TYPE" != "pre-commit" ] && [ "$HOOK_TYPE" != "pre-push" ]; then
    echo "Usage: $0 [pre-commit|pre-push]" >&2
    exit 1
fi

HOOK_FILE="$ROOT/.git/hooks/$HOOK_TYPE"

if [ "$HOOK_TYPE" = "pre-push" ]; then
    cat << 'EOF' > "$HOOK_FILE"
#!/bin/bash
set -euo pipefail
echo "🔍 Running pre-push Local CI..."
./scripts/local-ci.sh
EOF
else
    cat << 'EOF' > "$HOOK_FILE"
#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "🔍 Running pre-commit format and lint check..."

STAGED_SWIFT_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$' || true)

if [ -n "$STAGED_SWIFT_FILES" ]; then
    swiftformat $STAGED_SWIFT_FILES --lint || {
        echo "" >&2
        echo "❌ SwiftFormat violation in staged files!" >&2
        echo "💡 Run 'swiftformat .' or './scripts/local-ci.sh --fix' to format." >&2
        exit 1
    }
    swiftlint lint --quiet || {
        echo "" >&2
        echo "❌ SwiftLint violation! Please resolve errors before committing." >&2
        exit 1
    }
fi
EOF
fi

chmod +x "$HOOK_FILE"
echo "✅ Successfully installed $HOOK_TYPE hook into .git/hooks/$HOOK_TYPE"
