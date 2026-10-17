import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app

    private var runnable: [CatalogEntry] {
        app.predictableModels.sorted { ($0.ready ? 0 : 1) < ($1.ready ? 0 : 1) }
    }
    private var reference: [CatalogEntry] { app.catalog.filter { !$0.installable } }
    private var diskUsed: Int { app.status?.storage.reduce(0) { $0 + $1.bytes } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                summary
                if app.catalog.isEmpty {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)).frame(height: 230).shimmering()
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(runnable) { entry in
                            LibraryCard(entry: entry)
                        }
                    }
                }
                if !reference.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("More models on bio.rodeo")
                            .font(.headline)
                        Text("Catalogue entries without a Dimitri runner yet, here for reference.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                            ForEach(reference) { entry in
                                ReferenceCard(entry: entry)
                            }
                        }
                    }
                }
                sources
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1260)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Library")
        .navigationSubtitle("\(runnable.filter(\.ready).count) of \(runnable.count) models ready")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await app.refreshCatalog() }
                } label: {
                    if app.refreshingCatalog {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Catalogue", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .help("Re-read model pages from bio.rodeo")
                .disabled(app.refreshingCatalog)
            }
        }
        .task { await app.refreshStatus() }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)] }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model library")
                .font(.system(size: 28, weight: .bold))
            Text("Install a model once; it runs on this Mac from then on. Loaded models stay warm between jobs so the next run starts at once.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            SummaryTile(icon: "checkmark.seal", title: "Ready", value: "\(runnable.filter(\.ready).count) / \(runnable.count)", caption: "models installed and runnable")
            SummaryTile(icon: "bolt", title: "Loaded now", value: "\(app.workers.count)", caption: app.workers.isEmpty ? "loads on the first job" : app.workers.map { app.shortName(for: $0.runnerId) }.joined(separator: ", "))
            SummaryTile(icon: "internaldrive", title: "On disk", value: diskUsed > 0 ? Format.bytes(diskUsed) : "—", caption: "models, results and cache")
            if let device = app.status?.device {
                SummaryTile(icon: "memorychip", title: device.chip, value: "\(Int(device.memoryGb)) GB", caption: "\(Format.score(device.gpuBudgetGb)) GB usable for models")
            }
        }
    }

    private var sources: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Catalogue: model pages on bio.rodeo (no public API; read from its pages and cached), plus Dimitri's own runner list.")
                if let note = app.catalogSources?.bioRodeo?.note {
                    Text(note).foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if let base = app.catalogSources?.bioRodeo?.baseUrl, let url = URL(string: base) {
                Link("bio.rodeo", destination: url).font(.caption)
            }
        }
        .padding(.top, 4)
    }
}

private struct SummaryTile: View {
    let icon: String
    let title: String
    let value: String
    let caption: String

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct LibraryCard: View {
    @Environment(AppModel.self) private var app
    let entry: CatalogEntry

    private var installJob: JobSummary? {
        app.installJobs.first { $0.modelId == entry.modelID && ($0.isActive || $0.status == "failed") }
    }
    private var installing: Bool { installJob?.isActive == true }
    private var warm: Bool { app.isWarm(entry.modelID) }
    private var status: RunnerStatus? { app.runnerStatus[entry.modelID] }

    var body: some View {
        Card(highlighted: warm) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand)
                            .frame(width: 40, height: 40)
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.title3.weight(.semibold))
                        Text(entry.provider ?? "Independent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    badge
                }

                Text(entry.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ForEach(entry.entityTypes, id: \.self) { type in
                        Chip(text: EntityKind(rawValue: type)?.label ?? type)
                    }
                    Spacer()
                    if let runtime = entry.runtime {
                        Chip(text: runtime, icon: "cpu", tint: .accentColor)
                    }
                }

