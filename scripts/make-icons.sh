#!/usr/bin/env bash
# Regenerate every raster logo asset from the SVG sources in design/.
#
#   design/dimitri-icon.svg      -> app/Bundle/AppIcon.icns
#                                   app/Bundle/Assets.xcassets/AppIcon.appiconset/
#   design/dimitri-wordmark.svg  -> docs/logo.png       (for light backgrounds)
#                                   docs/logo-dark.png  (for dark backgrounds)
#
# Needs only a Mac with Xcode or the Command Line Tools: SVGs are rendered by
# scripts/svg2png.swift through WebKit, the .icns is built by iconutil and the
# results are checked with sips, iconutil and (when Xcode is installed) actool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESIGN="$ROOT/design"
BUNDLE="$ROOT/app/Bundle"
CATALOG="$BUNDLE/Assets.xcassets"
APPICONSET="$CATALOG/AppIcon.appiconset"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dimitri-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for tool in swiftc iconutil sips; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "make-icons: $tool not found; install Xcode or the Command Line Tools" >&2
    exit 1
  fi
done

# macOS app icon slots: point size and scale.
SLOTS="16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2"

slot_name() { # 16 2 -> icon_16x16@2x.png
  if [ "$2" = 1 ]; then echo "icon_$1x$1.png"; else echo "icon_$1x$1@2x.png"; fi
}

echo "== compiling svg2png"
swiftc -O -o "$WORK/svg2png" "$ROOT/scripts/svg2png.swift"

echo "== rendering app icon"
mkdir -p "$WORK/px"
jobs=()
for px in 16 32 64 128 256 512 1024; do
  jobs+=("$px=$WORK/px/$px.png")
done
"$WORK/svg2png" "$DESIGN/dimitri-icon.svg" "${jobs[@]}"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$APPICONSET"
rm -f "$APPICONSET"/icon_*.png
for slot in $SLOTS; do
  pt="${slot%:*}"; scale="${slot#*:}"
  name="$(slot_name "$pt" "$scale")"
  cp "$WORK/px/$((pt * scale)).png" "$ICONSET/$name"
  cp "$WORK/px/$((pt * scale)).png" "$APPICONSET/$name"
done

echo "== building AppIcon.icns"
iconutil -c icns -o "$BUNDLE/AppIcon.icns" "$ICONSET"

echo "== writing asset catalog"
cat > "$CATALOG/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
{
  echo '{'
  echo '  "images" : ['
  first=1
  for slot in $SLOTS; do
    pt="${slot%:*}"; scale="${slot#*:}"
    [ "$first" = 1 ] || echo '    },'
    first=0
    echo '    {'
    echo "      \"filename\" : \"$(slot_name "$pt" "$scale")\","
    echo '      "idiom" : "mac",'
    echo "      \"scale\" : \"${scale}x\","
    echo "      \"size\" : \"${pt}x${pt}\""
  done
  echo '    }'
  echo '  ],'
  echo '  "info" : {'
  echo '    "author" : "xcode",'
  echo '    "version" : 1'
  echo '  }'
  echo '}'
} > "$APPICONSET/Contents.json"

echo "== rendering README wordmarks"
"$WORK/svg2png" "$DESIGN/dimitri-wordmark.svg" 1200="$ROOT/docs/logo.png"
"$WORK/svg2png" --class dark "$DESIGN/dimitri-wordmark.svg" 1200="$ROOT/docs/logo-dark.png"

echo "== verifying"
pixel_size() { # prints WxH
  sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'
}
status=0
check_dir() { # check every slot PNG in a directory
  for slot in $SLOTS; do
    pt="${slot%:*}"; scale="${slot#*:}"
    file="$1/$(slot_name "$pt" "$scale")"
    want="$((pt * scale))x$((pt * scale))"
    if [ ! -f "$file" ]; then
      echo "  missing $file" >&2; status=1
    elif [ "$(pixel_size "$file")" != "$want" ]; then
      echo "  $file is $(pixel_size "$file"), expected $want" >&2; status=1
    fi
  done
}
check_dir "$APPICONSET"
iconutil -c iconset -o "$WORK/roundtrip.iconset" "$BUNDLE/AppIcon.icns"
check_dir "$WORK/roundtrip.iconset"
if xcrun --find actool >/dev/null 2>&1; then
  mkdir -p "$WORK/actool"
  if ! xcrun actool --compile "$WORK/actool" --platform macosx --minimum-deployment-target 14.0 \
      --app-icon AppIcon --output-partial-info-plist "$WORK/actool/partial.plist" \
      "$CATALOG" >"$WORK/actool/log.txt" 2>&1; then
    cat "$WORK/actool/log.txt" >&2
    status=1
  fi
else
  echo "  actool not found (Command Line Tools only); skipped the asset catalog compile check"
fi
for f in "$ROOT/docs/logo.png" "$ROOT/docs/logo-dark.png"; do
  echo "  $(basename "$f"): $(pixel_size "$f")"
done
if [ "$status" != 0 ]; then
  echo "make-icons: verification failed" >&2
  exit 1
fi
echo "done: app/Bundle/AppIcon.icns, app/Bundle/Assets.xcassets, docs/logo.png, docs/logo-dark.png"
