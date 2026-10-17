// Offline check of the bundled structure viewer.
//
// Run it through scripts/viewer-check.sh, which compiles this file together
// with the app's MolStarView.swift, so the check drives the same controller,
// page and message bridge as the app:
//
//   scripts/viewer-check.sh [options] <structure>[@colour] [<structure> ...]
//
// It opens the viewer in an offscreen window with every network request
// blocked and a monitor on the page's network APIs, loads the structures
// (several are overlaid in one view), waits for the 'loaded' report, saves a
// WKWebView snapshot and Mol*'s own render as PNGs, and checks that the
// pixels are not blank and, for pLDDT colouring, that they fall in the pLDDT
// band colours. Optional follow-up steps recolour, change theme, load other
// structures and kill the web content process, each checked the same way.
//
// A structure may carry its own colour: `model.pdb@plddt`, `ref.cif@uniform:#9AA4B2`.
//
// Options:
//   --viewer DIR           viewer page (default: app/Sources/DimitriStudio/Resources/Viewer)
//   --format pdb|mmcif     declared format for every structure (default: from the extension)
//   --color MODE           plddt | chain | secondary | rainbow | uniform (default: plddt)
//   --theme light|dark     (default: dark)
//   --size WxH             viewport in points (default: 900x640)
//   --out FILE.png         WKWebView snapshot (default: viewer-check.png); Mol*'s render
//                          goes to FILE.molstar.png and steps to FILE.stepN-….png
//   --expect-confidence yes|no
//   --expect-color MODE    colour mode the viewer must report for every structure
//   --expect-polymer KIND  protein | rna | dna (repeatable)
//   --expect-representation NAME   e.g. cartoon: every structure's representation starts with it
//   --expect-helix         at least one helical residue
//   --then-color MODE      recolour in place (no page reload)
//   --then-theme THEME     switch light/dark (no page reload)
//   --then-load A[,B…]     show other structures in the running page (no page reload)
//   --then-crash           kill the web content process; the viewer must recover
//   --legacy MOLSTAR_JS    instead of the bundled page, reproduce the phase-1 page:
//                          the old inline HTML (base64 text, auto preset, no CSS),
//                          with this local molstar.js in place of the CDN copy
//   --timeout SECONDS      (default: 90)

import AppKit
import WebKit

// MARK: - Options

/// `path`, `path@MODE` or `path@uniform:#RRGGBB`.
struct StructureArgument {
    let url: URL
    var color: ViewerColorMode?
    var uniformColor: String?

    init(_ text: String) {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        url = URL(fileURLWithPath: parts[0])
        guard parts.count == 2 else { return }
        let spec = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        guard let mode = ViewerColorMode(rawValue: spec[0]) else { usage("unknown colour in \(text)") }
        color = mode
        uniformColor = spec.count == 2 ? spec[1] : nil
    }
}

enum Step {
    case color(ViewerColorMode)
    case theme(ViewerTheme)
    case load([StructureArgument])
    case crash

    var name: String {
        switch self {
        case .color(let mode): return "color-\(mode.rawValue)"
        case .theme(let theme): return "theme-\(theme.rawValue)"
        case .load: return "load"
        case .crash: return "crash"
        }
    }
}

