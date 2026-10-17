import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel

    private var installedCount: Int {
        app.catalog.filter { $0.installed }.count
    }

    private var readyCount: Int {
        app.catalog.filter { $0.ready }.count
    }

    private var totalDisk: Int {
        app.status?.storage.reduce(0) { $0 + $1.bytes } ?? 0
    }

    private var af3: CatalogEntry? {
        app.catalog.first(where: { $0.id == "alphafold3-mac" })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryRow
                if let af3, !af3.ready {
                    weightRequestBanner(af3)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 335), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(app.catalog) { entry in
                        CatalogCard(
                            entry: entry,
                            status: app.statusEntry(for: entry),
                            installJob: app.installJob(for: entry),
                            onInstall: { Task { await app.install(entry) } },
                            onCancel: {
                                if let job = app.installJob(for: entry) {
                                    Task { await app.cancel(jobID: job.id) }
                                }
                            }
                        )
                    }
                }
                sourcesFooter
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Model library")
                    .font(.system(size: 26, weight: .bold))
                Text("Browse structure models, install a runner, and see what is on disk.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await app.refreshCatalog() }
            } label: {
                HStack(spacing: 6) {
                    if app.refreshingCatalog {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text("Refresh catalog")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(app.refreshingCatalog)
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            summaryCard(
                title: "Catalogue",
                value: "\(app.catalog.count)",
                caption: "\(installedCount) installed · \(readyCount) ready"
            )
            summaryCard(
                title: "Disk used",
                value: formatBytes(totalDisk),
                caption: "Models, results and cache"
            )
            summaryCard(
                title: "Source",
                value: "bio.rodeo",
                caption: "\(app.catalogSources?.bioRodeo?.entries ?? 0) matching models"
            )
            if let status = app.status {
                summaryCard(
                    title: "LM Studio",
                    value: status.lmStudio.reachable ? "Online" : "Offline",
                    caption: status.lmStudio.reachable
                        ? "\(status.lmStudio.models.count) local models"
                        : "Status only · port 1234"
                )
            }
        }
    }

    private func summaryCard(title: String, value: String, caption: String) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func weightRequestBanner(_ entry: CatalogEntry) -> some View {
        Card(padding: 15) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 5) {
                    Text("AlphaFold 3 needs DeepMind's weights")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(entry.weightNote ?? "Request access, then place af3.bin.zst in the weights directory.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let directory = entry.weightDir {
                        Text(directory)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if let requestURL = entry.weightRequestUrl, let url = URL(string: requestURL) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Request weights", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var sourcesFooter: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catalog sources")
                        .font(.system(size: 11, weight: .semibold))
                    if let source = app.catalogSources?.bioRodeo {
                        Text(
                            "bio.rodeo · \(source.mode ?? "snapshot")"
                                + (source.api == nil ? " · no public API" : " · API")
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        if let note = source.note {
                            Text(note)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Local runner metadata from backend/dimitri/catalog/models.json")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let base = app.catalogSources?.bioRodeo?.baseUrl, let url = URL(string: base) {
                    Button("bio.rodeo") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}

struct CatalogCard: View {
    let entry: CatalogEntry
    let status: RunnerStatus?
    let installJob: Job?
    let onInstall: () -> Void
    let onCancel: () -> Void

    private var badge: (text: String, color: Color) {
        if entry.ready { return ("Ready", Theme.accent) }
        if entry.installed { return ("Weights needed", Theme.amber) }
        if entry.installable { return ("Not installed", .secondary) }
        return ("Catalog only", .secondary)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text(entry.provider ?? "Independent")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(text: badge.text, color: badge.color, filled: true)
                }

                Text(entry.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if !entry.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(entry.tags.prefix(4), id: \.self) { tag in
                            TagChip(text: tag)
                        }
                        Spacer()
                    }
                }

                HStack(spacing: 10) {
                    if let license = entry.license {
                        Label(license, systemImage: "doc.badge.gearshape")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    if let openness = entry.openness {
                        Label("\(openness)/100 open", systemImage: "lock.open")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if entry.sizeBytes > 0 {
                        Text(formatBytes(entry.sizeBytes))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                if let installJob {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(installJob.stages.first?.message ?? "Installing…")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(installJob.progress))%")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ProgressView(value: installJob.progress, total: 100)
                            .tint(Theme.accent)
                        Button("Cancel install") { onCancel() }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    if entry.installable {
                        Button {
                            onInstall()
                        } label: {
                            Label(
                                entry.ready ? "Re-check" : (entry.installed ? "Finish setup" : "Install"),
                                systemImage: entry.ready ? "checkmark.circle" : "arrow.down.circle"
                            )
                        }
                        .buttonStyle(AdaptiveButtonStyle(primary: !entry.ready))
                        .disabled(installJob != nil)
                    }

                    if let sourceURL = entry.sourceUrl, let url = URL(string: sourceURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("bio.rodeo", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Spacer()

                    if let directory = openableDirectory {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Open model folder")
                    }
                }

                if !entry.installable {
                    Text("A Dimitri runner for this model is not available yet. The catalog entry is here for comparison.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else if let detail = status?.detail, !entry.ready {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var openableDirectory: String? {
        if let dir = entry.weightDir, FileManager.default.fileExists(atPath: dir) {
            return dir
        }
        if let repo = status?.paths["repo"], FileManager.default.fileExists(atPath: repo) {
            return repo
        }
        return nil
    }
}
