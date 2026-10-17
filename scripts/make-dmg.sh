#!/usr/bin/env bash
# Package "Dimitri Studio.app" as a drag-to-Applications disk image.
#
# Usage: scripts/make-dmg.sh [--identity NAME] [--notarize-profile NAME] [APP]
#
# Release order: scripts/build-app.sh → scripts/notarize.sh (staples the app)
# → scripts/make-dmg.sh --notarize-profile dimitri-notary (signs, notarizes and
# staples the image). Without a profile the image is signed but not notarized.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Dimitri Studio.app"
IDENTITY="${DIMITRI_SIGN_IDENTITY:-Developer ID Application: Vasanth Sreeram (UTSTY3J6NS)}"
PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize-profile) PROFILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP="${1%/}"; shift ;;
  esac
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ -d "$APP" ] || die "no app at $APP; run scripts/build-app.sh first"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
DMG="$(dirname "$APP")/Dimitri-Studio-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Dimitri Studio.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Dimitri Studio" -srcfolder "$STAGE" -ov -fs HFS+ -format UDZO "$DMG" \
  || die "hdiutil could not create the disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG" || die "the disk image signature does not verify"

if [ -n "$PROFILE" ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "no notarytool keychain profile named $PROFILE (see scripts/notarize.sh)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
else
  echo "Signed, not notarized (no --notarize-profile). Gatekeeper will warn on other Macs."
fi
echo "Disk image: $DMG ($(du -h "$DMG" | cut -f1))"
