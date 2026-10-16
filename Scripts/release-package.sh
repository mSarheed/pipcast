#!/bin/bash
set -euo pipefail
source Scripts/release-config.sh
for NAME in SIGNING_P12_BASE64 SIGNING_P12_PASSWORD NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_PRIVATE_KEY; do
    test -n "${!NAME:-}" || { echo "Missing configuration: $NAME" >&2; exit 1; }
done
case "${ARCHITECTURE:-}" in
    arm64) ARCHS=arm64; PREFIX=Pipcast ;;
    universal) ARCHS="arm64 x86_64"; PREFIX=Pipcast-Universal ;;
    *) exit 1 ;;
esac
umask 077
PRIVATE_DIR="$(mktemp -d "$RUNNER_TEMP/pipcast-signing.XXXXXX")"
KEYCHAIN="$PRIVATE_DIR/signing.keychain-db"
cleanup() {
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$PRIVATE_DIR"
}
trap cleanup EXIT
KPW="$(openssl rand -base64 32)"
printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$PRIVATE_DIR/identity.p12"
printf '%s' "$NOTARY_PRIVATE_KEY" > "$PRIVATE_DIR/AuthKey.p8"
security create-keychain -p "$KPW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KPW" "$KEYCHAIN"
security import "$PRIVATE_DIR/identity.p12" -k "$KEYCHAIN" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -v team="($APPLE_TEAM_ID)" '/Developer ID Application:/ && index($0, team) {print $2; exit}')"
test -n "$IDENTITY" || { echo 'No matching Developer ID Application identity' >&2; exit 1; }
rm "$PRIVATE_DIR/identity.p12"
mkdir -p "$PRIVATE_DIR/arm64"
tar -xpf build/release-artifacts/arm64.tar -C "$PRIVATE_DIR/arm64"
APP="$PRIVATE_DIR/arm64/$DISPLAY_NAME.app"
if [ "$ARCHITECTURE" = universal ]; then
    mkdir -p "$PRIVATE_DIR/x86_64"
    tar -xpf build/release-artifacts/x86_64.tar -C "$PRIVATE_DIR/x86_64"
    ./Scripts/release-merge.sh "$APP" "$PRIVATE_DIR/x86_64/$DISPLAY_NAME.app"
fi
for HELPER in ClipboardTextHelper FileIndexHelper 'Pipcast Dictation.app'; do
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$APP/Contents/Helpers/$HELPER"
done
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
    --entitlements Pipcast/Pipcast.entitlements "$APP"
for BIN in "$APP/Contents/MacOS/$DISPLAY_NAME" "$APP/Contents/Helpers/ClipboardTextHelper" "$APP/Contents/Helpers/FileIndexHelper" "$APP/Contents/Helpers/Pipcast Dictation.app/Contents/MacOS/Pipcast Dictation"; do
    for ARCH in $ARCHS; do lipo "$BIN" -verify_arch "$ARCH"; done
done
./Scripts/verify-signature.sh "$APP"
REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
codesign --verify --deep --strict -R "=$REQUIREMENT" "$APP"
notarize() {
    xcrun notarytool submit "$1" --key "$PRIVATE_DIR/AuthKey.p8" --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m --output-format json > "$PRIVATE_DIR/result.json"
    if ! jq -e '.status == "Accepted"' "$PRIVATE_DIR/result.json" >/dev/null; then
        cat "$PRIVATE_DIR/result.json"
        xcrun notarytool log "$(jq -r .id "$PRIVATE_DIR/result.json")" \
            --key "$PRIVATE_DIR/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
        exit 1
    fi
}
ditto -c -k --keepParent --sequesterRsrc "$APP" "$PRIVATE_DIR/submission.zip"
notarize "$PRIVATE_DIR/submission.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
mkdir -p dist "$PRIVATE_DIR/stage"
ditto "$APP" "$PRIVATE_DIR/stage/$DISPLAY_NAME.app"
ln -s /Applications "$PRIVATE_DIR/stage/Applications"
DMG="dist/$PREFIX-$VERSION.dmg"
hdiutil create -srcfolder "$PRIVATE_DIR/stage" -volname "$DISPLAY_NAME" -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
ditto -c -k --keepParent --sequesterRsrc "$APP" "dist/$PREFIX-$VERSION.zip"
