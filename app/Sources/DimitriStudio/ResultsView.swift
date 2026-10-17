import AppKit
import SwiftUI

enum JobFilter: String, CaseIterable, Identifiable {
    case all, running, done, failed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    func matches(_ job: JobSummary) -> Bool {
        switch self {
        case .all: return true
        case .running: return job.isActive
        case .done: return job.isCompleted
        case .failed: return job.status == "failed" || job.status == "cancelled"
        }
    }
}

struct ResultsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var filter: JobFilter = .all

    private var filtered: [JobSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return app.predictions.filter { job in
            filter.matches(job) && (query.isEmpty
                || job.name.localizedCaseInsensitiveContains(query)
                || app.shortName(for: job.modelId).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            jobList
                .frame(width: 270)
            Divider()
            Group {
                if let summary = app.selectedSummary {
                    JobDetailView(summary: summary)
                        .id(summary.id)
                        .transition(.opacity)
                } else {
                    EmptyState(
                        icon: "cube.transparent",
                        title: app.predictions.isEmpty ? "No results yet" : "Select a result",
                        message: app.predictions.isEmpty
                            ? "Run a model on the Predict screen, or drop a PDB or mmCIF file here to view it."
                            : "Choose a job on the left to see its structure and confidence."
                    ) {
                        if app.predictions.isEmpty {
                            Button("New Prediction") { withAnimation(Motion.snappy) { app.screen = .predict } }
                                .buttonStyle(PrimaryButtonStyle())
                            Button("Open a Structure…") { app.openPanel() }
                                .buttonStyle(SubtleButtonStyle())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.gentle, value: app.selectedJobID)
        }
        .navigationTitle("Results")
        .navigationSubtitle(app.selectedSummary?.name ?? "\(app.predictions.count) jobs")
        .confirmationDialog(
            "Delete “\(app.selectedSummary?.name ?? "this job")” and its files?",
            isPresented: $app.confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                if let id = app.selectedJobID { Task { await app.delete(id) } }
            }
        } message: {
            Text("The structure, confidence values and logs are removed from this Mac.")
        }
    }

    private var jobList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search results", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Filter", selection: $filter) {
                    ForEach(JobFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { job in
                            JobListRow(job: job, selected: job.id == app.selectedJobID)
                                .id(job.id)
                                .contentShape(Rectangle())
                                .onTapGesture { app.select(job.id, show: false) }
                                .contextMenu { JobContextMenu(job: job) }
                        }
                    }
                    .padding(8)
                }
                .overlay {
                    if filtered.isEmpty {
                        Text(app.predictions.isEmpty ? "Nothing here yet" : "No jobs match")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
                .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            }
        }
        .background(Theme.canvas)
    }

    /// Arrow keys move the selection through the visible list.
    private func move(_ step: Int, _ proxy: ScrollViewProxy) {
        let ids = filtered.map(\.id)
        guard !ids.isEmpty else { return }
        let current = app.selectedJobID.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        let next = min(ids.count - 1, max(0, current + step))
        app.select(ids[next], show: false)
        withAnimation(Motion.snappy) { proxy.scrollTo(ids[next], anchor: .center) }
    }
}

