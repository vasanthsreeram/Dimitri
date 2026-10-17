#!/usr/bin/env bash
# Build a signed "Dimitri Studio.app" from the SwiftPM executable.
#
# Usage: scripts/build-app.sh [--identity NAME_OR_SHA1] [--no-sign] [--dmg]
#
#   --identity  codesigning identity. Default: $DIMITRI_SIGN_IDENTITY, else
#               "Developer ID Application: Vasanth Sreeram (UTSTY3J6NS)".
#   --no-sign   assemble an unsigned development bundle. It runs on this Mac
#               (the linker's ad-hoc signature covers the executable) but cannot
#               be notarized or distributed.
#   --dmg       also build dist/Dimitri-Studio-<version>.dmg (drag-to-Applications
#               disk image, signed with the same identity).
#
# Produces dist/Dimitri Studio.app (dist/ is git-ignored) and the executable's
# dSYM next to it. Notarize and staple afterwards with scripts/notarize.sh.
#
# Bundle layout:
#   Contents/MacOS/DimitriStudio     release arm64 executable
#   Contents/Helpers/uv              Astral's uv (pinned release, SHA-256 checked), re-signed
#                                    with the Developer ID. The app uses it on first launch to
#                                    create its Python environment, so users need no Terminal.
#   Contents/Info.plist              app/Bundle/Info.plist with the version filled in
#   Contents/PkgInfo
#   Contents/Resources/AppIcon.icns  app/Bundle/AppIcon.icns, when present
#   Contents/Resources/Assets.car    app/Bundle/Assets.xcassets compiled by actool, when present
#   Contents/Resources/Viewer/...    contents of SwiftPM's resource bundle, when the target has
#                                    resources. Only the contents are copied: a .bundle at the
#                                    .app root is unsealed content and breaks codesign.
#   Contents/Resources/backend/      backend/dimitri (no tests or bytecode), pyproject.toml and
#                                    uv.lock. The app creates the Python environment outside the
#                                    bundle (UV_PROJECT_ENVIRONMENT under ~/Library/Application
#                                    Support/Dimitri Studio). Nothing in the bundle may be written
#                                    at runtime: any added or changed file invalidates the seal.
#
# Entitlements: app/Bundle/DimitriStudio.entitlements is intentionally an empty
# dictionary. The hardened runtime comes from `codesign --options runtime`, not
# from an entitlement, and each exception it offers was considered:
#   - App Sandbox: off. The app starts uv and python child processes for its
#     local backend and the model runtimes. They read and write ~/.dimitri, model
#     checkouts and caches, and a sandbox would be inherited by every child.
#     Outside the sandbox, the network.client/server entitlements do nothing.
#   - cs.allow-jit, cs.allow-unsigned-executable-memory,
#     cs.disable-executable-page-protection: not needed. WKWebView runs
#     JavaScript, including its JIT, in Apple's WebContent XPC process, which is
#     signed with its own entitlements. Loading local files into the web view
#     needs no entitlement either. This process never generates code.
#   - cs.disable-library-validation: not needed. The executable links only
#     /usr/lib and /System libraries (checked below) and loads no plug-ins.
#   - cs.allow-dyld-environment-variables: not needed. The hardened runtime
#     ignores DYLD_* only for this process. uv and python are separate
#     executables whose own signatures decide their runtime flags.
#   - Camera, microphone, location, contacts, calendars, photos, Apple Events:
#     none are used.
#   - get-task-allow: must stay absent, because notarization rejects it.
# Talking to http://127.0.0.1:8642 needs no entitlement outside the sandbox. The
# ATS side is NSAllowsLocalNetworking in Info.plist. Add an exception here only
# when something concretely fails under the hardened runtime, and record why.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Dimitri Studio"
PRODUCT="DimitriStudio"
DEFAULT_IDENTITY="Developer ID Application: Vasanth Sreeram (UTSTY3J6NS)"

APP_SRC="$ROOT/app"
BUNDLE_SRC="$APP_SRC/Bundle"
ENTITLEMENTS="$BUNDLE_SRC/DimitriStudio.entitlements"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
PLIST="$CONTENTS/Info.plist"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Mach-O files under Contents/ other than the main executable, deepest first.
# (A function because bash 3.2 misparses `case` inside a command substitution.)
nested_macho() {
  local f
  find "$CONTENTS" -type f ! -path "$CONTENTS/MacOS/$PRODUCT" -print | while IFS= read -r f; do
    case "$(file -b "$f")" in
      *Mach-O*) printf '%s\n' "$f" ;;
    esac
  done | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-
}

