import SwiftUI

// Dimitri's design system: semantic colours that follow light and dark mode,
// a few reusable surfaces, and motion that respects Reduce Motion.

enum Theme {
    /// Brand gradient (deep indigo → cobalt → cyan), echoing the confidence
    /// palette. Used sparingly: the logo, the primary action, hero moments.
    static let brand = LinearGradient(
        colors: [
            Color(red: 0.16, green: 0.20, blue: 0.62),
            Color(red: 0.05, green: 0.40, blue: 0.86),
            Color(red: 0.20, green: 0.72, blue: 0.90),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let brandInk = Color(red: 0.10, green: 0.16, blue: 0.42)

    static let success = Color(nsColor: .systemGreen)
    static let running = Color.accentColor
    static let failure = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)

    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return success
        case "running", "queued": return running
        case "failed": return failure
        default: return .secondary
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "completed": return "Done"
        case "running": return "Running"
        case "queued": return "Queued"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default: return status.capitalized
        }
    }

    static func plddtColor(_ value: Double) -> Color {
        PlddtBand.band(for: value).color
    }

    static func paeColor(_ value: Double, maxValue: Double = 30) -> Color {
        // Dark (confident) to light (uncertain), like AlphaFold's PAE plots.
        let t = min(1, max(0, value / maxValue))
        return Color(
            red: 0.06 + 0.86 * t,
            green: 0.30 + 0.62 * t,
            blue: 0.42 + 0.50 * t
        )
    }
}

extension PlddtBand {
    static func band(for value: Double) -> PlddtBand {
        switch value {
        case 90...: return .veryHigh
        case 70..<90: return .confident
        case 50..<70: return .low
        default: return .veryLow
        }
    }
}

// MARK: - Motion

enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let snappy = Animation.snappy(duration: 0.28)
    static let gentle = Animation.smooth(duration: 0.45)
}

extension View {
    /// Animate `value` changes unless Reduce Motion is on.
    func motion<V: Equatable>(_ animation: Animation = Motion.spring, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    var highlighted = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0 : 0.06),
                        radius: 10, y: 3
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.55) : Theme.hairline, lineWidth: highlighted ? 1.5 : 1)
            )
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?
    var icon: String?
    /// Keep the subtitle on one line (for headers that share a row with controls).
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    if compact {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusBadge: View {
    let status: String
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if status == "running" {
                PulseDot(color: Theme.statusColor(status), size: 6)
            } else {
                Circle().fill(Theme.statusColor(status)).frame(width: 6, height: 6)
            }
            if !compact {
                Text(Theme.statusLabel(status))
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 3)
        .background {
            if !compact {
                Capsule().fill(Theme.statusColor(status).opacity(0.13))
            }
        }
        .foregroundStyle(Theme.statusColor(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(Theme.statusLabel(status))")
    }
}

struct Chip: View {
    let text: String
    var icon: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

/// A softly pulsing dot for "working" states.
struct PulseDot: View {
    var color: Color = .accentColor
    var size: CGFloat = 8
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(on ? 1 : 0.4)
                .opacity(on ? 0 : 1)
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true }
        }
        .accessibilityHidden(true)
    }
}

/// Small circular progress for list rows.
struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .motion(Motion.gentle, value: progress)
        .accessibilityLabel("\(Int(progress * 100)) percent")
    }
}

/// Mean pLDDT as a ring in its confidence band colour.
struct ConfidenceRing: View {
    let value: Double?
    var size: CGFloat = 58
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: 6)
            if let value {
                Circle()
                    .trim(from: 0, to: shown / 100)
                    .stroke(Theme.plddtColor(value), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value.map { Format.score($0, digits: 0) } ?? "—")
                .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .onAppear { animate() }
        .onChange(of: value) { animate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "Mean pLDDT \(Format.score($0))" } ?? "No pLDDT")
    }

    private func animate() {
        withAnimation(.smooth(duration: 0.9)) { shown = value ?? 0 }
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    var caption: String?
    var tint: Color = .primary
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                .contentTransition(.numericText())
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brand)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(hovering ? 0.08 : 0))
                    )
                    .shadow(color: Color(red: 0.05, green: 0.35, blue: 0.85).opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

struct SubtleButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Color.accentColor.opacity(hovering ? 0.22 : 0.15) : Color.primary.opacity(configuration.isPressed ? 0.13 : (hovering ? 0.09 : 0.06)))
            )
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - Loading and empty states

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.18), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: proxy.size.width * phase)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

struct EmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) { actions }
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toasts

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    private var icon: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .info: return .accentColor
        case .success: return Theme.success
        case .failure: return Theme.failure
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: toast.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}