struct JobListRow: View {
    @Environment(AppModel.self) private var app
    let job: JobSummary
    var selected = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(job.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if job.isCompleted, let plddt = job.plddt {
                    Text(Format.score(plddt))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.plddtColor(plddt).opacity(0.18)))
                        .help("Mean pLDDT")
                } else {
                    StatusBadge(status: job.status, compact: job.isCompleted)
                }
            }
            HStack(spacing: 5) {
                Text(app.shortName(for: job.modelId))
                Text("·")
                Text("\(job.length) \(EntityKind(rawValue: job.entityType)?.unit ?? "")")
                Spacer()
                Text(Format.relative(job.createdDate))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if job.isActive {
                ProgressView(value: min(100, max(0, job.progress)), total: 100)
                    .controlSize(.small)
                    .tint(Color.accentColor)
                    .motion(Motion.gentle, value: job.progress)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 8)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Detail

struct JobDetailView: View {
    @Environment(AppModel.self) private var app
    let summary: JobSummary

    private var job: Job? { app.details[summary.id] }
    private var siblings: [JobSummary] { app.siblings(of: summary) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if summary.isCompleted {
                    if app.compareMode, !siblings.isEmpty {
                        CompareView(reference: summary, others: siblings)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if let job, let result = job.result {
                        CompletedResultView(job: job, result: result)
                            .transition(.opacity)
                    } else {
                        ResultSkeleton()
                    }
                } else {
                    LiveProgressCard(summary: summary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 1320)
            .frame(maxWidth: .infinity)
            .motion(Motion.gentle, value: summary.status)
            .motion(Motion.gentle, value: app.compareMode)
        }
        .task(id: summary.status) { await app.loadDetail(summary.id, force: summary.isTerminal) }
        .toolbar { toolbar }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(summary.name)
                        .font(.system(size: 24, weight: .bold))
                        .textSelection(.enabled)
                    StatusBadge(status: summary.status)
                }
                HStack(spacing: 8) {
                    Chip(text: app.shortName(for: summary.modelId), icon: summary.isImport ? "doc" : "cpu", tint: .accentColor)
                    if let entity = EntityKind(rawValue: summary.entityType) {
                        Chip(text: "\(entity.label) · \(summary.length) \(entity.unit)", icon: entity.symbol)
                    }
                    if summary.kind == "predict" {
                        Chip(text: "seed \(summary.seed)")
                    }
                    if let warm = summary.warm, summary.isCompleted, summary.kind == "predict" {
                        Chip(text: warm ? "Warm model" : "Cold start", icon: warm ? "bolt.fill" : "snowflake", tint: warm ? Theme.success : .secondary)
                            .help(warm ? "The model was already loaded, so the job skipped start-up." : "This job started the model process.")
                    }
                    Text(summary.createdDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if !siblings.isEmpty, summary.isCompleted {
                Toggle(isOn: Binding(get: { app.compareMode }, set: { value in withAnimation(Motion.snappy) { app.compareMode = value } })) {
                    Label("Compare", systemImage: "square.split.2x1")
                }
                .help("Compare with \(siblings.count) other result(s) on the same input (⌘K)")
            }
            if summary.isActive {
                Button {
                    Task { await app.cancel(summary.id) }
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                .help("Cancel this job (⌘.)")
            } else {
                if summary.kind == "predict" {
                    Button {
                        Task { await app.rerun(summary.id) }
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                    }
                    .help("Run the same input again (⌘R)")
                }
                if summary.isCompleted {
                    Menu {
                        Button("mmCIF…") { app.export(summary.id, format: "cif") }
                        Button("PDB…") { app.export(summary.id, format: "pdb") }
                        Button("Confidence JSON…") { app.export(summary.id, format: "json") }
                        Divider()
                        Button("Structure Image…") { app.requestSnapshot() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export the structure (⌘E for mmCIF)")
                }
                Button {
                    app.confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this job (⌘⌫)")
            }
        }
    }
}

// MARK: - Live progress

struct LiveProgressCard: View {
    @Environment(AppModel.self) private var app
    let summary: JobSummary
    @State private var showLog = false

    private var stages: [Stage] {
        app.live[summary.id]?.stages ?? app.details[summary.id]?.stages ?? []
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: title, subtitle: subtitle, icon: icon)
                    Spacer()
                    if summary.isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Format.elapsed(since: summary.startedDate ?? summary.createdDate, until: context.date))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    Text("\(Int(summary.progress))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .frame(minWidth: 56, alignment: .trailing)
                }

                ProgressView(value: min(100, max(0, summary.progress)), total: 100)
                    .tint(summary.status == "failed" ? Theme.failure : Color.accentColor)
                    .motion(Motion.gentle, value: summary.progress)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                        StageRow(stage: stage, isLast: index == stages.count - 1)
                    }
                }

                if summary.status == "failed" || summary.status == "cancelled" {
                    failure
                }

                if let log = app.live[summary.id]?.log ?? app.details[summary.id]?.logTail, !log.isEmpty {
                    DisclosureGroup("Recent output", isExpanded: $showLog) {
                        Text((app.details[summary.id]?.logTail ?? log).suffix(30).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
        }
        .motion(Motion.spring, value: stages)
    }

    private var title: String {
        switch summary.status {
        case "queued": return "Waiting for the model"
        case "running": return summary.stageName ?? "Running"
        case "failed": return "This run failed"
        case "cancelled": return "Cancelled"
        default: return "Working"
        }
    }

    private var subtitle: String? {
        if summary.status == "queued" { return "Another job is using the GPU; this one starts next." }
        return summary.stageMessage
    }

    private var icon: String {
        switch summary.status {
        case "failed": return "exclamationmark.triangle"
        case "cancelled": return "stop.circle"
        default: return "bolt.horizontal"
        }
    }

    @ViewBuilder
    private var failure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let error = app.details[summary.id]?.error ?? summary.error {
                Text(error)
                    .font(.callout.monospaced())
                    .foregroundStyle(Theme.failure)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
            if let hint = app.details[summary.id]?.hint ?? summary.hint {
                Label(hint, systemImage: "lightbulb")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if summary.kind == "predict" {
                    Button("Run Again") { Task { await app.rerun(summary.id) } }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                    Button("Edit Input") { Task { await app.reuseInput(summary.id) } }
                        .buttonStyle(SubtleButtonStyle())
                }
                Button("Open Library") { withAnimation(Motion.snappy) { app.screen = .library } }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
    }
}

private struct StageRow: View {
    let stage: Stage
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    if stage.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                            .transition(.scale.combined(with: .opacity))
                    } else if stage.isFailed {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.failure)
                    } else if stage.isRunning {
                        PulseDot(size: 9)
                    } else {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                    }
                }
                .font(.system(size: 15))
                .frame(width: 18, height: 18)
                if !isLast {
                    Rectangle()
                        .fill(stage.isDone ? Theme.success.opacity(0.5) : Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(stage.name)
                        .font(.callout.weight(stage.isRunning ? .semibold : .regular))
                        .foregroundStyle(stage.isPending ? .secondary : .primary)
                    Spacer()
                    if stage.isRunning, stage.progress > 0 {
                        Text("\(Int(stage.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                if stage.isRunning {
                    if let message = stage.message, !message.isEmpty {
                        Text(message)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    ProgressView(value: stage.progress, total: 1)
                        .controlSize(.mini)
                        .tint(Color.accentColor)
                        .frame(maxWidth: 360)
                        .motion(Motion.gentle, value: stage.progress)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.name), \(stage.status)")
    }
}

// MARK: - Completed result

struct CompletedResultView: View {
    @Environment(AppModel.self) private var app
    let job: Job
    let result: JobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MetricsStrip(job: job, result: result)
            StructureCard(job: job, result: result)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(title: "Per-residue confidence", subtitle: "pLDDT by residue (0–100). Hover for values.", icon: "chart.bar.xaxis")
                            PlddtChart(values: result.perResiduePlddt, sequence: job.sequence)
                            if !result.perResiduePlddt.isEmpty {
                                BandBreakdown(values: result.perResiduePlddt)
                            }
                        }
                    }
                    if let dotBracket = result.dotBracket {
                        SecondaryStructureCard(sequence: job.sequence, dotBracket: dotBracket)
                    }
                    if let note = result.note {
                        Label {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    if let paeSize = result.paeSize, paeSize > 0 {
                        PaeCard(jobID: job.id, note: result.paeNote)
                    }
                    DetailsCard(job: job, result: result)
                }
                .frame(width: 310)
            }
        }
    }
}

private struct MetricsStrip: View {
    let job: Job
    let result: JobResult

    var body: some View {
        Card(padding: 16) {
            HStack(spacing: 22) {
                HStack(spacing: 14) {
                    ConfidenceRing(value: result.confident ? result.metrics.plddt : nil)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mean pLDDT")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(result.confident ? (result.metrics.plddt.map { PlddtBand.band(for: $0).label } ?? "—") : "No confidence values")
                            .font(.title3.weight(.semibold))
                        Text("per-residue confidence, 0–100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 220, alignment: .leading)
                Divider().frame(height: 46)
                MetricTile(label: "pTM", value: Format.score(result.metrics.ptm, digits: 2), caption: result.metrics.ptm == nil ? "Not reported by this model" : "Global fold confidence", help: "Predicted TM-score of the whole structure (0–1).")
                MetricTile(label: "ipTM", value: Format.score(result.metrics.iptm, digits: 2), caption: result.metrics.iptm == nil ? "Single chain: no interface" : "Interface confidence", help: "Interface predicted TM-score between chains (0–1).")
                MetricTile(label: "Size", value: "\(result.residues)", caption: "\(result.atoms) atoms · \(result.chains) chain\(result.chains == 1 ? "" : "s")")
                MetricTile(label: "Time", value: Format.seconds(result.durationS), caption: timeCaption, tint: result.warm == true ? Theme.success : .primary)
            }
        }
    }

    private var timeCaption: String {
        if job.kind == "import" { return "Imported file" }
        if let device = result.device { return "on \(device.uppercased())\(result.warm == true ? " · model already loaded" : "")" }
        return ""
    }
}

struct StructureCard: View {
    @Environment(AppModel.self) private var app
    let job: Job
    let result: JobResult
    @State private var structures: [ViewerStructure] = []
    @State private var colorMode: ViewerColorMode = .plddt
    @State private var loadFailed = false
    @ObservedObject private var viewer = AppModel.shared.viewer

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SectionTitle(title: "Structure", subtitle: subtitle, icon: "cube", compact: true)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Picker("Colour", selection: $colorMode) {
                        Text("pLDDT").tag(ViewerColorMode.plddt)
                        Text("Chain").tag(ViewerColorMode.chain)
                        Text("Secondary").tag(ViewerColorMode.secondary)
                        Text("Rainbow").tag(ViewerColorMode.rainbow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Colour the cartoon by")
                    Button {
                        viewer.resetView()
                    } label: {
                        Image(systemName: "scope")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset the view")
                    Button {
                        app.requestSnapshot()
                    } label: {
                        Image(systemName: "camera")
                    }
                    .buttonStyle(.borderless)
                    .help("Save an image of the view (⇧⌘S)")
                }
                .padding(14)
                Divider()
                ZStack {
                    MolStarView(structures: structures, colorMode: colorMode, controller: viewer)
                        .opacity(isLoaded ? 1 : 0.001)
                    overlay
                }
                .frame(height: 500)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
                legend
            }
        }
        .task(id: job.id) {
            colorMode = result.confident ? .plddt : .secondary
            loadFailed = false
            if let structure = await app.structure(for: job.id) {
                withAnimation(.smooth) { structures = [structure] }
            } else {
                loadFailed = true
            }
            // The controller lives as long as the app, so a strong capture is fine.
            let controller = viewer
            app.snapshotProvider = { try await controller.snapshotPNG() }
        }
        .motion(Motion.gentle, value: isLoaded)
    }

    private var isLoaded: Bool {
        if case .loaded = viewer.state { return !structures.isEmpty }
        return false
    }

    private var subtitle: String {
        if case .loaded(let report) = viewer.state, let first = report.structures.first {
            let kinds = first.polymerTypes.map { $0 == "rna" ? "RNA" : ($0 == "dna" ? "DNA" : $0) }.joined(separator: " + ")
            let ss = first.secondaryStructure.map { $0.helix + $0.sheet > 0 ? " · \($0.helix) helix, \($0.sheet) strand residues" : "" } ?? ""
            return "\(first.representation.capitalized) · \(kinds.isEmpty ? "structure" : kinds)\(ss)"
        }
        return "Mol* · loaded from this Mac, no network"
    }

    @ViewBuilder
    private var overlay: some View {
        switch viewer.state {
        case .failed(let message):
            EmptyState(icon: "exclamationmark.triangle", title: "The viewer could not show this structure", message: message) {
                Button("Reload") {
                    let current = structures
                    structures = []
                    DispatchQueue.main.async { structures = current }
                }
                .buttonStyle(SubtleButtonStyle())
            }
        case .loaded:
            EmptyView()
        default:
            if loadFailed {
                EmptyState(icon: "cube.transparent", title: "Structure file missing", message: "The result files for this job could not be read.") {}
            } else {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 220, height: 150)
                        .shimmering()
                    Text("Building the cartoon…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        if case .loaded(let report) = viewer.state {
            HStack(spacing: 12) {
                if report.showsConfidenceLegend {
                    PlddtLegend()
                } else if let note = report.structures.first?.confidenceNote, colorMode == .plddt {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Coloured by \(colorMode.label.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Drag to rotate · scroll to zoom · right-drag to move")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .transition(.opacity)
        }
    }
}

private struct DetailsCard: View {
    @Environment(AppModel.self) private var app
    let job: Job
    let result: JobResult

    var body: some View {
        VStack(spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    SectionTitle(title: "Run details", icon: "list.bullet.rectangle")
                    if let device = result.device {
                        KeyValueRow(label: "Device", value: device.uppercased())
                    }
                    if let runtime = app.runner(for: job.modelId)?.runtime {
                        KeyValueRow(label: "Runtime", value: runtime)
                    }
                    if let warm = result.warm {
                        KeyValueRow(label: "Model", value: warm ? "Already loaded" : "Loaded for this job")
                    }
                    ForEach(timingRows, id: \.0) { row in
                        KeyValueRow(label: row.0, value: row.1)
                    }
                    if let peak = result.peakMemoryGb {
                        KeyValueRow(label: "GPU memory", value: String(format: "%.2f GB", peak))
                    }
                    if job.kind == "predict" {
                        KeyValueRow(label: "Seed", value: "\(job.seed)")
                        KeyValueRow(label: "Samples", value: "\(job.samples)")
                    }
                    KeyValueRow(label: "Native file", value: result.format == "pdb" ? "PDB" : "mmCIF")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Export", subtitle: "Portable files for PyMOL, ChimeraX and friends", icon: "square.and.arrow.down")
                    ExportRow(title: "mmCIF", detail: "with entity records", icon: "doc.text") { app.export(job.id, format: "cif") }
                    ExportRow(title: "PDB", detail: "pLDDT in the B-factor column", icon: "doc.text") { app.export(job.id, format: "pdb") }
                    ExportRow(title: "JSON", detail: "metrics, pLDDT and PAE", icon: "curlybraces") { app.export(job.id, format: "json") }
                }
            }
        }
    }

    private var timingRows: [(String, String)] {
        guard let timings = result.timings else { return [] }
        let names: [(String, String)] = [
            ("queue_s", "Waiting"), ("model_load_s", "Model load"), ("featurise_s", "Features"),
            ("trunk_s", "Trunk"), ("diffusion_s", "Diffusion"), ("predict_s", "Prediction"),
            ("confidence_s", "Confidence"), ("write_s", "Writing"),
        ]
        return names.compactMap { key, label in
            guard let value = timings[key], value >= 0.05 || key == "predict_s" else { return nil }
            return (label, Format.seconds(value))
        }
    }
}

private struct ExportRow: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: hovering)
        .accessibilityLabel("Export \(title)")
    }
}

private struct PaeCard: View {
    @Environment(AppModel.self) private var app
    let jobID: String
    let note: String?
    @State private var matrix: PaeMatrix?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Predicted aligned error", subtitle: note ?? "Expected position error in Å", icon: "square.grid.3x3")
                if let matrix {
                    PaeHeatmap(matrix: matrix)
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                        .aspectRatio(1, contentMode: .fit)
                        .shimmering()
                }
            }
        }
        .task(id: jobID) {
            let value = await app.pae(for: jobID)
            withAnimation(.smooth) { matrix = value }
        }
    }
}

private struct SecondaryStructureCard: View {
    let sequence: String
    let dotBracket: String

    private var pairs: Int { dotBracket.filter { "([{".contains($0) }.count }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Secondary structure", subtitle: "Base pairs predicted by RhoFold+ (dot-bracket)", icon: "point.3.connected.trianglepath.dotted")
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sequence)
                        Text(dotBracket)
                            .foregroundStyle(.tint)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                }
                HStack(spacing: 12) {
                    Chip(text: "\(pairs) base pairs", icon: "link")
                    if dotBracket.contains("[") {
                        Chip(text: "Pseudoknot", icon: "arrow.triangle.branch", tint: Theme.warning)
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(">\(sequence.count) nt\n\(sequence)\n\(dotBracket)\n", forType: .string)
                    AppModel.shared.present(.success, "Copied sequence and structure")
                } label: {
                    Label("Copy as dot-bracket", systemImage: "doc.on.doc")
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
    }
}

private struct ResultSkeleton: View {
    var body: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)).frame(height: 90)
            RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)).frame(height: 470)
        }
        .shimmering()
    }
}
