#!/bin/bash
# Sourced. CI and releases take the same Xcode, not the runner image's default.
DEVELOPER_DIR="$(find /Applications -maxdepth 1 -name 'Xcode_26*.app' | sort -V | tail -n1)/Contents/Developer"
test -d "$DEVELOPER_DIR" || { echo "✗ No Xcode 26 in /Applications" >&2; exit 1; }
export DEVELOPER_DIR
