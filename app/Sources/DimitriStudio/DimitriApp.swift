import AppKit
import SwiftUI

@main
struct DimitriStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Dimitri Studio", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            DimitriCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

extension AppModel {
    /// One model for the window, the menus and files opened from Finder.
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`; harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Automation.startIfRequested(AppModel.shared)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.open(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stops the backend this app started (and with it any loaded models).
        MainActor.assumeIsolated {
            AppModel.shared.backend.stop()
        }
    }
}

struct DimitriCommands: Commands {
    let model: AppModel

    private var selected: JobSummary? { model.selectedSummary }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Prediction") {
                model.draft = PredictionDraft(seed: model.draft.seed, samples: model.draft.samples)
                model.reconcileDraftModels()
                withAnimation(Motion.snappy) { model.screen = .predict }
            }
            .keyboardShortcut("n")
            Button("Open…") { model.openPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .saveItem) {
            Menu("Export") {
                Button("mmCIF…") { if let id = selected?.id { model.export(id, format: "cif") } }
                    .keyboardShortcut("e")
                Button("PDB…") { if let id = selected?.id { model.export(id, format: "pdb") } }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Confidence JSON…") { if let id = selected?.id { model.export(id, format: "json") } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            .disabled(selected?.isCompleted != true)
            Button("Save Structure Image…") { model.requestSnapshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(selected?.isCompleted != true || model.screen != .results)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Screen.allCases) { screen in
                Button(screen.title) {
                    withAnimation(Motion.snappy) { model.screen = screen }
                }
                .keyboardShortcut(screen.shortcut)
            }
            Divider()
        }

        CommandMenu("Job") {
            Button("Run Prediction") { Task { await model.submit() } }
                .keyboardShortcut(.return)
                .disabled(model.screen != .predict || !model.canSubmit)
            Button("Run Again") { if let id = selected?.id { Task { await model.rerun(id) } } }
                .keyboardShortcut("r")
                .disabled(selected?.kind != "predict" || selected?.isActive == true)
            Button("Edit Input in Predict") { if let id = selected?.id { Task { await model.reuseInput(id) } } }
                .keyboardShortcut("i")
                .disabled(selected == nil || selected?.isImport == true)
            Button("Compare Models") {
                withAnimation(Motion.snappy) { model.compareMode.toggle() }
            }
            .keyboardShortcut("k")
            .disabled(selected.map { model.siblings(of: $0).isEmpty } ?? true)
            Divider()
            Button("Cancel Job") { if let id = selected?.id { Task { await model.cancel(id) } } }
                .keyboardShortcut(".")
                .disabled(selected?.isActive != true)
            Button("Delete Job") { model.confirmDelete = true }
                .keyboardShortcut(.delete)
                .disabled(selected == nil || selected?.isActive == true)
        }

        CommandGroup(replacing: .help) {
            Link("Dimitri Studio on GitHub", destination: URL(string: "https://github.com/vasanthsreeram/Dimitri")!)
            Link("rhofold-mac", destination: URL(string: "https://github.com/vasanthsreeram/rhofold-mac")!)
            Divider()
            Button("Show Backend Log") { NSWorkspace.shared.open(model.backend.logURL) }
            Button("Show Welcome Guide") { model.showOnboarding = true }
        }
    }
}
