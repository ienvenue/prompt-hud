#!/bin/bash
# Lint, test, build and restart Prompt HUD. Stops at the first step that fails; the running app is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

echo "== 1/3 SwiftLint"
if command -v swiftlint >/dev/null; then
  # Errors stop the run; warnings are only counted (list them with: swiftlint lint --quiet).
  LINT=$(swiftlint lint --quiet 2>/dev/null || true)
  ERRORS=$(printf '%s\n' "$LINT" | grep ' error: ' || true)
  WARNINGS=$(printf '%s\n' "$LINT" | grep -c ' warning: ' || true)
  if [ -n "$ERRORS" ]; then
    printf '%s\n' "$ERRORS"
    echo "SwiftLint found errors. Stopped; the running app was not touched."
    exit 1
  fi
  echo "No errors, $WARNINGS warnings"
else
  echo "SwiftLint is not installed, skipping (brew install swiftlint)"
fi

echo "== 2/3 Tests"
scripts/test.sh | grep -v '^PASS' || { echo "Tests failed. Stopped; the running app was not touched."; exit 1; }

echo "== 3/3 Build"
xcodebuild -project PromptHUD.xcodeproj -scheme PromptHUD -configuration Debug -derivedDataPath DerivedData/PromptHUD build -quiet
pkill -x PromptHUD || true
sleep 1
open DerivedData/PromptHUD/Build/Products/Debug/PromptHUD.app
echo "== Done, Prompt HUD restarted"
