#!/usr/bin/env bash
# Offline check of the bundled structure viewer. Compiles scripts/viewer-check.swift
# together with the app's MolStarView.swift (so it drives the app's own controller,
# page and bridge), then runs it. Options are documented in viewer-check.swift.
#
#   scripts/viewer-check.sh backend/dimitri/data/1l2y.pdb --expect-helix --out /tmp/1l2y.png
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${TMPDIR:-/tmp}/dimitri-viewer-check"
binary="$build/viewer-check"
sources=("$root/scripts/viewer-check.swift" "$root/app/Sources/DimitriStudio/MolStarView.swift")

mkdir -p "$build"
if [[ ! -x "$binary" || "${sources[0]}" -nt "$binary" || "${sources[1]}" -nt "$binary" ]]; then
  swiftc -O -parse-as-library -o "$binary" "${sources[@]}"
fi
exec "$binary" "$@"
