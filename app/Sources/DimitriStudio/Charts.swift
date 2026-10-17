import SwiftUI

struct MetricCard: View {
    let label: String
    let value: String
    let caption: String
    var color: Color = .primary
    var unavailable: Bool = false

    var body: some View {
        Card(padding: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(unavailable ? Color.secondary : color)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PlddtChart: View {
    let values: [Double]
    var height: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if values.isEmpty {
                placeholder
            } else {
                Canvas { context, size in
                    let top: CGFloat = 6
                    let usable = size.height - top
                    for mark in [0, 25, 50, 75, 100] {
                        let y = top + usable * (1 - CGFloat(mark) / 100)
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(
                            path,
                            with: .color(Color.primary.opacity(mark == 0 ? 0.16 : 0.06)),
                            lineWidth: 1
                        )
                    }
                    let count = values.count
                    let barWidth = size.width / CGFloat(count)
                    for (index, value) in values.enumerated() {
                        let clamped = min(100, max(0, value))
                        let barHeight = max(1, usable * CGFloat(clamped) / 100)
                        let rect = CGRect(
                            x: CGFloat(index) * barWidth,
                            y: top + usable - barHeight,
                            width: max(0.8, barWidth - 0.15),
                            height: barHeight
                        )
                        context.fill(
                            Path(rect),
                            with: .color(Theme.plddtColor(clamped).opacity(0.92))
                        )
                    }
                }
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.10))
                )

                HStack {
                    Text("1")
                    Spacer()
                    Text("\(values.count)")
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)

                HStack(spacing: 12) {
                    legend("Very high", Theme.plddtColor(95))
                    legend("Confident", Theme.plddtColor(80))
                    legend("Low", Theme.plddtColor(60))
                    legend("Very low", Theme.plddtColor(30))
                    Spacer()
                    Text("pLDDT")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("This model did not report per-residue pLDDT.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }
}

struct PaeHeatmap: View {
    let matrix: [[Double]]
    var maxValue: Double = 30

    private var size: Int { matrix.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if matrix.isEmpty {
                placeholder
            } else {
                Canvas { context, canvasSize in
                    let step = max(1, Int(ceil(Double(size) / 140.0)))
                    let cells = Int(ceil(Double(size) / Double(step)))
                    let cellW = canvasSize.width / CGFloat(cells)
                    let cellH = canvasSize.height / CGFloat(cells)
                    for rowIndex in stride(from: 0, to: size, by: step) {
                        let row = matrix[rowIndex]
                        for colIndex in stride(from: 0, to: min(size, row.count), by: step) {
                            let value = row[colIndex]
                            let rect = CGRect(
                                x: CGFloat(colIndex / step) * cellW,
                                y: CGFloat(rowIndex / step) * cellH,
                                width: cellW + 0.4,
                                height: cellH + 0.4
                            )
                            context.fill(
                                Path(rect),
                                with: .color(Theme.paeColor(value, maxValue: maxValue))
                            )
                        }
                    }
                }
                .frame(height: 196)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                HStack {
                    Text("Rows: aligned residue · columns: scored residue")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(size) × \(size)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Text("0")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    LinearGradient(
                        colors: (0...10).map {
                            Theme.paeColor(Double($0) / 10 * maxValue, maxValue: maxValue)
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 6)
                    .clipShape(Capsule())
                    Text("30 Å")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No PAE matrix from this model.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 196)
    }
}
