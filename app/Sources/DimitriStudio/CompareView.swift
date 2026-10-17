import SwiftUI

/// Several models on the same input: superposed in one viewer, with RMSD,
/// per-residue distance and pLDDT side by side.
struct CompareView: View {
    @Environment(AppModel.self) private var app
    let reference: JobSummary
    let others: [JobSummary]

    @State private var included: Set<String> = []
    @State private var comparisons: [String: Comparison] = [:]
    @State private var failures: [String: String] = [:]
    @State private var structures: [ViewerStructure] = []
    @State private var colorByModel = true
    @ObservedObject private var viewer = AppModel.shared.viewer

    static let palette: [Color] = [
        Color(red: 0.18, green: 0.44, blue: 0.92),
        Color(red: 0.95, green: 0.55, blue: 0.16),
        Color(red: 0.56, green: 0.36, blue: 0.85),
        Color(red: 0.17, green: 0.70, blue: 0.64),
    ]
    static let hex = ["#2E70EB", "#F28C28", "#8F5CD9", "#2BB3A3"]

    private var shown: [JobSummary] {
        [reference] + others.filter { included.contains($0.id) }.prefix(3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(
                        title: "Compare models on this input",
                        subtitle: "Other results are superposed onto \(reference.name) (\(app.shortName(for: reference.modelId))) by Kabsch fit on Cα or P atoms.",
                        icon: "square.split.2x1"
                    )
                    FlowChips(jobs: shown, others: others, included: $included)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                overlayCard.frame(maxWidth: .infinity)
                scoresCard.frame(width: 300)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Confidence per residue", subtitle: "pLDDT of each model on the same residues", icon: "chart.xyaxis.line")
                    PlddtOverlayChart(series: series)
                }
            }
            if shown.count > 1 {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Where the models disagree", subtitle: "Distance between matched residues after superposition", icon: "ruler")
                        ForEach(Array(shown.dropFirst().enumerated()), id: \.element.id) { index, job in
                            if let comparison = comparisons[job.id] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(app.shortName(for: job.modelId)) vs \(app.shortName(for: reference.modelId))")
                                        .font(.caption.weight(.semibold))
                                    DeviationChart(distances: comparison.perResidueDistance, color: Self.palette[(index + 1) % Self.palette.count])
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: reference.id) {
            if included.isEmpty { included = Set(others.prefix(2).map(\.id)) }
            await app.loadDetail(reference.id)
        }
        .task(id: shown.map(\.id)) { await load() }
        .onChange(of: colorByModel) { rebuild() }
    }

    private var overlayCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionTitle(title: "Overlay", subtitle: "\(shown.count) structures, superposed", icon: "cube.transparent")
                    Spacer()
                    Picker("Colour", selection: $colorByModel) {
                        Text("By model").tag(true)
                        Text("By pLDDT").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    Button { viewer.resetView() } label: { Image(systemName: "scope") }
                        .buttonStyle(.borderless)
                        .help("Reset the view")
                }
                .padding(14)
                Divider()
                ZStack {
                    MolStarView(structures: structures, colorMode: colorByModel ? .uniform : .plddt, controller: viewer)
                    if structures.isEmpty {
                        ProgressView("Superposing…")
                    }
                }
                .frame(height: 440)
                HStack(spacing: 14) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, job in
                        HStack(spacing: 6) {
                            Circle().fill(colorByModel ? Self.palette[index % Self.palette.count] : Color.secondary).frame(width: 9, height: 9)
                            Text(app.shortName(for: job.modelId)).font(.caption.weight(.medium))
                        }
                    }
                    Spacer()
                    if !colorByModel { PlddtLegend() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private var scoresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Agreement", icon: "checkmark.seal")
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, job in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Self.palette[index % Self.palette.count]).frame(width: 10, height: 10).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.shortName(for: job.modelId)).font(.callout.weight(.semibold))
                            Text("pLDDT \(Format.score(job.plddt)) · \(Format.seconds(job.durationS))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if index == 0 {
                                Text("Reference").font(.caption2).foregroundStyle(.tertiary)
                            } else if let comparison = comparisons[job.id] {
                                Text("RMSD \(String(format: "%.2f", comparison.rmsd)) Å over \(comparison.aligned) \(comparison.atoms) atoms")
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(comparison.rmsd < 2 ? Theme.success : (comparison.rmsd < 5 ? Theme.warning : Theme.failure))
                                    .contentTransition(.numericText())
                            } else if let failure = failures[job.id] {
                                Text(failure).font(.caption2).foregroundStyle(Theme.failure).lineLimit(3)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
                Text("Below 2 Å the models agree closely; above 5 Å they predict different folds.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var series: [PlddtOverlayChart.Series] {
        shown.enumerated().compactMap { index, job in
            guard let values = app.details[job.id]?.result?.perResiduePlddt, !values.isEmpty else { return nil }
            return .init(id: job.id, name: app.shortName(for: job.modelId), color: Self.palette[index % Self.palette.count], values: values)
        }
    }

    private func load() async {
        for job in shown { await app.loadDetail(job.id) }
        for job in shown.dropFirst() where comparisons[job.id] == nil {
            switch await app.compare(reference.id, job.id) {
            case .success(let value): comparisons[job.id] = value
            case .failure(let error): failures[job.id] = error.localizedDescription
            }
        }
        rebuild()
    }

    private func rebuild() {
        Task {
            guard let base = await app.structure(for: reference.id) else { return }
            var list = [ViewerStructure(id: base.id, text: base.text, format: base.format, label: base.label,
                                        colorMode: colorByModel ? .uniform : .plddt, uniformColor: Self.hex[0])]
            for (index, job) in shown.dropFirst().enumerated() {
                guard let comparison = comparisons[job.id] else { continue }
                list.append(ViewerStructure(
                    id: "\(job.id)-on-\(reference.id)",
                    text: comparison.movedText,
                    format: ViewerStructure.Format(comparison.movedFormat) ?? .pdb,
                    label: app.shortName(for: job.modelId),
                    colorMode: colorByModel ? .uniform : .plddt,
                    uniformColor: Self.hex[(index + 1) % Self.hex.count]
                ))
            }
            withAnimation(.smooth) { structures = list }
        }
    }
}

private struct FlowChips: View {
    @Environment(AppModel.self) private var app
    let jobs: [JobSummary]
    let others: [JobSummary]
    @Binding var included: Set<String>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(others.prefix(6)) { job in
                let on = included.contains(job.id)
                Button {
                    withAnimation(Motion.snappy) {
                        if on { included.remove(job.id) } else if included.count < 3 { included.insert(job.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                            .contentTransition(.symbolEffect(.replace))
                        Text("\(app.shortName(for: job.modelId)) · \(Format.relative(job.createdDate))")
                    }
                }
                .buttonStyle(SubtleButtonStyle(prominent: on))
            }
            Spacer()
        }
    }
}