IDENTITY="${DIMITRI_SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
SIGN=1
MAKE_DMG=0
UV_VERSION="0.11.2"
UV_SHA256="4beaa9550f93ef7f0fc02f7c28c9c48cd61fe30db00f5ac8947e0a425c3fb282"
while [ $# -gt 0 ]; do
  case "$1" in
    --identity)
      [ $# -ge 2 ] || die "--identity needs a value"
      IDENTITY="$2"
      shift 2
      ;;
    --identity=*) IDENTITY="${1#*=}"; shift ;;
    --no-sign) SIGN=0; shift ;;
    --dmg) MAKE_DMG=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# --- preflight ---------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "this script builds a macOS app and must run on macOS"
for tool in swift xcrun codesign plutil git rsync ditto; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found; install Xcode"
done

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be MAJOR.MINOR.PATCH, found '$VERSION'"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)" \
  || die "cannot count commits for CFBundleVersion; build from a git checkout"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
  warn "uncommitted changes: build $BUILD_NUMBER does not pin down the exact source"
fi

EXPECTED_TEAM=""
if [ "$SIGN" -eq 1 ]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if ! grep -Fq -- "$IDENTITY" <<<"$identities"; then
    printf '%s\n' "$identities" >&2
    die "signing identity not in the keychain: $IDENTITY