                if let job = installJob {
                    InstallProgress(job: job)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !entry.ready, let note = entry.weightNote, entry.installed || entry.modelID == "alphafold3-mac" {
                    WeightsNote(entry: entry, note: note)
                }

                Divider()

                HStack(spacing: 8) {
                    primaryAction
                    if warm {
                        Button {
                            Task { await app.release(entry.modelID) }
                        } label: {
                            Label("Unload", systemImage: "eject")
                        }
                        .buttonStyle(SubtleButtonStyle())
                        .help("Free the memory this loaded model is using")
                    }
                    Spacer()
                    if entry.sizeBytes > 0 {
                        Text(Format.bytes(entry.sizeBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let folder = folder {
                        Button {
                            NSWorkspace.shared.open(folder)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show the model's folder in Finder")
                    }
                    if let source = entry.sourceUrl, let url = URL(string: source) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Model page on bio.rodeo")
                    }
                }

                if let detail = status?.detail, !entry.ready, installJob == nil {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .motion(Motion.spring, value: installing)
        .motion(Motion.spring, value: warm)
        .motion(Motion.spring, value: entry.ready)
    }

    private var icon: String {
        switch entry.modelID {
        case "rhofold": return "waveform.path"
        case "alphafold3-mac": return "atom"
        default: return "circle.hexagongrid"
        }
    }

    @ViewBuilder
    private var badge: some View {
        if installing {
            Chip(text: "Installing", icon: "arrow.down.circle", tint: .accentColor)
        } else if warm {
            Chip(text: "Loaded", icon: "bolt.fill", tint: Theme.success)
        } else if entry.ready {
            Chip(text: "Ready", icon: "checkmark.circle.fill", tint: Theme.success)
        } else if entry.installed {
            Chip(text: "Needs weights", icon: "key.fill", tint: Theme.warning)
        } else {
            Chip(text: "Not installed", icon: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if installing {
            Button("Cancel Install") {
                if let job = installJob { Task { await app.cancel(job.id) } }
            }
            .buttonStyle(SubtleButtonStyle())
        } else if entry.ready {
            Button {
                app.draft.modelIDs = [entry.modelID]
                if let first = entry.entityTypes.first, let kind = EntityKind(rawValue: first),
                   !entry.entityTypes.contains(app.draft.entity.rawValue) {
                    app.draft.entity = kind
                }
                withAnimation(Motion.snappy) { app.screen = .predict }
            } label: {
                Label("Use", systemImage: "play.fill")
            }
            .buttonStyle(SubtleButtonStyle(prominent: true))
            Button {
                Task { await app.install(entry) }
            } label: {
                Label("Update", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(SubtleButtonStyle())
            .help("Run setup again to update the model and check its files")
        } else {
            Button {
                Task { await app.install(entry) }
            } label: {
                Label(entry.installed ? "Finish Setup" : "Install", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var folder: URL? {
        let candidates = [status?.paths["repo"], entry.weightDir].compactMap { $0 }
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct InstallProgress: View {
    @Environment(AppModel.self) private var app
    let job: JobSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.isActive {
                HStack {
                    Text(job.stageMessage ?? "Starting…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer()
                    Text("\(Int(job.progress))%")
                        .font(.caption.monospacedDigit())
                        .contentTransition(.numericText())
                }
                ProgressView(value: job.progress, total: 100)
                    .tint(Color.accentColor)
                    .motion(Motion.gentle, value: job.progress)
            } else {
                Label("Setup failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.failure)
                if let error = job.error {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
                if let hint = job.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

private struct WeightsNote: View {
    let entry: CatalogEntry
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(note).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key.fill").foregroundStyle(Theme.warning)
            }
            .font(.caption)
            if let directory = entry.weightDir {
                HStack(spacing: 8) {
                    Text(directory)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show Folder") {
                        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            if entry.modelID == "alphafold3-mac" {
                Link("AlphaFold 3 model parameter terms", destination: URL(string: "https://github.com/google-deepmind/alphafold3/blob/main/WEIGHTS_TERMS_OF_USE.md")!)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.08)))
    }
}

private struct ReferenceCard: View {
    let entry: CatalogEntry

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.name).font(.callout.weight(.semibold))
                    Spacer()
                    if let source = entry.sourceUrl, let url = URL(string: source) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    }
                }
                Text(entry.provider ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}
