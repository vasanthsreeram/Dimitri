import AppKit
import SwiftUI
import WebKit

/// Scripted runs and window snapshots for development, screenshots and
/// end-to-end checks. Inactive unless DIMITRI_UI_SCRIPT is set, e.g.
///
///   DIMITRI_UI_SCRIPT="wait-ready,screen:library,snap:library,example:6tb7,submit,wait-job,snap:result,quit"
///   DIMITRI_UI_SNAPSHOT_DIR=/tmp/shots
///
/// The app captures its own window (no Screen Recording permission needed),
/// compositing the Mol* view from WKWebView's own snapshot.
@MainActor
enum Automation {
    static func startIfRequested(_ app: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let script = environment["DIMITRI_UI_SCRIPT"], !script.isEmpty else { return }
        let directory = URL(fileURLWithPath: environment["DIMITRI_UI_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let steps = script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { await run(steps, app: app, directory: directory) }
    }

    private static func log(_ message: String, _ directory: URL) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        let url = directory.appendingPathComponent("automation.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func run(_ steps: [String], app: AppModel, directory: URL) async {
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let command = parts[0]
            let argument = parts.count > 1 ? parts[1] : ""
            log("step \(step)", directory)
            switch command {
            case "wait-ready":
                await waitUntil(seconds: 600) { app.backend.isReady && app.connected && !app.catalog.isEmpty }
                try? await Task.sleep(for: .seconds(1))
            case "screen":
                if let screen = Screen(rawValue: argument) {
                    withAnimation(Motion.snappy) { app.screen = screen }
                }
                try? await Task.sleep(for: .seconds(1.2))
            case "example":
                if let example = SequenceExample.all.first(where: { $0.id == argument }) {
                    app.draft.sequence = example.sequence
                    app.draft.entity = example.entity
                    app.draft.entityPinned = false
                    app.draft.modelsPinned = false
                    app.draft.name = example.title.components(separatedBy: " (").first ?? example.title
                    app.reconcileDraftModels()
                }
                try? await Task.sleep(for: .seconds(0.8))
            case "model":
                app.draft.modelIDs = argument.split(separator: "+").map(String.init)
                app.draft.modelsPinned = true
                try? await Task.sleep(for: .seconds(0.5))
            case "submit":
                await app.submit()
            case "wait-job":
                await waitUntil(seconds: 900) { app.selectedSummary?.isTerminal == true }
                try? await Task.sleep(for: .seconds(3))
            case "wait-viewer":
                await waitUntil(seconds: 60) {
                    if case .loaded = app.viewer.state { return true }
                    if case .failed = app.viewer.state { return true }
                    return false
                }
                try? await Task.sleep(for: .seconds(1.5))
            case "open":
                app.open([URL(fileURLWithPath: argument)])
                try? await Task.sleep(for: .seconds(3))
            case "select-model":
                if let job = app.predictions.first(where: { $0.modelId == argument }) {
                    app.select(job.id)
                }
                try? await Task.sleep(for: .seconds(1.5))
            case "select-latest":
                if let first = app.predictions.first { app.select(first.id) }
                try? await Task.sleep(for: .seconds(1.5))
            case "compare":
                withAnimation { app.compareMode = argument != "off" }
                try? await Task.sleep(for: .seconds(2))
            case "onboarding":
                app.showOnboarding = argument != "off"
                try? await Task.sleep(for: .seconds(1.5))
            case "appearance":
                NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
                try? await Task.sleep(for: .seconds(1))
            case "sleep":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "snap":
                await snapshot(name: argument.isEmpty ? "window" : argument, directory: directory)
            case "report":
                writeReport(app, directory: directory)
            case "quit":
                NSApp.terminate(nil)
            default:
                log("unknown step \(step)", directory)
            }
        }
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The main window as PNG, with web views drawn from their own snapshots.
    static func snapshot(name: String, directory: URL) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }),
              let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        for webView in webViews(in: frameView) where !webView.isHidden && webView.window != nil {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            guard let shot = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            let rect = webView.convert(webView.bounds, to: frameView)
            image.lockFocusFlipped(frameView.isFlipped)
            shot.draw(in: rect)
            image.unlockFocus()
        }

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        log("snapshot \(name).png \(Int(bounds.width))x\(Int(bounds.height))", directory)

        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
           let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
            if let data = sheetRep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("\(name)-sheet.png"))
            }
        }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = view as? WKWebView { found.append(webView) }
        for subview in view.subviews { found += webViews(in: subview) }
        return found
    }

    private static func writeReport(_ app: AppModel, directory: URL) {
        var lines: [String] = []
        lines.append("backend: \(app.backend.baseURL.absoluteString) ready=\(app.backend.isReady) owns=\(app.backend.ownsProcess)")
        if let job = app.selectedSummary {
            lines.append("selected: \(job.name) \(job.modelId) \(job.status) plddt=\(job.plddt.map { String($0) } ?? "-") duration=\(job.durationS.map { String($0) } ?? "-") warm=\(String(describing: job.warm))")
        }
        switch app.viewer.state {
        case .loaded(let report):
            for structure in report.structures {
                lines.append("viewer: \(structure.representation) colour=\(structure.color) residues=\(structure.residues) atoms=\(structure.atoms) polymer=\(structure.polymerTypes.joined(separator: "+")) confidence=\(structure.hasConfidence) ms=\(Int(report.ms))")
            }
        case .failed(let message):
            lines.append("viewer: FAILED \(message)")
        default:
            lines.append("viewer: \(app.viewer.state)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8
        )
        log("report written", directory)
    }
}
