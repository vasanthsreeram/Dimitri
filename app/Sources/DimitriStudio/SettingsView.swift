import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = BackendSettings(
        home: "",
        modelsDir: "",
        resultsDir: "",
        cacheDir: "",
        lmsBaseUrl: "http://localhost:1234/v1",
        af3Repo: "",
        af3WeightsDir: "",
        rhofoldRepo: "",
        openfold3Repo: "",
        openfold3Cache: "",
        bioRodeoCacheHours: 24
    )
    @State private var loaded = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 18, weight: .bold))
                    Text("Storage, backend and LM Studio")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    storageSection
                    backendSection
                    lmStudioSection
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("Path changes apply to new jobs and model installs.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button {
                    Task {
                        saveError = nil
                        if await app.saveSettings(draft) {
                            dismiss()
                        } else {
                            saveError = app.banner
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if app.savingSettings {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Save")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!loaded || app.savingSettings)
                .opacity(loaded && !app.savingSettings ? 1 : 0.45)
            }
            .padding(16)
        }
        .frame(width: 640, height: 660)
        .background(Theme.canvas)
        .task(id: app.settings != nil) {
            if let settings = app.settings {
                draft = settings
                loaded = true
            }
        }
    }

    private var storageSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(
                    title: "Storage",
                    subtitle: "Everything stays on this Mac. Weights are never committed.",
                    icon: "internaldrive"
                )
                pathField("Models", text: $draft.modelsDir)
                pathField("Results", text: $draft.resultsDir)
                pathField("Cache", text: $draft.cacheDir)

                DisclosureGroup("Runner paths") {
                    VStack(spacing: 10) {
                        pathField("AlphaFold 3 checkout", text: $draft.af3Repo)
                        pathField("AlphaFold 3 weights", text: $draft.af3WeightsDir)
                        pathField("RhoFold checkout", text: $draft.rhofoldRepo)
                        pathField("OpenFold3 checkout", text: $draft.openfold3Repo)
                        pathField("OpenFold3 parameters", text: $draft.openfold3Cache)
                    }
                    .padding(.top, 10)
                }
                .font(.system(size: 11, weight: .medium))

                if let status = app.status {
                    VStack(spacing: 5) {
                        ForEach(status.storage) { usage in
                            HStack {
                                Text((usage.path as NSString).lastPathComponent)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatBytes(usage.bytes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var backendSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Backend", subtitle: "Local FastAPI process", icon: "server.rack")
                HStack(spacing: 7) {
                    Circle()
                        .fill(app.connected ? Theme.accent : Theme.danger)
                        .frame(width: 7, height: 7)
                    Text(app.connected ? "Running" : "Offline")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Re-check") {
                        Task { await app.refreshAll() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if let status = app.status {
                    KeyValueRow(label: "Endpoint", value: "http://127.0.0.1:8642")
                    KeyValueRow(label: "Version", value: status.version)
                    KeyValueRow(label: "Python", value: status.python)
                    KeyValueRow(label: "Platform", value: status.platform)
                    if let source = app.catalogSources?.bioRodeo {
                        KeyValueRow(
                            label: "bio.rodeo",
                            value: source.api == nil ? "HTML adapter (no API)" : "API"
                        )
                    }
                } else {
                    Text(app.connectionDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var lmStudioSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(
                    title: "LM Studio",
                    subtitle: "Status only. Dimitri does not call an LLM.",
                    icon: "bubble.left.and.text.bubble.right"
                )
                HStack(spacing: 8) {
                    TextField("http://localhost:1234/v1", text: $draft.lmsBaseUrl)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Check") {
                        Task {
                            saveError = nil
                            if await app.saveSettings(draft) {
                                await app.refreshAll(quiet: true)
                            } else {
                                saveError = app.banner
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if let lm = app.status?.lmStudio {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(lm.reachable ? Theme.accent : .secondary)
                            .frame(width: 6, height: 6)
                        Text(lm.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if !lm.models.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(lm.models.prefix(6), id: \.self) { model in
                                TagChip(text: model)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func pathField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5, design: .monospaced))
            Button {
                chooseDirectory { path in text.wrappedValue = path }
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func chooseDirectory(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}