struct Options {
    var viewer = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("app/Sources/DimitriStudio/Resources/Viewer")
    var files: [StructureArgument] = []
    var format: ViewerStructure.Format?
    var color: ViewerColorMode = .plddt
    var theme: ViewerTheme = .dark
    var size = CGSize(width: 900, height: 640)
    var out = URL(fileURLWithPath: "viewer-check.png")
    var expectConfidence: Bool?
    var expectColor: String?
    var expectPolymers: [String] = []
    var expectRepresentation: String?
    var expectHelix = false
    var steps: [Step] = []
    var legacyMolstar: URL?
    var timeout: TimeInterval = 90

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func value(_ flag: String) -> String {
            guard let next = iterator.next() else { usage("\(flag) needs a value") }
            return next
        }
        func mode(_ text: String) -> ViewerColorMode {
            guard let mode = ViewerColorMode(rawValue: text) else { usage("unknown colour mode \(text)") }
            return mode
        }
        func theme(_ text: String) -> ViewerTheme {
            guard let theme = ViewerTheme(rawValue: text) else { usage("unknown theme \(text)") }
            return theme
        }
        while let argument = iterator.next() {
            switch argument {
            case "--viewer": options.viewer = URL(fileURLWithPath: value(argument))
            case "--format":
                guard let format = ViewerStructure.Format(value(argument)) else { usage("unknown format") }
                options.format = format
            case "--color": options.color = mode(value(argument))
            case "--theme": options.theme = theme(value(argument))
            case "--size":
                let parts = value(argument).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { usage("--size takes WxH") }
                options.size = CGSize(width: parts[0], height: parts[1])
            case "--out": options.out = URL(fileURLWithPath: value(argument))
            case "--expect-confidence": options.expectConfidence = ["yes", "true", "1"].contains(value(argument))
            case "--expect-color": options.expectColor = value(argument)
            case "--expect-polymer": options.expectPolymers.append(value(argument))
            case "--expect-representation": options.expectRepresentation = value(argument)
            case "--expect-helix": options.expectHelix = true
            case "--then-color": options.steps.append(.color(mode(value(argument))))
            case "--then-theme": options.steps.append(.theme(theme(value(argument))))
            case "--then-load":
                options.steps.append(.load(value(argument).split(separator: ",").map { StructureArgument(String($0)) }))
            case "--then-crash": options.steps.append(.crash)
            case "--legacy": options.legacyMolstar = URL(fileURLWithPath: value(argument))
            case "--timeout": options.timeout = TimeInterval(value(argument)) ?? options.timeout
            case "-h", "--help": usage(nil)
            default:
                if argument.hasPrefix("--") { usage("unknown option \(argument)") }
                options.files.append(StructureArgument(argument))
            }
        }
        if options.files.isEmpty { usage("no structure files given") }
        return options
    }
}

func usage(_ problem: String?) -> Never {
    if let problem { FileHandle.standardError.write(Data("viewer-check: \(problem)\n".utf8)) }
    print("usage: scripts/viewer-check.sh [--color MODE] [--theme light|dark] [--out FILE.png] [--expect-…] [--then-…] <structure>[@colour]…")
    exit(2)
}

// MARK: - Pixels

struct PixelStats {
    var width = 0
    var height = 0
    var background = "#000000"
    /// Pixels that differ clearly from the background.
    var foreground = 0
    var foregroundFraction = 0.0
    /// Foreground pixels whose hue matches each pLDDT band.
    var bands: [(String, Int)] = []
    var bandFraction = 0.0
    /// Separate foreground blobs of at least 12 pixels: one connected cartoon
    /// gives a handful, unbonded atoms give many.
    var blobs = 0
    var largestBlobFraction = 0.0
}

/// pLDDT bands by hue (degrees), which survives Mol*'s lighting better than RGB distance.
let bandHues: [(name: String, hex: String, hue: ClosedRange<Double>)] = [
    ("very high #0053D6", "#0053D6", 207...232),
    ("confident #65CBF3", "#65CBF3", 185...206.99),
    ("low #FFDB13", "#FFDB13", 40...62),
    ("very low #FF7D45", "#FF7D45", 6...32),
]

