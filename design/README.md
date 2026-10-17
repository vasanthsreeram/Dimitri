# Dimitri Studio logo

One protein chain folded into a "D", coloured the way AlphaFold colours a
prediction by pLDDT. Confidence is very high at the N-terminus, stays confident
through the fold, and falls to low and very low in the C-terminal tail, which
thins out the way disordered termini do in a cartoon render. The open gap
between the two ends keeps it a chain rather than a closed letter.

## Files

| File | What it is |
|---|---|
| `dimitri-icon.svg` | macOS app icon, 1024 × 1024. Source for every raster icon size. |
| `dimitri-mark.svg` | The bare mark, no background. Works on light and dark backgrounds. |
| `dimitri-wordmark.svg` | Mark plus "Dimitri Studio", text as outlines. For light backgrounds by default. |
| `../app/Sources/DimitriStudio/LogoMark.swift` | `LogoMark(size:)`, the mark drawn in SwiftUI from the same geometry. |

`dimitri-mark.svg` and `dimitri-wordmark.svg` switch to their dark-background
colours when the root `<svg>` has `class="dark"`.

## Palette

| Role | Hex |
|---|---|
| pLDDT very high (> 90) | `#0053D6` |
| pLDDT confident (70–90) | `#65CBF3` |
| pLDDT low (50–70) | `#FFDB13` |
| pLDDT very low (< 50) | `#FF7D45` |
| Icon body, top to bottom | `#1E2738` → `#0A0E16` |
| Mark on light backgrounds: fold end, tail | `#2F8FE3`; `#F2B600` → `#F26A2E` |
| Wordmark text, light / dark | `#0F1726` / `#F2F5F9` |

The icon and the dark variants use the four pLDDT colours exactly. Light
yellow and light blue all but disappear on white, so the default mark and
wordmark deepen them slightly.

## Geometry

- Icon: 824 × 824 body at (100, 100) on the 1024 canvas, continuous corners of
  radius 185.4. The path is SwiftUI's
  `RoundedRectangle(cornerRadius: 185.4, style: .continuous)`, which matches
  the outline of Apple's own icons. The drop shadow (9 px down, 16 px blur, 22 %
  black) was fitted to Apple's icons.
- Mark: drawn in a 456 × 536 box with a 96-wide chain. The stem is at x = 48,
  the corner radius is 80, and the bowl has radius 220 about (188, 268). Blue
  turns to yellow at 40° on the bowl, and the tail tapers on its inner edge to a
  60-wide round tip. In the icon the box sits at (290, 244), 6 px right of
  centre for optical balance.
- The fold colour is a radial gradient centred on the N-terminus (r = 300),
  with a smoothstep ease sampled at seven stops. Its iso-lines cross the stem
  squarely, and everything past the stem is confident blue.
- Wordmark: Inter Display SemiBold ("Dimitri") and Regular ("Studio"), 100
  units, −1 % tracking, outlined with CoreText. The mark is 1.76 × the cap
  height and the gap to the text is 0.46 em. Inter is © The Inter Project
  Authors, SIL Open Font License 1.1.

`LogoMark.swift` uses the same coordinates, arcs, Bézier and gradient stops as
`dimitri-mark.svg`. If you change one, change the other.

## Regenerating the rasters

```bash
./scripts/make-icons.sh
```

This writes:

- `app/Bundle/AppIcon.icns` (all ten macOS sizes, 16–512 pt at 1× and 2×)
- `app/Bundle/Assets.xcassets/AppIcon.appiconset/` (the same PNGs plus `Contents.json`)
- `docs/logo.png` and `docs/logo-dark.png` (the wordmark at 1200 px wide, for
  light and dark backgrounds)

It then checks every pixel size with `sips`, round-trips the `.icns` through
`iconutil`, and compiles the asset catalog with `actool`. The `actool` check
needs Xcode; with only the Command Line Tools it is skipped. Nothing else needs
installing. `scripts/svg2png.swift` renders the SVGs through WebKit offscreen
and is compiled on the fly. Each image is drawn at up to 2048 px and
box-filtered down, because WebKit renders SVG filters at low resolution on
small targets.

To render one SVG yourself:

```bash
swift scripts/svg2png.swift design/dimitri-mark.svg 256=mark.png
swift scripts/svg2png.swift --class dark design/dimitri-mark.svg 256=mark-dark.png
```

The text in `dimitri-wordmark.svg` is already outlined, so the font is only
needed to change the wording.
