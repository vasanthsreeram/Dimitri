import SwiftUI

enum Theme {
    static let accent = Color(red: 0.31, green: 0.83, blue: 0.68)
    static let accentDeep = Color(red: 0.13, green: 0.55, blue: 0.45)
    static let amber = Color(red: 0.96, green: 0.73, blue: 0.35)
    static let danger = Color(red: 0.94, green: 0.45, blue: 0.42)
    static let blue = Color(red: 0.42, green: 0.66, blue: 0.98)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .underPageBackgroundColor)

    static func plddtColor(_ value: Double) -> Color {
        switch value {
        case 90...: return Color(red: 0.35, green: 0.62, blue: 0.98)
        case 70..<90: return Color(red: 0.38, green: 0.86, blue: 0.90)
        case 50..<70: return Color(red: 0.98, green: 0.83, blue: 0.38)
        default: return Color(red: 0.97, green: 0.51, blue: 0.36)
        }
    }

    static func paeColor(_ value: Double, maxValue: Double = 30) -> Color {
        let t = min(1, max(0, value / maxValue))
        if t < 0.5 {
            let u = t / 0.5
            return Color(
                red: 0.10 + 0.85 * u,
                green: 0.55 + 0.28 * u,
                blue: 0.72 - 0.40 * u
            )
        }
        let u = (t - 0.5) / 0.5
        return Color(
            red: 0.95,
            green: 0.83 - 0.42 * u,
            blue: 0.32 - 0.20 * u
        )
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "completed", "ready": return accent
        case "running", "queued": return blue
        case "failed": return danger
        case "cancelled": return .secondary
        default: return .secondary
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.panel.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct CardTitle: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(filled ? color.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(filled ? 0.35 : 0.55), lineWidth: 1)
            )
            .foregroundStyle(color)
    }
}

struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .foregroundStyle(.secondary)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct AdaptiveButtonStyle: ButtonStyle {
    let primary: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if primary {
            PrimaryButtonStyle().makeBody(configuration: configuration)
        } else {
            SecondaryButtonStyle().makeBody(configuration: configuration)
        }
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