func analyse(_ image: CGImage) -> PixelStats {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // The background is the most common colour on a ring just inside the edge.
    var counts: [UInt32: Int] = [:]
    func key(_ i: Int) -> UInt32 {
        UInt32(pixels[i * 4]) << 16 | UInt32(pixels[i * 4 + 1]) << 8 | UInt32(pixels[i * 4 + 2])
    }
    let inset = min(6, width / 4, height / 4)
    for x in inset..<(width - inset) {
        counts[key(inset * width + x), default: 0] += 1
        counts[key((height - 1 - inset) * width + x), default: 0] += 1
    }
    for y in inset..<(height - inset) {
        counts[key(y * width + inset), default: 0] += 1
        counts[key(y * width + width - 1 - inset), default: 0] += 1
    }
    let background = counts.max { $0.value < $1.value }?.key ?? 0
    let bg = (Int(background >> 16), Int((background >> 8) & 0xFF), Int(background & 0xFF))

    var stats = PixelStats()
    stats.width = width
    stats.height = height
    stats.background = String(format: "#%06X", background)
    var mask = [Bool](repeating: false, count: width * height)
    var bandCounts = [Int](repeating: 0, count: bandHues.count)
    for i in 0..<(width * height) {
        let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
        guard max(abs(r - bg.0), abs(g - bg.1), abs(b - bg.2)) > 28 else { continue }
        mask[i] = true
        stats.foreground += 1
        let maxC = Double(max(r, g, b)), minC = Double(min(r, g, b))
        guard maxC > 40, (maxC - minC) / maxC > 0.25 else { continue }
        let delta = maxC - minC
        var hue: Double
        if maxC == Double(r) {
            hue = 60 * ((Double(g) - Double(b)) / delta)
        } else if maxC == Double(g) {
            hue = 60 * ((Double(b) - Double(r)) / delta) + 120
        } else {
            hue = 60 * ((Double(r) - Double(g)) / delta) + 240
        }
        if hue < 0 { hue += 360 }
        if let band = bandHues.firstIndex(where: { $0.hue.contains(hue) }) {
            bandCounts[band] += 1
        }
    }
    stats.foregroundFraction = Double(stats.foreground) / Double(width * height)
    stats.bands = zip(bandHues, bandCounts).map { ($0.0.name, $0.1) }
    stats.bandFraction = stats.foreground > 0 ? Double(bandCounts.reduce(0, +)) / Double(stats.foreground) : 0

    // Connected foreground blobs (4-neighbour flood fill).
    var seen = [Bool](repeating: false, count: width * height)
    var stack: [Int] = []
    var largest = 0
    for start in 0..<(width * height) where mask[start] && !seen[start] {
        var size = 0
        seen[start] = true
        stack.append(start)
        while let i = stack.popLast() {
            size += 1
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let j = ny * width + nx
                if mask[j] && !seen[j] {
                    seen[j] = true
                    stack.append(j)
                }
            }
        }
        if size >= 12 { stats.blobs += 1 }
        largest = max(largest, size)
    }
    stats.largestBlobFraction = stats.foreground > 0 ? Double(largest) / Double(stats.foreground) : 0
    return stats
}

