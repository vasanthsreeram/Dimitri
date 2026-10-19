import SwiftUI

/// The Dimitri Studio mark: one chain folded into a "D", coloured like an
/// AlphaFold pLDDT plot. Very high confidence at the N-terminus eases into
/// confident through the fold, and the tapering C-terminal tail runs from low
/// to very low.
///
/// Drawn with `Canvas` from the same geometry as `design/dimitri-mark.svg`
/// (the D lives in a 456 x 536 box), so it is crisp at any size. Dark mode
/// uses the exact pLDDT colours, as the app icon does; light mode uses the
/// slightly deeper set that holds up on white.
struct LogoMark: View {
    var size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(size: CGFloat = 32) {
        self.size = size
    }

    var body: some View {
        Canvas { context, canvas in
            let palette = colorScheme == .dark ? LogoPalette.dark : LogoPalette.light

            // Same square framing as the SVG viewBox "-46 0 536 536".
            let scale = min(canvas.width, canvas.height) / 536
            context.translateBy(
                x: (canvas.width - 536 * scale) / 2 + 46 * scale,
                y: (canvas.height - 536 * scale) / 2
            )
            context.scaleBy(x: scale, y: scale)

            let fold = GraphicsContext.Shading.radialGradient(
                palette.fold, center: CGPoint(x: 48, y: 414), startRadius: 0, endRadius: 300
            )
            context.stroke(Self.foldPath, with: fold, style: StrokeStyle(lineWidth: 96, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 0, y: 366, width: 96, height: 96)), with: fold)
            context.fill(
                Self.tailPath,
                with: .linearGradient(
                    palette.tail, startPoint: CGPoint(x: 393.3, y: 0), endPoint: CGPoint(x: 94, y: 0)
                )
            )
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Dimitri Studio")
    }

    /// Fold: from the N-terminus up the stem, round the corner and the bowl,
    /// ending 1.5 degrees past the junction so the tail covers the seam.
    /// Each `addArc` draws the straight run to its own start point (the stem,
    /// then the top bar); an explicit line there would leave a near-zero
    /// segment whose join opens a hairline gap in the stroke.
    private static var foldPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 48, y: 414))
        path.addArc(
            center: CGPoint(x: 128, y: 128), radius: 80,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.addArc(
            center: CGPoint(x: 188, y: 268), radius: 220,
            startAngle: .degrees(-90), endAngle: .degrees(41.5), clockwise: false
        )
        return path
    }

    /// C-terminal tail: the outer edge stays on the D; the inner edge tapers
    /// from the full 96 width to a 60-wide round tip.
    private static var tailPath: Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: 188, y: 268), radius: 268,
            startAngle: .degrees(40), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: 124, y: 536))
        path.addArc(
            center: CGPoint(x: 124, y: 506), radius: 30,
            startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: 319.76, y: 378.56),
            control1: CGPoint(x: 224.59, y: 476),
            control2: CGPoint(x: 257.91, y: 452.26)
        )
        path.closeSubpath()
        return path
    }
}

private struct LogoPalette {
    let fold: Gradient
    let tail: Gradient

    /// The exact AlphaFold pLDDT colours, for dark backgrounds.
    static var dark: LogoPalette {
        LogoPalette(
            fold: Gradient(stops: [
                .init(color: Color(logoHex: 0x0053D6), location: 0.18),
                .init(color: Color(logoHex: 0x075CD8), location: 0.32),
                .init(color: Color(logoHex: 0x1A72DE), location: 0.45),
                .init(color: Color(logoHex: 0x338FE5), location: 0.59),
                .init(color: Color(logoHex: 0x4BACEB), location: 0.73),
                .init(color: Color(logoHex: 0x5EC2F1), location: 0.86),
                .init(color: Color(logoHex: 0x65CBF3), location: 1),
            ]),
            tail: Gradient(stops: [
                .init(color: Color(logoHex: 0xFFDB13), location: 0.2),
                .init(color: Color(logoHex: 0xFF7D45), location: 1),
            ])
        )
    }

    /// The same palette deepened slightly so it holds up on white.
    static var light: LogoPalette {
        LogoPalette(
            fold: Gradient(stops: [
                .init(color: Color(logoHex: 0x0053D6), location: 0.18),
                .init(color: Color(logoHex: 0x0357D7), location: 0.32),
                .init(color: Color(logoHex: 0x0C63D9), location: 0.45),
                .init(color: Color(logoHex: 0x1871DD), location: 0.59),
                .init(color: Color(logoHex: 0x237FE0), location: 0.73),
                .init(color: Color(logoHex: 0x2C8BE2), location: 0.86),
                .init(color: Color(logoHex: 0x2F8FE3), location: 1),
            ]),
            tail: Gradient(stops: [
                .init(color: Color(logoHex: 0xF2B600), location: 0.2),
                .init(color: Color(logoHex: 0xF26A2E), location: 1),
            ])
        )
    }
}

private extension Color {
    init(logoHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// A PreviewProvider rather than #Preview: that macro's plugin ships only with
// Xcode, so with just the Command Line Tools `swift build` fails on it.
struct LogoMark_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            ForEach([16, 32, 64, 128] as [CGFloat], id: \.self) { size in
                LogoMark(size: size)
            }
        }
        .padding(24)
    }
}
