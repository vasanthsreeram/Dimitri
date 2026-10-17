import Charts
import SwiftUI

/// Per-residue pLDDT on the AlphaFold confidence bands, with hover read-out.
struct PlddtChart: View {
    let values: [Double]
    var sequence: String = ""
    var height: CGFloat = 190
    @State private var revealed = false
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Point: Identifiable {
        let id: Int
        let value: Double
    }

    private var points: [Point] {
        values.enumerated().map { Point(id: $0.offset + 1, value: min(100, max(0, $0.element))) }
    }

    var body: some View {
        if values.isEmpty {
            EmptyState(
                icon: "chart.bar.xaxis",
                title: "No per-residue confidence",
                message: "This structure carries no pLDDT values."
            ) {}
            .frame(height: height)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(PlddtBand.allCases) { band in
                RectangleMark(
                    xStart: .value("Start", 0.5),
                    xEnd: .value("End", Double(values.count) + 0.5),
                    yStart: .value("Low", band.lower),
                    yEnd: .value("High", band.upper)
                )
                .foregroundStyle(band.color.opacity(0.08))
            }
            ForEach(points) { point in
                BarMark(
                    x: .value("Residue", point.id),
                    y: .value("pLDDT", revealed ? point.value : 0),
                    width: .ratio(values.count > 400 ? 1 : 0.82)
                )
                .foregroundStyle(Theme.plddtColor(point.value))
                .opacity(hovered == nil || hovered == point.id ? 1 : 0.55)
            }
            if let hovered, hovered <= values.count {
                RuleMark(x: .value("Residue", hovered))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        tooltip(hovered)
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0.5...(Double(values.count) + 0.5))
        .chartYAxis {
            AxisMarks(values: [0, 50, 70, 90, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("Residue", alignment: .trailing)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geometry[frame].origin.x
                            if let residue: Double = proxy.value(atX: x) {
                                let index = Int(residue.rounded())
                                hovered = (1...values.count).contains(index) ? index : nil
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: height)
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.smooth(duration: 0.8)) { revealed = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-residue pLDDT")
        .accessibilityValue(summary)
    }

    private func tooltip(_ residue: Int) -> some View {
        let value = values[residue - 1]
        let letter = residue <= sequence.count ? String(Array(sequence)[residue - 1]) : ""
        return VStack(spacing: 1) {
            Text("\(letter)\(residue)")
                .font(.caption.weight(.semibold).monospaced())
            Text("pLDDT \(Format.score(value))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.plddtColor(value))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }

    private var summary: String {
        let counts = Dictionary(grouping: values) { PlddtBand.band(for: $0) }.mapValues(\.count)
        return PlddtBand.allCases.map { "\($0.label) \(counts[$0] ?? 0)" }.joined(separator: ", ")
    }
}

extension PlddtBand {
    var lower: Double {
        switch self {
        case .veryHigh: return 90
        case .confident: return 70
        case .low: return 50
        case .veryLow: return 0
        }
    }

    var upper: Double {
        switch self {
        case .veryHigh: return 100
        case .confident: return 90
        case .low: return 70
        case .veryLow: return 50
        }
    }
}

/// Share of residues in each confidence band, as one stacked bar.
struct BandBreakdown: View {
    let values: [Double]

    var body: some View {
        let counts = Dictionary(grouping: values) { PlddtBand.band(for: $0) }.mapValues(\.count)
        let total = max(1, values.count)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(PlddtBand.allCases) { band in
                        let share = CGFloat(counts[band] ?? 0) / CGFloat(total)
                        if share > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(band.color)
                                .frame(width: max(3, proxy.size.width * share - 2))
                        }
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                ForEach(PlddtBand.allCases) { band in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(band.color).frame(width: 9, height: 9)
                        Text("\(band.label) \(band.range)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(Int((Double(counts[band] ?? 0) / Double(total) * 100).rounded()))%")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Predicted aligned error as a bitmap (fast for hundreds of residues).
struct PaeHeatmap: View {
    let matrix: PaeMatrix
    var maxValue: Double = 30
    @State private var image: CGImage?
    @State private var hover: (Int, Int, Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .transition(.opacity)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)).shimmering()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let n = matrix.matrix.count
                        guard n > 0 else { return }
                        let i = min(n - 1, max(0, Int(point.y / proxy.size.height * CGFloat(n))))
                        let j = min(n - 1, max(0, Int(point.x / proxy.size.width * CGFloat(n))))
                        hover = (i, j, matrix.matrix[i][j])
                    case .ended:
                        hover = nil
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            HStack {
                if let hover {
                    Text("aligned \(hover.0 * matrix.stride + 1) · scored \(hover.1 * matrix.stride + 1) · \(Format.score(hover.2)) Å")
                        .font(.caption2.monospacedDigit())
                } else {
                    Text("Aligned residue ↓ · scored residue →")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(matrix.stride > 1 ? "\(matrix.size)² (shown in \(matrix.stride)-residue blocks)" : "\(matrix.size) × \(matrix.size)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text("0 Å").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                LinearGradient(
                    colors: (0...10).map { Theme.paeColor(Double($0) * 3, maxValue: maxValue) },
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 6)
                .clipShape(Capsule())
                Text("30 Å").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .task(id: matrix) {
            let rendered = await Task.detached(priority: .userInitiated) { [matrix, maxValue] in
                Self.render(matrix.matrix, maxValue: maxValue)
            }.value
            withAnimation(.smooth) { image = rendered }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Predicted aligned error heatmap, \(matrix.size) residues")
    }

    nonisolated static func render(_ matrix: [[Double]], maxValue: Double) -> CGImage? {
        let n = matrix.count
        guard n > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<n {
            let row = matrix[i]
            for j in 0..<min(n, row.count) {
                let t = min(1, max(0, row[j] / maxValue))
                let offset = (i * n + j) * 4
                pixels[offset] = UInt8((0.06 + 0.86 * t) * 255)
                pixels[offset + 1] = UInt8((0.30 + 0.62 * t) * 255)
                pixels[offset + 2] = UInt8((0.42 + 0.50 * t) * 255)
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// pLDDT of several models on the same input, one line each.
struct PlddtOverlayChart: View {
    struct Series: Identifiable {
        let id: String
        let name: String
        let color: Color
        let values: [Double]
    }

    let series: [Series]

    var body: some View {
        Chart {
            ForEach(series) { item in
                ForEach(Array(item.values.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Residue", index + 1),
                        y: .value("pLDDT", value),
                        series: .value("Model", item.name)
                    )
                    .foregroundStyle(item.color)
                    .interpolationMethod(.monotone)
                }
            }
            RuleMark(y: .value("Confident", 70))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
        }
        .chartYScale(domain: 0...100)
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 180)
        .accessibilityLabel("pLDDT per residue for each model")
    }
}

/// Distance between matched residues after superposition.
struct DeviationChart: View {
    let distances: [Double?]
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(distances.enumerated()), id: \.offset) { index, value in
                if let value {
                    AreaMark(x: .value("Residue", index + 1), y: .value("Å", value))
                        .foregroundStyle(color.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Residue", index + 1), y: .value("Å", value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYAxisLabel("Å")
        .frame(height: 140)
        .accessibilityLabel("Per-residue distance after superposition")
    }
}