func describe(_ stats: PixelStats, label: String) -> String {
    var lines = [
        "  \(label): \(stats.width)x\(stats.height) px, background \(stats.background)",
        String(format: "    foreground %d px (%.1f%% of the image), %d blobs, largest blob %.0f%% of foreground",
               stats.foreground, stats.foregroundFraction * 100, stats.blobs, stats.largestBlobFraction * 100),
    ]
    let bandText = stats.bands.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
    lines.append(String(format: "    pLDDT band pixels (%.0f%% of foreground): ", stats.bandFraction * 100) + bandText)
    return lines.joined(separator: "\n")
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "viewer-check", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

func cgImage(fromPNG data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - WebKit helpers

/// Blocks every request that is not to a local file, so the check proves the
/// viewer needs no network.
@MainActor
func offlineRules() async throws -> WKContentRuleList {
    let store = WKContentRuleListStore(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("dimitri-viewer-check-rules")
    )!
    // WebKit's rule regexes have no alternation, hence one rule per scheme.
    let rules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
    """
    return try await withCheckedThrowingContinuation { continuation in
        store.compileContentRuleList(forIdentifier: "offline", encodedContentRuleList: rules) { list, error in
            if let list {
                continuation.resume(returning: list)
            } else {
                continuation.resume(throwing: error ?? NSError(domain: "viewer-check", code: 2))
            }
        }
    }
}

/// Records, from the first line of the page on, every attempt to reach a URL
/// that is not a local file (fetch, XHR, WebSocket, EventSource, beacons, and
/// src/href on elements added later). Read back as `window.__networkAttempts`.
let networkMonitorJS = """
(() => {
  const attempts = [];
  window.__networkAttempts = attempts;
  const local = /^(file|data|blob|about|javascript):/i;
  const note = (kind, url) => {
    try {
      const text = String(url && url.url ? url.url : url);
      const absolute = new URL(text, document.baseURI).href;
      if (!local.test(absolute)) attempts.push(kind + ' ' + absolute);
    } catch (e) { attempts.push(kind + ' ' + String(url)); }
  };
  const fetch0 = window.fetch;
  window.fetch = function (input, init) { note('fetch', input); return fetch0.apply(this, arguments); };
  const open0 = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) { note('xhr', url); return open0.apply(this, arguments); };
  const WebSocket0 = window.WebSocket;
  window.WebSocket = function (url, protocols) { note('websocket', url); return new WebSocket0(url, protocols); };
  const EventSource0 = window.EventSource;
  if (EventSource0) window.EventSource = function (url, config) { note('eventsource', url); return new EventSource0(url, config); };
  if (navigator.sendBeacon) {
    const beacon0 = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = (url, data) => { note('beacon', url); return beacon0(url, data); };
  }
  new MutationObserver((records) => {
    for (const record of records) {
      const nodes = record.type === 'attributes' ? [record.target] : Array.from(record.addedNodes);
      for (const node of nodes) {
        if (node.nodeType !== 1) continue;
        for (const attribute of ['src', 'href', 'poster', 'data']) {
          const value = node.getAttribute && node.getAttribute(attribute);
          if (value) note(node.tagName.toLowerCase() + '.' + attribute, value);
        }
      }
    }
  }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'href', 'poster', 'data'] });
})();
"""

@MainActor
func installNetworkMonitor(on webView: WKWebView) {
    let script = WKUserScript(source: networkMonitorJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    webView.configuration.userContentController.addUserScript(script)
}

@MainActor
func makeWindow(for view: NSView, size: CGSize) -> NSWindow {
    // WebKit stops painting web views whose window is occluded, and a window
    // off every screen counts as occluded. Turn that detection off (check-only
    // SPI; a nil argument is NO) so the offscreen page renders like a visible one.
    let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    if view.responds(to: occlusion) {
        _ = view.perform(occlusion, with: nil)
    }
    // Off every screen, but ordered in.
    let window = NSWindow(
        contentRect: NSRect(x: -12000, y: -12000, width: size.width, height: size.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    return window
}

/// Resumes once, with the first of a reply or a timeout: a web view whose
/// content process is gone may never answer.
@MainActor
final class Reply<Value> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>, timeout: TimeInterval, fallback: Value) {
        self.continuation = continuation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.resume(fallback)
        }
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
func takeSnapshot(of webView: WKWebView, timeout: TimeInterval = 20) async -> CGImage? {
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
        let reply = Reply(continuation, timeout: timeout, fallback: nil)
        webView.takeSnapshot(with: configuration) { image, _ in
            reply.resume(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }
}

@MainActor
func evaluate(_ webView: WKWebView, _ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 20) async -> Any? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
        let reply = Reply<Any?>(continuation, timeout: timeout, fallback: "timed out")
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            switch result {
            case .success(let value): reply.resume(value)
            case .failure(let error): reply.resume("JS error: \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

@MainActor
func waitUntilAsync(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
}

@MainActor
func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
    return text
}

// MARK: - Checks

struct Outcome {
    var failures: [String] = []
    mutating func check(_ condition: Bool, _ message: String) {
        print("  [\(condition ? "ok" : "FAIL")] \(message)")
        if !condition { failures.append(message) }
    }
}

/// Everything the controller reported, in order.
@MainActor
final class EventRecorder {
    var sequence: [String] = []
    var ready = 0
    var loaded = 0
    var report: ViewerLoadReport?
    var failure: String?

    func record(_ event: ViewerEvent) {
        switch event {
        case .ready:
            ready += 1
            sequence.append("ready")
        case .loaded(let report):
            loaded += 1
            self.report = report
            sequence.append("loaded")
        case .failed(let message):
            failure = message
            sequence.append("error")
        case .log(let message):
            print("  [page] \(message)")
        }
    }
}

func makeStructures(_ arguments: [StructureArgument], format: ViewerStructure.Format?, prefix: String) -> [ViewerStructure] {
    arguments.enumerated().map { index, argument in
        let text = (try? String(contentsOf: argument.url, encoding: .utf8)) ?? ""
        return ViewerStructure(
            id: "\(prefix)\(index + 1)",
            text: text,
            format: format ?? ViewerStructure.Format(argument.url.pathExtension) ?? .pdb,
            label: argument.url.lastPathComponent,
            colorMode: argument.color,
            uniformColor: argument.uniformColor
        )
    }
}

/// The colour the viewer should report: pLDDT falls back without confidence.
func expectedColor(_ requested: ViewerColorMode, for structure: ViewerLoadReport.Structure) -> String {
    guard requested == .plddt, !structure.hasConfidence else { return requested.rawValue }
    return structure.polymerTypes.contains("protein") ? "secondary" : "chain"
}

func reportDictionary(_ report: ViewerLoadReport) -> [String: Any] {
    [
        "ms": report.ms,
        "structures": report.structures.map { s -> [String: Any] in
            var item: [String: Any] = [
                "id": s.id, "atoms": s.atoms, "residues": s.residues, "chains": s.chains,
                "polymerTypes": s.polymerTypes, "hasConfidence": s.hasConfidence,
                "color": s.color, "representation": s.representation,
            ]
            item["label"] = s.label
            item["format"] = s.format
            item["models"] = s.models
            item["bonds"] = s.bonds
            item["polymerResidues"] = s.polymerResidues
            item["traceOnly"] = s.traceOnly
            item["confidenceNote"] = s.confidenceNote
            item["plddtRange"] = s.plddtRange
            item["warnings"] = s.warnings
            if let ss = s.secondaryStructure {
                item["secondaryStructure"] = ["helix": ss.helix, "sheet": ss.sheet]
            }
            return item
        },
    ]
}

/// Saves and checks both snapshots of the current view.
@MainActor
func checkSnapshots(
    _ controller: MolStarController,
    report: ViewerLoadReport,
    out: URL,
    background: String?,
    outcome: inout Outcome
) async {
    // WKWebView's own snapshot: what the user would see in the app.
    if let image = await takeSnapshot(of: controller.webView) {
        try? writePNG(image, to: out)
        let stats = analyse(image)
        print("  snapshot: \(out.path)")
        print(describe(stats, label: "WKWebView snapshot"))
        outcome.check(stats.foregroundFraction > 0.005, "WKWebView snapshot is not blank")
        if let background {
            outcome.check(stats.background == background, "background is \(background) (got \(stats.background))")
        }
        if report.structures.contains(where: { $0.color == "plddt" }) {
            outcome.check(stats.bandFraction > 0.25, "most coloured pixels fall in pLDDT bands")
        }
    } else {
        outcome.check(false, "WKWebView produced a snapshot")
    }

    // Mol*'s render through the app's snapshot API ("Save image…").
    let molstarURL = out.deletingPathExtension().appendingPathExtension("molstar.png")
    do {
        let data = try await controller.snapshotPNG()
        try data.write(to: molstarURL)
        if let image = cgImage(fromPNG: data) {
            let stats = analyse(image)
            print("  snapshot: \(molstarURL.path)")
            print(describe(stats, label: "Mol* render (snapshotPNG)"))
            outcome.check(stats.foregroundFraction > 0.005, "Mol* render is not blank")
        }
    } catch {
        outcome.check(false, "snapshotPNG() works: \(error.localizedDescription)")
    }
}

@MainActor
func runBundledViewer(_ options: Options) async -> Bool {
    var outcome = Outcome()
    var structures = makeStructures(options.files, format: options.format, prefix: "s")
    var colorMode = options.color
    var theme = options.theme
    let backgrounds: [ViewerTheme: String] = [.dark: "#0D1117", .light: "#FFFFFF"]

    let controller = MolStarController(viewerDirectory: options.viewer)
    let events = EventRecorder()
    controller.onEvent = { events.record($0) }
    do {
        controller.webView.configuration.userContentController.add(try await offlineRules())
    } catch {
        print("could not compile the offline rules: \(error)")
        return false
    }
    installNetworkMonitor(on: controller.webView)
    let window = makeWindow(for: controller.webView, size: options.size)
    defer { window.close() }

    let started = Date()
    controller.start(theme: theme)
    controller.show(structures, colorMode: colorMode)
    let finished = await waitUntil(options.timeout) { events.report != nil || events.failure != nil }
    print(String(format: "viewer: %@ (%.1f s, events: %@)", options.viewer.path, Date().timeIntervalSince(started),
                 events.sequence.joined(separator: " → ")))
    outcome.check(finished, "viewer answered within \(Int(options.timeout)) s")
    outcome.check(events.failure == nil, "no error message" + (events.failure.map { ": \($0)" } ?? ""))
    guard let report = events.report else {
        return false
    }

    // Let Mol* finish its progressive passes before the snapshot.
    await pause(1.0)

    if let diagnostics = await evaluate(controller.webView, "return await window.dimitri.diagnostics();") as? [String: Any] {
        let resources = diagnostics["resources"] as? [String] ?? []
        print("  Mol* \(diagnostics["version"] ?? "?"), WebGL2: \(diagnostics["webgl2"] ?? "?"), theme: \(diagnostics["theme"] ?? "?")")
        print("  page scripts and styles: " + resources.map { URL(string: $0)?.lastPathComponent ?? $0 }.joined(separator: ", "))
        outcome.check(resources.count >= 4 && resources.allSatisfy { $0.hasPrefix("file:") },
                      "the page's scripts and styles are local files")
    } else {
        outcome.check(false, "window.dimitri.diagnostics() answered")
    }

    print("  report: " + jsonString(reportDictionary(report)))
    for structure in report.structures {
        if let expect = options.expectConfidence {
            outcome.check(structure.hasConfidence == expect, "\(structure.id) hasConfidence == \(expect)")
        }
        if let expect = options.expectColor {
            outcome.check(structure.color == expect, "\(structure.id) colour mode is \(expect) (got \(structure.color))")
        }
        for kind in options.expectPolymers {
            outcome.check(structure.polymerTypes.contains(kind), "\(structure.id) has a \(kind) polymer")
        }
        if let expect = options.expectRepresentation {
            outcome.check(structure.representation.hasPrefix(expect),
                          "\(structure.id) polymer drawn as \(expect) (got \(structure.representation))")
        }
        if options.expectHelix {
            outcome.check((structure.secondaryStructure?.helix ?? 0) > 0,
                          "\(structure.id) has helical residues (\(structure.secondaryStructure?.helix ?? 0))")
        }
    }
    await checkSnapshots(controller, report: report, out: options.out, background: backgrounds[theme], outcome: &outcome)

    for (index, step) in options.steps.enumerated() {
        let stepOut = options.out.deletingPathExtension()
            .appendingPathExtension("step\(index + 1)-\(step.name).png")
        print("step \(index + 1): \(step.name)")
        let readyBefore = events.ready
        let loadedBefore = events.loaded
        switch step {
        case .color(let mode):
            colorMode = mode
            controller.show(structures, colorMode: mode)
            let done = await waitUntil(options.timeout) { events.loaded > loadedBefore || events.failure != nil }
            outcome.check(done && events.failure == nil, "recoloured without an error")
            outcome.check(events.ready == readyBefore, "the page was not reloaded")
            for (structure, input) in zip(events.report?.structures ?? [], structures) {
                let expected = expectedColor(input.colorMode ?? mode, for: structure)
                outcome.check(structure.color == expected, "\(structure.id) colour mode is now \(expected) (got \(structure.color))")
            }
        case .theme(let newTheme):
            theme = newTheme
            controller.setTheme(newTheme)
            await pause(0.8)
            outcome.check(events.ready == readyBefore, "the page was not reloaded")
        case .load(let arguments):
            structures = makeStructures(arguments, format: options.format, prefix: "t")
            controller.show(structures, colorMode: colorMode)
            let done = await waitUntil(options.timeout) { events.loaded > loadedBefore || events.failure != nil }
            outcome.check(done && events.failure == nil, "loaded the new structures without an error")
            outcome.check(events.ready == readyBefore, "the page was not reloaded")
            outcome.check(events.report?.structures.map(\.id) == structures.map(\.id), "the report lists the new structures")
            if let report = events.report {
                print("  report: " + jsonString(reportDictionary(report)))
            }
        case .crash:
            // SIGKILL the page's WebContent process: to WebKit that is a real
            // crash, so the navigation delegate hears about it.
            let pidSelector = NSSelectorFromString("_webProcessIdentifier")
            guard controller.webView.responds(to: pidSelector),
                  let pid = (controller.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
                  pid > 0 else {
                print("  (skipped: WebKit does not expose the WebContent process id here)")
                continue
            }
            print("  killing WebContent process \(pid)")
            kill(pid, SIGKILL)
            let done = await waitUntil(options.timeout) {
                (events.ready > readyBefore && events.loaded > loadedBefore) || events.failure != nil
            }
            outcome.check(done && events.failure == nil, "recovered: page reloaded and structures shown again")
            outcome.check(events.report?.structures.map(\.id) == structures.map(\.id), "the same structures are back")
        }
        await pause(1.0)
        if let report = events.report {
            await checkSnapshots(controller, report: report, out: stepOut, background: backgrounds[theme], outcome: &outcome)
        }
    }

    let attempts = await evaluate(controller.webView, "return window.__networkAttempts || null;") as? [String]
    print("network attempts during the run: " + (attempts.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "monitor missing"))
    outcome.check(attempts?.isEmpty == true, "the page made no network requests (http/https/ws are also blocked)")

    // The web view must stay on the viewer page. about:blank passes WebKit's
    // own checks, so only the controller's navigation policy can stop it; a
    // file outside the viewer folder is refused by WebKit's sandbox, which
    // must not be mistaken for a broken viewer.
    let readyBeforeNavigation = events.ready
    for target in ["about:blank", "file:///etc/hosts"] {
        _ = await evaluate(controller.webView, "window.location.href = target; return true;", ["target": target])
        await pause(1.0)
        let stillThere = await evaluate(controller.webView, "return typeof window.dimitri;") as? String
        print("  after navigating to \(target): window.dimitri is \(stillThere ?? "?"), "
              + "page \(controller.webView.url?.lastPathComponent ?? "none"), failure: \(events.failure ?? "none")")
        outcome.check(stillThere == "object" && events.failure == nil && events.ready == readyBeforeNavigation,
                      "navigating to \(target) is refused and the viewer stays healthy")
    }
    print("events: " + events.sequence.joined(separator: " → "))
    print(outcome.failures.isEmpty ? "PASS" : "FAIL (\(outcome.failures.count))")
    return outcome.failures.isEmpty
}

// MARK: - Phase-1 reproduction

/// The page phase 1 shipped (MolStarView.html(for:) before this change), with
/// the CDN script swapped for a local copy of the same file. The viewer is
/// also kept on `window` so the check can ask what the preset built.
func legacyHTML(text: String) -> String {
    let encoded = Data(text.utf8).base64EncodedString()
    return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8" />
      <style>
        html, body, #app { margin: 0; padding: 0; width: 100%; height: 100%; background: #0d1117; }
        #fallback {
          display: none; color: #9aa4b2; font: 13px -apple-system, system-ui;
          padding: 24px; text-align: center;
        }
        #loading { color: #9aa4b2; font: 12px -apple-system, system-ui; padding: 16px; }
      </style>
      <script src="molstar.js"></script>
    </head>
    <body>
      <div id="app"></div>
      <div id="loading">Loading Mol* viewer…</div>
      <div id="fallback">The Mol* viewer could not load. Check your network connection; structures can still be exported below.</div>
      <script>
        const b64 = "\(encoded)";
        const raw = atob(b64);
        const bytes = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }
        const text = new TextDecoder("utf-8").decode(bytes);

        function fail(message) {
          document.getElementById("loading").style.display = "none";
          const fallback = document.getElementById("fallback");
          fallback.style.display = "block";
          fallback.textContent = message;
        }

        if (!window.molstar) {
          fail("The Mol* viewer could not load from the CDN. Check your network connection; structures can still be exported.");
        } else {
          molstar.Viewer.create("app", {
            layoutIsExpanded: false,
            layoutShowControls: false,
            layoutShowSequence: false,
            layoutShowLog: false,
            layoutShowLeftPanel: false,
            viewportShowExpand: false,
            viewportShowSelectionMode: false,
            viewportShowAnimation: false
          }).then(async (viewer) => {
            window.__legacyViewer = viewer;
            document.getElementById("loading").style.display = "none";
            await viewer.loadStructureFromData(text, "mmcif");
            window.__dimitriViewerReady = true;
            try {
              viewer.plugin.canvas3d?.setProps({
                renderer: { backgroundColor: 0x0d1117 }
              });
            } catch (e) { /* colour is cosmetic */ }
          }).catch((error) => {
            fail("Could not display this structure: " + error);
          });
        }
      </script>
    </body>
    </html>
    """
}

