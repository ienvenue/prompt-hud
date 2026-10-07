#!/bin/bash
# Runs the Prompt HUD data-rule tests in a temporary folder. Never touches real data.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=PromptHUD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# PHModels' shortcut names need the KeyboardShortcuts package, which the tests do not use.
sed '/^import KeyboardShortcuts/d; /^extension KeyboardShortcuts.Name {/,/^}/d' "$SRC/PHModels.swift" > "$TMP/PHModels.swift"
swiftc -swift-version 5 "$TMP/PHModels.swift" "$SRC/PHStore.swift" PromptHUDTests/main.swift -o "$TMP/tests"
"$TMP/tests" -phLocalRoot "$TMP/local" -phSyncRoot "$TMP/cloud"
