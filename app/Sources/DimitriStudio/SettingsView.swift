import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            BackendSettingsTab()
                .tabItem { Label("Backend", systemImage: "server.rack") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
    }
}

/// Edits a copy of the backend settings and saves on demand.
@MainActor
private func settingsBinding(_ app: AppModel, _ draft: Binding<BackendSettings?>) -> Binding<BackendSettings>? {
    guard draft.wrappedValue != nil else { return nil }
    return Binding(get: { draft.wrappedValue! }, set: { draft.wrappedValue = $0 })
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var draft: BackendSettings?

    private let options: [(String, Int?)] = [
        ("Automatic for this Mac", nil), ("5 minutes", 5), ("15 minutes", 15),
        ("1 hour", 60), ("Until Dimitri quits", -1),
    ]

    var body: some View {
        Form {
            if let binding = settingsBinding(app, $draft) {
                Section {
                    Toggle("Keep models loaded between jobs", isOn: binding.warmWorkers)
                    Picker("Unload an idle model after", selection: binding.keepWarmMinutes) {
                        ForEach(options, id: \.0) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .disabled(!binding.wrappedValue.warmWorkers)
                } header: {
                    Text("Warm models")
                } footer: {
                    Text("A loaded model starts the next job at once (RhoFold+ about 2× faster per job). It holds memory while loaded; Dimitri unloads idle models and never keeps more than this Mac can spare.")
                }
                if let device = app.status?.device {
                    Section("This Mac") {
                        LabeledContent("Chip", value: device.chip)
                        LabeledContent("Memory", value: "\(Int(device.memoryGb)) GB unified")
                        LabeledContent("Profile", value: device.tierLabel)
                        LabeledContent("GPU budget for models", value: "\(Format.score(device.gpuBudgetGb)) GB")
                        LabeledContent("MLX buffer cache", value: "\(Format.score(device.mlxCacheLimitGb)) GB")
                        ForEach(device.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(draft == app.settings)
                    }
                }
            } else {
                ProgressView("Waiting for the backend…")
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = app.settings }
        .onChange(of: app.settings) { draft = app.settings }
    }

    private func save() {
        guard let draft else { return }
        Task {
            if await app.saveSettings(draft) { app.present(.success, "Settings saved") }
        }
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var draft: BackendSettings?

    var body: some View {
        Form {
            if let binding = settingsBinding(app, $draft) {
                Section {
                    PathRow(label: "Models", path: binding.modelsDir)
                    PathRow(label: "Results", path: binding.resultsDir)
                    PathRow(label: "Cache", path: binding.cacheDir)
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Everything stays on this Mac. Weights and results are never uploaded or committed anywhere.")
                }
                Section("Model checkouts") {
                    PathRow(label: "rhofold-mac", path: binding.rhofoldRepo)
                    PathRow(label: "mac-af3", path: binding.macAf3Repo)
                    PathRow(label: "alphafold3-mac", path: binding.af3Repo)
                    PathRow(label: "AlphaFold 3 weights", path: binding.af3WeightsDir)
                    PathRow(label: "OpenFold3", path: binding.openfold3Repo)
                    PathRow(label: "OpenFold3 parameters", path: binding.openfold3Cache)
                }
                if let storage = app.status?.storage {
                    Section("Disk use") {
                        ForEach(storage) { usage in
                            LabeledContent((usage.path as NSString).lastPathComponent.capitalized, value: Format.bytes(usage.bytes))
                        }
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Save") {
                            guard let draft else { return }
                            Task { if await app.saveSettings(draft) { app.present(.success, "Settings saved") } }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft == app.settings)
                    }
                }
            } else {
                ProgressView("Waiting for the backend…")
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = app.settings }
        .onChange(of: app.settings) { draft = app.settings }
    }
}

private struct PathRow: View {
    let label: String
    @Binding var path: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(path)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path)
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
                .controlSize(.small)
            }
        }
    }
}

private struct BackendSettingsTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Local backend") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(app.connected ? Theme.success : Theme.warning).frame(width: 8, height: 8)
                        Text(app.connected ? "Running" : "Not connected")
                    }
                }
                LabeledContent("Address", value: app.backend.baseURL.absoluteString)
                LabeledContent("Started by", value: app.backend.ownsProcess ? "Dimitri Studio (stops when you quit)" : "Another process (left running on quit)")
                if let status = app.status {
                    LabeledContent("Version", value: status.version)
                    LabeledContent("Python", value: status.python)
                }
                HStack {
                    Button("Restart Backend") { app.backend.restart() }
                    Button("Show Log") { NSWorkspace.shared.open(app.backend.logURL) }
                }
            }
            Section("Loaded models") {
                if app.workers.isEmpty {
                    Text("No model is loaded. The first job loads one; it stays warm until idle.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.workers) { worker in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text("\(worker.state) · \(worker.jobsServed) job\(worker.jobsServed == 1 ? "" : "s")\(worker.rssMb.map { " · \(Format.score($0 / 1024, digits: 1)) GB" } ?? "")")
                                .foregroundStyle(.secondary)
                            Button("Unload") { Task { await app.release(worker.runnerId) } }
                                .controlSize(.small)
                        }
                    } label: {
                        Text(app.shortName(for: worker.runnerId))
                    }
                }
            }
            Section {
                LabeledContent("LM Studio") {
                    HStack(spacing: 6) {
                        Circle().fill(app.status?.lmStudio.reachable == true ? Theme.success : Color.secondary).frame(width: 8, height: 8)
                        Text(app.status?.lmStudio.reachable == true ? "Running (\(app.status?.lmStudio.models.count ?? 0) models)" : "Not running")
                    }
                }
                Button("Check Again") { Task { await app.refreshStatus(lmStudio: true) } }
            } header: {
                Text("LM Studio")
            } footer: {
                Text("Status only. Dimitri does not send anything to a language model.")
            }
        }
        .formStyle(.grouped)
        .task { await app.refreshStatus() }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            LogoMark(size: 76)
            Text("Dimitri Studio")
                .font(.title.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")")
                .foregroundStyle(.secondary)
            Text("Local structure prediction for researchers on Apple Silicon.")
                .font(.callout)
            Divider().frame(width: 300)
            VStack(alignment: .leading, spacing: 5) {
                credit("AlphaFold 3", "Abramson et al., Nature 2024 · runtime mac-af3 on alphafold3-mac")
                credit("RhoFold+", "Shen et al., Nature Methods 2024 · runtime rhofold-mac")
                credit("OpenFold3", "AlQuraishi Lab · openfold-3-mlx")
                credit("Mol*", "Sehnal et al., NAR 2021 · MIT licence")
                credit("gemmi", "Wojdyr, JOSS 2022 · MPL 2.0")
            }
            .font(.caption)
            Link("github.com/vasanthsreeram/Dimitri", destination: URL(string: "https://github.com/vasanthsreeram/Dimitri")!)
                .font(.caption)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).fontWeight(.semibold).frame(width: 90, alignment: .trailing)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
