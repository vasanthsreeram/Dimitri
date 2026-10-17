#!/usr/bin/env bash
# Notarize "Dimitri Studio.app" with Apple, staple the ticket and check
# Gatekeeper.
#
# Usage: scripts/notarize.sh [--profile NAME] [APP]
#
#   --profile  notarytool keychain profile. Default: $DIMITRI_NOTARY_PROFILE,
#              else dimitri-notary.
#   APP        the signed app. Default: dist/Dimitri Studio.app, built by
#              scripts/build-app.sh.
#
# One-time setup, which stores an app-specific password in the login keychain:
#   xcrun notarytool store-credentials dimitri-notary --apple-id <apple id> \
#     --team-id UTSTY3J6NS --password <app-specific password from appleid.apple.com>
#
# Exit status: 0 notarized and stapled, 1 failed, 2 the keychain profile is
# missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="UTSTY3J6NS"
PROFILE="${DIMITRI_NOTARY_PROFILE:-dimitri-notary}"
APP="$ROOT/dist/Dimitri Studio.app"

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

APP_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || die "--profile needs a value"
      PROFILE="$2"
      shift 2
      ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [ "$APP_GIVEN" -eq 0 ] || die "only one app path is accepted"
      APP="${1%/}"
      APP_GIVEN=1
      shift
      ;;
  esac
done
[ -d "$APP" ] || die "no app at $APP; build it first with scripts/build-app.sh"

# --- credentials --------------------------------------------------------------
say "Checking the notarytool keychain profile \"$PROFILE\""
history_rc=0
history_out="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1)" || history_rc=$?
if [ "$history_rc" -ne 0 ]; then
  printf '%s\n' "$history_out" >&2
  if grep -qi 'No Keychain password item found' <<<"$history_out"; then
    cat <<EOF

The notarytool keychain profile "$PROFILE" does not exist on this Mac, so
nothing was submitted. To create it:

  1. Sign in at https://appleid.apple.com, open Sign-In and Security >
     App-Specific Passwords, and generate a password for notarization.
  2. Store it in the login keychain:

     xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id $TEAM_ID --password <app-specific password from appleid.apple.com>

  3. Run scripts/notarize.sh again.
EOF
    exit 2
  fi
  die "notarytool cannot use the profile \"$PROFILE\" (exit $history_rc; output above).
If the app-specific password was revoked or mistyped, store it again with:
  xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id $TEAM_ID --password <app-specific password from appleid.apple.com>"
fi
echo "The profile works."

# --- the signature must be notarizable before anything is uploaded ------------
say "Checking the signature of $APP"
codesign --verify --deep --strict --verbose=2 "$APP" \
  || die "the signature does not verify; rebuild with scripts/build-app.sh"
details="$(codesign -dvv "$APP" 2>&1)"
grep -q '^Authority=Developer ID Application: ' <<<"$details" \
  || die "the app is not signed with a Developer ID Application certificate"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" \
  || die "the hardened runtime is off; notarization requires it"
grep -q '^Timestamp=' <<<"$details" \
  || die "the signature has no secure timestamp; notarization requires one"
echo "Developer ID signature, hardened runtime and secure timestamp are present."

# --- submit -------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NAME="$(basename "$APP" .app)"
ZIP="$WORK/$NAME.zip"

say "Zipping for upload"
ditto -c -k --keepParent "$APP" "$ZIP"

say "Submitting to Apple's notary service and waiting for the result"
submit_rc=0
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 \
  | tee "$WORK/submit.log" || submit_rc=$?
SUBMISSION_ID="$(awk '$1 == "id:" { id = $2 } END { print id }' "$WORK/submit.log")"
STATUS="$(awk '$1 == "status:" { s = $2 } END { print s }' "$WORK/submit.log")"

if [ "$STATUS" != "Accepted" ]; then
  printf '\nNotarization did not succeed (status: %s, notarytool exit %s).\n' \
    "${STATUS:-unknown}" "$submit_rc" >&2
  if [ -n "$SUBMISSION_ID" ]; then
    LOG="$(dirname "$APP")/notarization-$SUBMISSION_ID.json"
    say "Notary log for $SUBMISSION_ID"
    if xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "$LOG"; then
      cat "$LOG"
      echo
      echo "Saved to $LOG"
    fi
  fi
  exit 1
fi

# --- staple and check -----------------------------------------------------------
say "Stapling the ticket"
xcrun stapler staple "$APP"

say "stapler validate"
xcrun stapler validate "$APP"

say "spctl -a -vv -t exec (Gatekeeper)"
spctl -a -vv -t exec "$APP" || die "Gatekeeper still rejects the app after stapling"

# The upload zip predates the staple, so zip the stapled app for distribution.
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
OUT_ZIP="$(dirname "$APP")/${NAME// /-}-$VERSION.zip"
rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP" "$OUT_ZIP"

say "Done"
echo "Notarized and stapled: $APP"
echo "Distributable zip:     $OUT_ZIP"
