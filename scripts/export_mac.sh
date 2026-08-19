#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Pinbo.xcodeproj}"
SCHEME="${SCHEME:-PinboMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
PRODUCT_NAME="${PRODUCT_NAME:-Pinbo}"
TEAM_ID="${TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
APPLE_ID="${APPLE_ID:-}"
APPLE_PASSWORD="${APPLE_PASSWORD:-}"
NOTARIZE="${NOTARIZE:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
DMG_ARCH_LABEL="${DMG_ARCH_LABEL:-universal}"
EXPORT_DIR="${EXPORT_DIR:-$ROOT_DIR/build/mac-export}"

ARCHIVE_PATH="${ARCHIVE_PATH:-$EXPORT_DIR/archive/$PRODUCT_NAME.xcarchive}"
APP_EXPORT_DIR="$EXPORT_DIR/app"
DMG_ROOT_DIR="$EXPORT_DIR/dmg-root"

usage() {
    cat <<'USAGE'
Usage:
  DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=pinbo-notary VERSION=1.0.0 BUILD_NUMBER=1 bash scripts/export_mac.sh

Required:
  DEVELOPMENT_TEAM or TEAM_ID    Apple Developer Team ID used for Developer ID signing.

Notarization credentials, choose one:
  NOTARY_PROFILE or NOTARY_KEYCHAIN_PROFILE
                                Keychain profile created by xcrun notarytool store-credentials.
  APPLE_ID + APPLE_PASSWORD     Apple ID and app-specific password. TEAM_ID is also used.

Optional environment variables:
  VERSION                       Override MARKETING_VERSION, for example 1.0.0.
  BUILD_NUMBER                  Override CURRENT_PROJECT_VERSION, for example 1.
  ARCHS                         Default: arm64 x86_64. Builds a universal macOS app.
  SIGNING_IDENTITY              Default: Developer ID Application
  NOTARIZE                      Default: 1. Set to 0 to only build/sign/package without notarizing.
  EXPORT_DIR                    Default: build/mac-export
  SCHEME                        Default: PinboMac
  CONFIGURATION                 Default: Release
  PRODUCT_NAME                  Default: Pinbo
  PROJECT_PATH                  Default: Pinbo.xcodeproj
  ARCHIVE_PATH                  Default: $EXPORT_DIR/archive/$PRODUCT_NAME.xcarchive

Examples:
  xcrun notarytool store-credentials pinbo-notary --apple-id name@example.com --team-id ABCDE12345 --password app-specific-password
  DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=pinbo-notary VERSION=1.0.0 BUILD_NUMBER=1 bash scripts/export_mac.sh
  DEVELOPMENT_TEAM=ABCDE12345 NOTARIZE=0 bash scripts/export_mac.sh
USAGE
}

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$1"
}

fail() {
    printf '\033[1;31merror:\033[0m %s\n' "$1" >&2
    exit 1
}

print_notary_profile_help() {
    cat <<USAGE >&2

Create the notarytool keychain profile before exporting:

  xcrun notarytool store-credentials ${NOTARY_KEYCHAIN_PROFILE:-pinbo-notary} \\
    --apple-id your-apple-id@example.com \\
    --team-id $TEAM_ID \\
    --password app-specific-password

Then export again:

  DEVELOPMENT_TEAM='$TEAM_ID' \\
  NOTARY_PROFILE=${NOTARY_KEYCHAIN_PROFILE:-pinbo-notary} \\
  VERSION=$MARKETING_VERSION \\
  BUILD_NUMBER=$CURRENT_PROJECT_VERSION \\
  bash scripts/export_mac.sh

USAGE
}

validate_notary_credentials() {
    [[ "$NOTARIZE" != "0" ]] || return 0
    [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]] || return 0

    log "Validate Apple notarization profile"
    local notary_check_output
    if ! notary_check_output="$(xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" 2>&1 >/dev/null)"; then
        printf '%s\n' "$notary_check_output" >&2
        if [[ "$notary_check_output" == *"No Keychain password item found"* ]]; then
            print_notary_profile_help
        fi
        fail "Apple notarization profile '$NOTARY_KEYCHAIN_PROFILE' is not usable."
    fi
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