Pass --identity (or set DIMITRI_SIGN_IDENTITY), or use --no-sign for a development build."
  fi
  if [[ "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
    EXPECTED_TEAM="${BASH_REMATCH[1]}"
  fi
fi

# --- build -------------------------------------------------------------------
say "Building $PRODUCT $VERSION ($BUILD_NUMBER), release, arm64"
swift build --package-path "$APP_SRC" -c release --arch arm64 --product "$PRODUCT"
# Ask SwiftPM where the products went: swiftbuild (the default since Swift 6.4)
# and the older native build system use different directories.
BIN_DIR="$(swift build --package-path "$APP_SRC" -c release --arch arm64 --product "$PRODUCT" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$PRODUCT"
[ -f "$EXECUTABLE" ] || die "no executable at $EXECUTABLE"

# --- assemble ----------------------------------------------------------------
say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES"
cp -X "$EXECUTABLE" "$CONTENTS/MacOS/$PRODUCT"
printf 'APPL????' > "$CONTENTS/PkgInfo"

cp -X "$BUNDLE_SRC/Info.plist" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"

# SwiftPM resources. swiftbuild emits a real bundle (<name>.bundle/Contents/
# Resources/...); the legacy native build system emits a flat one with
# Info.plist at its top. Either way, only the resources themselves are copied.
RES_BUNDLE="$BIN_DIR/${PRODUCT}_${PRODUCT}.bundle"
if [ -d "$RES_BUNDLE/Contents/Resources" ]; then
  ditto --norsrc --noextattr --noqtn "$RES_BUNDLE/Contents/Resources" "$RESOURCES"
  echo "SwiftPM resources: $(ls "$RES_BUNDLE/Contents/Resources" | tr '\n' ' ')"
elif [ -d "$RES_BUNDLE" ]; then
  ditto --norsrc --noextattr --noqtn "$RES_BUNDLE" "$RESOURCES"
  rm -f "$RESOURCES/Info.plist"
  echo "SwiftPM resources: $(ls "$RESOURCES" | tr '\n' ' ')"
else
  warn "no SwiftPM resource bundle at $RES_BUNDLE; the app is packaged without bundled viewer resources"
fi

# Icon: a ready-made .icns, an asset catalog, or both.
ICON_FOUND=0
if [ -d "$BUNDLE_SRC/Assets.xcassets" ]; then
  echo "Compiling app/Bundle/Assets.xcassets"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  PARTIAL="$WORK/assetcatalog_generated_info.plist"
  xcrun actool "$BUNDLE_SRC/Assets.xcassets" \
    --compile "$RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL" \
    --output-format human-readable-text --notices --warnings --errors
  [ -f "$RESOURCES/Assets.car" ] && [ -f "$PARTIAL" ] || die "actool did not produce Assets.car"
  # PlistBuddy's Merge skips keys that already exist, so set the icon keys
  # from actool's output first, then merge anything else it added.
  for key in CFBundleIconFile CFBundleIconName; do
    if value="$(plutil -extract "$key" raw -o - "$PARTIAL" 2>/dev/null)"; then
      plutil -replace "$key" -string "$value" "$PLIST"
    fi
  done
  /usr/libexec/PlistBuddy -c "Merge $PARTIAL" "$PLIST" >/dev/null
  ICON_FOUND=1
fi
if [ -f "$BUNDLE_SRC/AppIcon.icns" ]; then
  cp -X "$BUNDLE_SRC/AppIcon.icns" "$RESOURCES/AppIcon.icns"
  echo "Copied app/Bundle/AppIcon.icns"
  ICON_FOUND=1
fi
if [ "$ICON_FOUND" -eq 0 ]; then
  warn "no app/Bundle/AppIcon.icns or app/Bundle/Assets.xcassets; the app gets the generic icon"
fi

# Embedded backend source. The setup scripts are run directly, so they keep
# their exec bit.
BACKEND="$RESOURCES/backend"
mkdir -p "$BACKEND"
rsync -a \
  --exclude '__pycache__' --exclude '*.pyc' --exclude '*.pyo' \
  --exclude '.venv' --exclude 'tests' --exclude '.pytest_cache' \
  --exclude '.ruff_cache' --exclude '*.egg-info' --exclude '.DS_Store' \
  "$ROOT/backend/dimitri/" "$BACKEND/dimitri/"
cp -X "$ROOT/backend/pyproject.toml" "$ROOT/backend/uv.lock" "$BACKEND/"
for script in "$BACKEND"/dimitri/runners/setup/*.sh; do
  [ -e "$script" ] || continue
  chmod 755 "$script"
done
stray="$(find "$BACKEND" \( -name __pycache__ -o -name '*.pyc' -o -name .venv -o -name tests \) -print)"
[ -z "$stray" ] || die "backend copy contains files that must not ship:
$stray"
echo "Backend: $(find "$BACKEND" -type f | wc -l | tr -d ' ') files in ${BACKEND#$DIST/}"

# uv, so first launch can build the backend environment without a terminal.
# Pinned release, checked against Astral's published SHA-256, cached in dist/.
UV_CACHE="$DIST/.cache/uv-$UV_VERSION"
if [ ! -x "$UV_CACHE/uv" ]; then
  echo "Fetching uv $UV_VERSION (aarch64-apple-darwin)"
  mkdir -p "$UV_CACHE"
  curl -fsSL -o "$UV_CACHE/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" \
    || die "could not download uv $UV_VERSION"
  got="$(shasum -a 256 "$UV_CACHE/uv.tar.gz" | awk '{print $1}')"
  [ "$got" = "$UV_SHA256" ] || { rm -f "$UV_CACHE/uv.tar.gz"; die "uv download checksum mismatch ($got)"; }
  tar -xzf "$UV_CACHE/uv.tar.gz" -C "$UV_CACHE" --strip-components 1 uv-aarch64-apple-darwin/uv
  rm -f "$UV_CACHE/uv.tar.gz"
fi
mkdir -p "$CONTENTS/Helpers" "$RESOURCES/Licenses"
cp -X "$UV_CACHE/uv" "$CONTENTS/Helpers/uv"
chmod 755 "$CONTENTS/Helpers/uv"
cat > "$RESOURCES/Licenses/uv.txt" <<UVNOTICE
uv $UV_VERSION (https://github.com/astral-sh/uv), included unmodified in
Contents/Helpers/uv and re-signed for this app.
Copyright (c) Astral Software Inc. Licensed under either of the Apache License,
Version 2.0 or the MIT license, at your option:
https://github.com/astral-sh/uv/blob/$UV_VERSION/LICENSE-APACHE
https://github.com/astral-sh/uv/blob/$UV_VERSION/LICENSE-MIT
UVNOTICE
echo "Helpers: uv $UV_VERSION"

# Every file readable by every user, writable only by its owner.
chmod -R u+rwX,go+rX,go-w "$APP"

# --- sanity checks before signing ---------------------------------------------
plutil -lint "$PLIST" >/dev/null || die "Info.plist does not parse"
if grep -Eq '@[A-Z_]+@' "$PLIST"; then
  die "Info.plist still has a template placeholder: $(grep -Eo '@[A-Z_]+@' "$PLIST" | sort -u | tr '\n' ' ')"
fi
[ "$(plutil -extract CFBundleExecutable raw -o - "$PLIST")" = "$PRODUCT" ] \
  || die "CFBundleExecutable in Info.plist does not match $PRODUCT"
ARCHS="$(lipo -archs "$CONTENTS/MacOS/$PRODUCT")"
[[ " $ARCHS " == *" arm64 "* ]] || die "executable is not arm64 (archs: $ARCHS)"
# The library-validation reasoning above depends on this.
non_system="$(otool -L "$CONTENTS/MacOS/$PRODUCT" | tail -n +2 | awk '{print $1}' \
  | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
[ -z "$non_system" ] || die "the executable links non-system libraries, which would need embedding,
signing and a library-validation review:
$non_system"

# Keep the dSYM for symbolicating crash reports. It is not part of the app.
if [ -d "$BIN_DIR/$PRODUCT.dSYM" ]; then
  rm -rf "$DIST/$APP_NAME.app.dSYM"
  ditto "$BIN_DIR/$PRODUCT.dSYM" "$DIST/$APP_NAME.app.dSYM"
fi

# Finder info and resource forks make codesign fail with "detritus not allowed".
xattr -cr "$APP" 2>/dev/null || true

# --- sign --------------------------------------------------------------------
if [ "$SIGN" -eq 0 ]; then
  say "Not signing (--no-sign)"
  echo "Unsigned development build. It runs on this Mac but cannot be notarized or shared."
else
  say "Signing with: $IDENTITY"
  # Sign nested code inside out. Notarization requires every Mach-O file in
  # the bundle to carry a Developer ID signature, the hardened runtime and a
  # secure timestamp. The only one is Contents/Helpers/uv: the backend is
  # Python source and the viewer is JavaScript.
  nested="$(nested_macho)"
  if [ -n "$nested" ]; then
    while IFS= read -r f; do
      echo "Signing nested code: ${f#$APP/}"
      codesign --force --timestamp --options runtime --sign "$IDENTITY" "$f"
    done <<<"$nested"
  else
    echo "No nested Mach-O code besides Contents/MacOS/$PRODUCT."
  fi
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

  # --- verify --------------------------------------------------------------
  say "codesign --verify --deep --strict --verbose=2"
  codesign --verify --deep --strict --verbose=2 "$APP" || die "codesign verification failed"

  say "codesign -dvvv"
  details="$(codesign -dvvv "$APP" 2>&1)"
  printf '%s\n' "$details"
  team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
  if [ -z "$team" ] || [ "$team" = "not set" ]; then
    die "the signature has no TeamIdentifier; use a Developer ID Application identity"
  fi
  if [ -n "$EXPECTED_TEAM" ] && [ "$team" != "$EXPECTED_TEAM" ]; then
    die "TeamIdentifier is $team, expected $EXPECTED_TEAM"
  fi
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" \
    || die "the hardened runtime flag is missing"
  grep -q '^Timestamp=' <<<"$details" \
    || die "the signature has no secure timestamp, which notarization requires"

  say "Entitlements (codesign -d --entitlements -)"
  entitlements_xml="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  if [ -n "$entitlements_xml" ]; then
    printf '%s\n' "$entitlements_xml" | plutil -p -
  else
    echo "(no entitlements blob)"
  fi
  if grep -q 'get-task-allow' <<<"$entitlements_xml"; then
    die "com.apple.security.get-task-allow is set; notarization rejects it"
  fi

  say "spctl -a -vv -t exec (Gatekeeper)"
  spctl_rc=0
  spctl_out="$(spctl -a -vv -t exec "$APP" 2>&1)" || spctl_rc=$?
  printf '%s\n' "$spctl_out"
  if [ "$spctl_rc" -eq 0 ]; then
    echo "Gatekeeper accepts the app."
  elif grep -q 'Unnotarized Developer ID' <<<"$spctl_out"; then
    cat <<'EOF'
Expected at this stage. The Developer ID signature is valid, but Gatekeeper
only accepts Developer ID apps once Apple has notarized them. Run
scripts/notarize.sh to notarize and staple. spctl should then report
"accepted" with "source=Notarized Developer ID".
EOF
  else
    warn "unexpected Gatekeeper result (exit $spctl_rc); see the output above"
  fi
fi

# --- disk image ----------------------------------------------------------------
DMG=""
if [ "$MAKE_DMG" -eq 1 ]; then
  say "Building the disk image"
  if [ "$SIGN" -eq 1 ]; then
    "$ROOT/scripts/make-dmg.sh" --identity "$IDENTITY" "$APP"
    DMG="$DIST/Dimitri-Studio-$VERSION.dmg"
  else
    warn "--dmg needs a signed app; skipped"
  fi
fi

# --- result ------------------------------------------------------------------
say "Result"
echo "App:      $APP"
echo "Version:  $VERSION (build $BUILD_NUMBER), $ARCHS"
echo "Size:     $(du -sh "$APP" | cut -f1)"
if [ -n "$DMG" ]; then
  echo "DMG:      $DMG ($(du -h "$DMG" | cut -f1))"
fi
if [ -d "$DIST/$APP_NAME.app.dSYM" ]; then
  echo "dSYM:     $DIST/$APP_NAME.app.dSYM"
fi
if git -C "$ROOT" check-ignore -q "$DIST"; then
  echo "dist/ is git-ignored."
else
  warn "dist/ is not git-ignored"
fi
