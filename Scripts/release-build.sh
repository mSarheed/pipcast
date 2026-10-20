#!/bin/bash
set -euo pipefail
source Scripts/release-config.sh
case "${ARCHITECTURE:-}" in
    arm64|x86_64) ;;
    *) echo 'ARCHITECTURE must be arm64 or x86_64' >&2; exit 1 ;;
esac
brew install xcodegen
xcodegen generate
xcodebuild -quiet -project Pipcast.xcodeproj -scheme Pipcast -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$RUNNER_TEMP/DerivedData" ARCHS="$ARCHITECTURE" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="$APPLE_TEAM_ID" PRODUCT_NAME="$DISPLAY_NAME" \
    PIPCAST_BUNDLE_IDENTIFIER="$BUNDLE_ID" MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" build
mkdir -p build/release-artifacts
tar -cf "build/release-artifacts/$ARCHITECTURE.tar" \
    -C "$RUNNER_TEMP/DerivedData/Build/Products/Release" "$DISPLAY_NAME.app"
