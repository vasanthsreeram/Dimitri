import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
}

struct ResultsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var search = ""
    @State private var filter: JobFilter = .all
    @State private var cifText: String?
    @State private var structureLoading = false
    @State private var exportingFormat: String?
    @State private var confirmDelete = false

    private var filteredJobs: [Job] {
        app.predictions.filter { job in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .running: matchesFilter = job.isRunning
            case .done: matchesFilter = job.status == "completed"
            case .failed: matchesFilter = job.status == "failed" || job.status == "cancelled"
            }
            let query = search.trimmingCharacters(in: .whitespaces)
            let matchesSearch = query.isEmpty
                || job.name.localizedCaseInsensitiveContains(query)
                || job.modelId.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
    }

    private var job: Job? { app.selectedJob }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 268)
            Divider().opacity(0.5)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Jobs")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(app.predictions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            TextField("Search jobs", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .padding(.horizontal, 14)

            HStack(spacing: 4) {
                ForEach(JobFilter.allCases) { item in
                    Button(item.label) {
                        filter = item
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(filter == item ? Color.primary.opacity(0.1) : .clear)
                    )
                    .foregroundStyle(filter == item ? .primary : .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(spacing: 3) {
                    if filteredJobs.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "tray")
                                .foregroundStyle(.tertiary)
                            Text(app.predictions.isEmpty ? "No predictions yet" : "No jobs match")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                    }
                    ForEach(filteredJobs) { item in
                        JobRow(
                            job: item,
                            modelName: app.runner(for: item)?.shortName ?? item.modelId,
                            selected: item.id == app.selectedJobID
                        ) {
                            app.selectedJobID = item.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(Theme.panel.opacity(0.25))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let job {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(job)

                    if job.isRunning || job.status == "failed" || job.status == "cancelled" {
                        progressCard(job)
                    }

                    if let result = job.result {
                        metrics(result)
                        viewerRow(job, result: result)
                        chartsRow(result)
                        noteCard(job, result: result)
                    } else if job.status == "completed" {
                        ProgressView("Loading result…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .padding(22)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if job.isRunning { app.watch(jobID: job.id) }
            }
            .onChange(of: app.selectedJobID) { _, newValue in
                if let id = newValue, let selected = app.job(id: id), selected.isRunning {
                    app.watch(jobID: id)
                }
            }
            .task(id: "\(job.id)-\(job.status)") {
                guard job.status == "completed" else {
                    cifText = nil
                    structureLoading = false
                    return
                }
                cifText = nil
                structureLoading = true
                let text = await app.structureText(jobID: job.id)
                guard !Task.isCancelled, app.selectedJobID == job.id else { return }
                cifText = text
                structureLoading = false
            }
            .confirmationDialog(
                "Delete this job and its files?",
                isPresented: $confirmDelete
            ) {
                Button("Delete", role: .destructive) {
                    Task { await app.delete(jobID: job.id) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No prediction selected")
                    .font(.system(size: 15, weight: .semibold))
                Text("Run a model from the Predict screen, then watch its stages here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(job.name)
                            .font(.system(size: 25, weight: .bold))
                        StatusPill(
                            text: job.status.capitalized,
                            color: Theme.statusColor(job.status),
                            filled: true
                        )
                    }
                    HStack(spacing: 8) {
                        Text(app.runner(for: job)?.shortName ?? job.modelId)
                        Text("·")
                        Text(job.entityType.uppercased())
                        Text("·")
                        Text("seed \(job.seed)")
                        Text("·")
                        Text("\(job.samples) sample\(job.samples == 1 ? "" : "s")")
                        Text("·")
                        Text(job.createdDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    if job.isRunning {
                        Button("Cancel") {
                            Task { await app.cancel(jobID: job.id) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button {
                            rerun(job)
                        } label: {
                            Label("Run again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button {
                            confirmDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Delete job")
                    }
                }
            }
        }
    }

    private func progressCard(_ job: Job) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    CardTitle(
                        title: job.status == "failed" ? "Run failed" : "Progress",
                        icon: job.status == "failed" ? "exclamationmark.triangle" : "bolt.horizontal"
                    )
                    Spacer()
                    Text("\(Int(job.progress))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: min(100, max(0, job.progress)), total: 100)
                    .tint(Theme.accent)

                VStack(spacing: 7) {
                    ForEach(job.stages) { stage in
                        HStack(spacing: 9) {
                            Group {
                                if stage.isDone {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                } else if stage.isFailed {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Theme.danger)
                                } else if stage.isRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 15)

                            Text(stage.name)
                                .font(.system(size: 11.5, weight: stage.isRunning ? .semibold : .regular))
                                .foregroundStyle(stage.status == "pending" ? .tertiary : .primary)
                            if let message = stage.message, !message.isEmpty, stage.isRunning {
                                Text(message)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }

                if job.status == "failed" {
                    Divider().opacity(0.5)
                    if let error = job.error {
                        Text(error)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.danger)
                            .textSelection(.enabled)
                            .lineLimit(10)
                    }
                    if let hint = job.hint {
                        Text(hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let runner = app.runner(for: job),
                       let requestURL = runner.weightRequestUrl,
                       let url = URL(string: requestURL) {
                        HStack(spacing: 10) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Request model weights", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            if let dir = runner.weightDir {
                                Text(dir)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func metrics(_ result: JobResult) -> some View {
        HStack(spacing: 12) {
            MetricCard(
                label: "pTM",
                value: formatPercent(result.metrics.ptm),
                caption: "Global fold confidence (0–1)",
                color: Theme.accent,
                unavailable: result.metrics.ptm == nil
            )
            MetricCard(
                label: "ipTM",
                value: formatPercent(result.metrics.iptm),
                caption: result.metrics.iptm == nil
                    ? "Not reported for a single chain"
                    : "Interface confidence (0–1)",
                color: Theme.accent,
                unavailable: result.metrics.iptm == nil
            )
            MetricCard(
                label: "pLDDT",
                value: formatScore(result.metrics.plddt),
                caption: "Mean per-residue confidence (0–100)",
                color: Theme.plddtColor(result.metrics.plddt ?? 0),
                unavailable: result.metrics.plddt == nil
            )
        }
    }

    private func viewerRow(_ job: Job, result: JobResult) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        CardTitle(title: "3D structure", subtitle: "Mol* · top-ranked sample", icon: "cube")
                        Spacer()
                        if job.result?.format == "cif" {
                            StatusPill(text: "CIF", color: .secondary)
                        }
                    }
                    .padding(15)
                    Divider().opacity(0.4)
                    Group {
                        if let cifText, !cifText.isEmpty {
                            MolStarView(cif: cifText)
                                .frame(height: 430)
                        } else if structureLoading {
                            VStack(spacing: 9) {
                                ProgressView()
                                Text("Loading structure…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 430)
                        } else {
                            VStack(spacing: 9) {
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundStyle(.tertiary)
                                Text("Preview unavailable")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Export the structure below to open it in your own viewer.")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 430)
                        }
                    }
                    .background(Color(red: 0.05, green: 0.067, blue: 0.09))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 11) {
                        CardTitle(title: "Export", subtitle: "Portable, unmodified files", icon: "square.and.arrow.down")
                        ExportButton(title: "CIF", subtitle: "mmCIF structure", icon: "doc.text", busy: exportingFormat == "cif") {
                            export(job, format: "cif")
                        }
                        ExportButton(title: "PDB", subtitle: "Legacy PDB structure", icon: "doc.text", busy: exportingFormat == "pdb") {
                            export(job, format: "pdb")
                        }
                        ExportButton(title: "JSON", subtitle: "Confidence and pLDDT", icon: "curlybraces", busy: exportingFormat == "json") {
                            export(job, format: "json")
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        CardTitle(title: "Details", icon: "list.bullet")
                        if let device = result.device {
                            KeyValueRow(label: "Device", value: device.uppercased())
                        } else if let runtime = app.runner(for: job)?.runtime {
                            KeyValueRow(label: "Target runtime", value: runtime)
                        }
                        KeyValueRow(label: "Residues", value: "\(result.residues)")
                        KeyValueRow(label: "Atoms", value: "\(result.atoms)")
                        KeyValueRow(label: "Chains", value: "\(result.chains)")
                        KeyValueRow(label: "Seed", value: "\(job.seed)")
                        KeyValueRow(label: "Samples", value: "\(job.samples)")
                        if let duration = result.durationS {
                            KeyValueRow(label: "Duration", value: String(format: "%.1f s", duration))
                        }
                    }
                }
            }
            .frame(width: 248)
        }
    }

    private func chartsRow(_ result: JobResult) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(
                        title: "Per-residue confidence",
                        subtitle: "pLDDT by residue index",
                        icon: "chart.bar"
                    )
                    PlddtChart(values: result.perResiduePlddt)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(
                        title: "Predicted aligned error",
                        subtitle: result.paeNote ?? "Expected position error",
                        icon: "square.grid.3x3"
                    )
                    PaeHeatmap(matrix: result.pae ?? [])
                }
            }
            .frame(width: 330)
        }
    }

    private func noteCard(_ job: Job, result: JobResult) -> some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    if let note = result.note {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(result.modelName) · runner \(result.modelId) · result format \(result.format.uppercased())")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func export(_ job: Job, format: String) {
        Task {
            exportingFormat = format
            defer { exportingFormat = nil }
            guard let payload = await app.export(jobID: job.id, format: format) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = payload.filename
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let type = UTType(filenameExtension: format) {
                panel.allowedContentTypes = [type]
            }
            if panel.runModal() == .OK, var url = panel.url {
                if url.pathExtension.isEmpty {
                    url.appendPathExtension(format)
                }
                do {
                    try payload.data.write(to: url)
                    app.present("Saved \(url.lastPathComponent).")
                } catch {
                    app.present("Could not save the file: \(error.localizedDescription)")
                }
            }
        }
    }

    private func rerun(_ job: Job) {
        guard let entry = app.catalog.first(where: { $0.runnerId == job.modelId || $0.id == job.modelId }),
              let kind = EntityKind(rawValue: job.entityType) else { return }
        Task {
            _ = await app.submitPrediction(
                modelID: entry.runnerId ?? entry.id,
                entity: kind,
                sequence: job.sequence,
                seed: job.seed,
                samples: job.samples
            )
        }
    }
}

struct JobRow: View {
    let job: Job
    let modelName: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.statusColor(job.status))
                        .frame(width: 6, height: 6)
                    Text(job.name)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(relativeTime(job.createdDate))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    Text(modelName)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(job.sequence.count)\(job.entityType == "ligand" ? "" : " aa")")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(job.status.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.statusColor(job.status))
                }
                if job.isRunning {
                    ProgressView(value: min(100, max(0, job.progress)), total: 100)
                        .tint(Theme.accent)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ExportButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