[[ -n "$TEAM_ID" ]] || { usage; fail "TEAM_ID is required for Developer ID signing."; }

if [[ "$NOTARIZE" != "0" ]]; then
    if [[ -z "$NOTARY_KEYCHAIN_PROFILE" && ( -z "$APPLE_ID" || -z "$APPLE_PASSWORD" ) ]]; then
        usage
        fail "Provide NOTARY_KEYCHAIN_PROFILE or APPLE_ID + APPLE_PASSWORD, or set NOTARIZE=0."
    fi
fi

command -v xcodebuild >/dev/null || fail "xcodebuild was not found. Install Xcode command line tools."
command -v hdiutil >/dev/null || fail "hdiutil was not found."
command -v xcrun >/dev/null || fail "xcrun was not found. Install Xcode command line tools."

mkdir -p "$EXPORT_DIR"

if command -v xcodegen >/dev/null; then
    log "Generate Xcode project"
    (cd "$ROOT_DIR" && xcodegen generate)
fi

log "Resolve version"
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"
MARKETING_VERSION="$(awk -F'= ' '/MARKETING_VERSION/ { print $2; exit }' <<< "$BUILD_SETTINGS" | tr -d '[:space:]')"
CURRENT_PROJECT_VERSION="$(awk -F'= ' '/CURRENT_PROJECT_VERSION/ { print $2; exit }' <<< "$BUILD_SETTINGS" | tr -d '[:space:]')"
MARKETING_VERSION="${VERSION:-${MARKETING_VERSION:-0.0.0}}"
CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-${CURRENT_PROJECT_VERSION:-0}}"
DMG_PATH="${DMG_PATH:-$EXPORT_DIR/$PRODUCT_NAME-$MARKETING_VERSION-$CURRENT_PROJECT_VERSION-$DMG_ARCH_LABEL.dmg}"

validate_notary_credentials

log "Clean export directory"
rm -rf "$ARCHIVE_PATH" "$APP_EXPORT_DIR" "$DMG_ROOT_DIR" "$DMG_PATH"
mkdir -p "$APP_EXPORT_DIR" "$DMG_ROOT_DIR" "$(dirname "$ARCHIVE_PATH")"

log "Archive macOS app"
xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    SKIP_INSTALL=NO

log "Copy archived app"
ARCHIVED_APP_PATH="$(find "$ARCHIVE_PATH/Products" -name '*.app' -type d | head -n 1)"
[[ -n "$ARCHIVED_APP_PATH" ]] || fail "No .app was found in $ARCHIVE_PATH/Products."
APP_PATH="$APP_EXPORT_DIR/$(basename "$ARCHIVED_APP_PATH")"
/usr/bin/ditto "$ARCHIVED_APP_PATH" "$APP_PATH"

log "Verify app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH" 2>&1 | sed -n '1,24p'

log "Verify app architectures"
APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
ACTUAL_ARCHS="$(lipo -archs "$APP_EXECUTABLE")"
printf 'Expected archs: %s\n' "$ARCHS"
printf 'Actual archs:   %s\n' "$ACTUAL_ARCHS"
for arch in $ARCHS; do
    [[ " $ACTUAL_ARCHS " == *" $arch "* ]] || fail "Exported app is missing required architecture: $arch"
done

log "Create signed DMG"
cp -R "$APP_PATH" "$DMG_ROOT_DIR/"
ln -s /Applications "$DMG_ROOT_DIR/Applications"
hdiutil create \
    -volname "$PRODUCT_NAME" \
    -srcfolder "$DMG_ROOT_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$NOTARIZE" != "0" ]]; then
    log "Submit DMG for Apple notarization"
    NOTARY_ARGS=(xcrun notarytool submit "$DMG_PATH" --wait)
    if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
        NOTARY_ARGS+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    else
        NOTARY_ARGS+=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID")
    fi
    "${NOTARY_ARGS[@]}"

    log "Staple notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    log "Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

log "Export finished"
printf 'App: %s\n' "$APP_PATH"
printf 'DMG: %s\n' "$DMG_PATH"