/// What Mol*'s default preset made of the structure.
let legacySummaryJS = """
const v = window.__legacyViewer;
if (!v) return JSON.stringify({ error: (document.getElementById('fallback') || {}).textContent || 'viewer not created' });
const p = v.plugin;
const out = { molstar: (window.molstar && window.molstar.version) || null, structures: [] };
for (const s of p.managers.structure.hierarchy.current.structures) {
  const st = s.cell.obj.data;
  const m = st.models[0];
  const entities = [];
  for (let i = 0; i < m.entities.data._rowCount; i++) {
    entities.push(`id='${m.entities.data.id.value(i)}' type=${m.entities.data.type.value(i)} subtype=${m.entities.subtype.value(i)}`);
  }
  out.structures.push({
    atoms: st.elementCount,
    polymerResidueCount: st.polymerResidueCount,
    polymerGapCount: st.polymerGapCount,
    entities,
    components: s.components.map(c => ({
      label: c.cell.obj && c.cell.obj.label,
      atoms: c.cell.obj && c.cell.obj.data.elementCount,
      representations: c.representations.map(r => r.cell.transform.params.type.name),
    })),
  });
}
return JSON.stringify(out);
"""

@MainActor
func runLegacy(_ options: Options, molstar: URL) async -> Bool {
    guard options.files.count == 1,
          let text = try? String(contentsOf: options.files[0].url, encoding: .utf8) else {
        print("--legacy takes exactly one readable structure file")
        return false
    }
    let directory = molstar.deletingLastPathComponent()
    guard molstar.lastPathComponent == "molstar.js" else {
        print("--legacy expects a path to a file named molstar.js")
        return false
    }
    let page = directory.appendingPathComponent("legacy-\(options.files[0].url.lastPathComponent).html")
    do {
        try legacyHTML(text: text).write(to: page, atomically: true, encoding: .utf8)
    } catch {
        print("could not write \(page.path): \(error)")
        return false
    }

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    do {
        configuration.userContentController.add(try await offlineRules())
    } catch {
        print("could not compile the offline rules: \(error)")
        return false
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    installNetworkMonitor(on: webView)
    let window = makeWindow(for: webView, size: options.size)
    defer { window.close() }
    webView.loadFileURL(page, allowingReadAccessTo: directory)

    let finished = await waitUntilAsync(options.timeout) {
        let state = await evaluate(webView, """
            return window.__dimitriViewerReady === true ? 'ready'
                : (document.getElementById('fallback') && document.getElementById('fallback').style.display === 'block' ? 'failed' : 'loading');
            """) as? String
        return state == "ready" || state == "failed"
    }
    print("legacy page: \(page.path) with \(molstar.path)")
    print("  finished: \(finished)")
    await pause(1.5)
    if let summary = await evaluate(webView, legacySummaryJS) as? String {
        print("  what the default preset built: " + summary)
    }
    if let image = await takeSnapshot(of: webView) {
        try? writePNG(image, to: options.out)
        print("  snapshot: \(options.out.path)")
        print(describe(analyse(image), label: "WKWebView snapshot"))
    }
    let molstarURL = options.out.deletingPathExtension().appendingPathExtension("molstar.png")
    if let dataURL = await evaluate(webView, "return await window.__legacyViewer.plugin.helpers.viewportScreenshot.getImageDataUri();") as? String,
       let comma = dataURL.firstIndex(of: ","),
       let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
       let image = cgImage(fromPNG: data) {
        try? data.write(to: molstarURL)
        print("  snapshot: \(molstarURL.path)")
        print(describe(analyse(image), label: "Mol* render"))
    }
    return finished
}

// MARK: - Entry point

@MainActor
final class CheckDelegate: NSObject, NSApplicationDelegate {
    let options: Options

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let passed: Bool
            if let molstar = options.legacyMolstar {
                passed = await runLegacy(options, molstar: molstar)
            } else {
                passed = await runBundledViewer(options)
            }
            exit(passed ? 0 : 1)
        }
    }
}

@main
struct ViewerCheck {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = CheckDelegate(options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
