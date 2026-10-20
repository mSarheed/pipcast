#!/bin/bash
set -euo pipefail
for NAME in BASE_VERSION CHANNEL APPLE_TEAM_ID GITHUB_RUN_NUMBER RUNNER_TEMP; do
    test -n "${!NAME:-}" || { echo "Missing configuration: $NAME" >&2; exit 1; }
done
[[ "$BASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 1
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 1
VERSION="$BASE_VERSION"
DISPLAY_NAME="Pipcast"
BUNDLE_ID="io.github.msarheed.pipcast.app"
case "$CHANNEL" in
    beta) VERSION+="-beta.${GITHUB_RUN_NUMBER}"; DISPLAY_NAME+=" Beta"; BUNDLE_ID+=".beta" ;;
    stable) ;;
    *) exit 1 ;;
esac
source Scripts/select-xcode.sh
