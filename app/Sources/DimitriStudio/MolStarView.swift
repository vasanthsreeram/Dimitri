import AppKit
import SwiftUI
import WebKit

// The 3D structure viewer: Mol* 5.12.0 bundled in Resources/Viewer and run in a
// WKWebView, fully offline. Swift hands it structure text through
// `window.dimitri` (see Resources/Viewer/viewer.js) and hears back through the
// `dimitri` script message handler.

// MARK: - Inputs

/// One structure for the viewer, as the model wrote it.
struct ViewerStructure: Identifiable, Equatable, Sendable {
    enum Format: String, Sendable {
        case pdb
        case mmcif

        /// Maps a backend format name or file extension ("pdb", "cif", "mmcif").
        init?(_ name: String) {
            switch name.lowercased() {
            case "pdb", "ent": self = .pdb
            case "cif", "mmcif", "pdbx": self = .mmcif
            default: return nil
            }
        }
    }

    let id: String
    /// The file's native text. The viewer also checks the text itself, so a
    /// mislabelled PDB/mmCIF still parses.
    let text: String
    let format: Format
    let label: String
    /// Overrides the view's colour mode for this structure, e.g. a grey
    /// reference under a pLDDT-coloured prediction in an overlay.
    var colorMode: ViewerColorMode?
    /// `#RRGGBB`, used with `.uniform`.
    var uniformColor: String?

    init(
        id: String,
        text: String,
        format: Format,
        label: String,
        colorMode: ViewerColorMode? = nil,
        uniformColor: String? = nil
    ) {
        self.id = id
        self.text = text
        self.format = format
        self.label = label
        self.colorMode = colorMode
        self.uniformColor = uniformColor
    }

    /// Same atoms on screen; colour and label changes do not need a reload.
    func hasSameContent(as other: ViewerStructure) -> Bool {
        id == other.id && format == other.format && text == other.text
    }
}

/// How polymer cartoons are coloured.
enum ViewerColorMode: String, CaseIterable, Identifiable, Sendable {
    case plddt, chain, secondary, rainbow, uniform

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plddt: return "pLDDT"
        case .chain: return "Chain"
        case .secondary: return "Secondary structure"
        case .rainbow: return "Rainbow"
        case .uniform: return "Single colour"
        }
    }
}

enum ViewerTheme: String, Sendable {
    case light, dark

    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

// MARK: - Output

/// What the viewer drew, per structure.
struct ViewerLoadReport: Decodable, Equatable, Sendable {
    struct Structure: Decodable, Equatable, Identifiable, Sendable {
        struct SecondaryStructure: Decodable, Equatable, Sendable {
            /// Residues in helices.
            let helix: Int
            /// Residues in strands.
            let sheet: Int
        }

        let id: String
        let label: String?
        /// The format the text was actually parsed as.
        let format: String?
        /// Models in the file; only the first is shown.
        let models: Int?
        let atoms: Int
        let residues: Int
        let chains: Int
        let bonds: Int?
        /// "protein", "rna", "dna": what Mol* recognised as polymer.
        let polymerTypes: [String]
        let polymerResidues: Int?
        /// CA-only or P-only coordinates.
        let traceOnly: Bool?
        let secondaryStructure: SecondaryStructure?
        /// False when the B-factors are not usable as pLDDT (all equal, all
        /// zero, out of range, or an experimental structure).
        let hasConfidence: Bool
        let confidenceNote: String?
        let plddtRange: [Double]?
        /// The colour mode actually applied to the cartoon. pLDDT falls back
        /// to secondary structure (protein) or chain when `hasConfidence` is
        /// false; "element" means there is no polymer to colour.
        let color: String
        /// For example "cartoon" or "cartoon+ball-and-stick".
        let representation: String
        let warnings: [String]?
    }

    let structures: [Structure]
    /// Load time in milliseconds.
    let ms: Double

    /// Whether a pLDDT legend applies: something on screen is coloured by real
    /// confidence values.
    var showsConfidenceLegend: Bool {
        structures.contains { $0.hasConfidence && $0.color == ViewerColorMode.plddt.rawValue }
    }
}

enum ViewerEvent: Sendable {
    case ready
    case loaded(ViewerLoadReport)
    case failed(String)
    case log(String)
}

/// AlphaFold's pLDDT bands, exactly as the viewer colours them.
enum PlddtBand: CaseIterable, Identifiable, Sendable {
    case veryHigh, confident, low, veryLow

    var id: Self { self }

    var label: String {
        switch self {
        case .veryHigh: return "Very high"
        case .confident: return "Confident"
        case .low: return "Low"
        case .veryLow: return "Very low"
        }
    }

    var range: String {
        switch self {
        case .veryHigh: return "≥ 90"
        case .confident: return "70–90"
        case .low: return "50–70"
        case .veryLow: return "< 50"
        }
    }

    var hex: String {
        switch self {
        case .veryHigh: return "#0053D6"
        case .confident: return "#65CBF3"
        case .low: return "#FFDB13"
        case .veryLow: return "#FF7D45"
        }
    }

    var color: Color {
        switch self {
        case .veryHigh: return Color(red: 0x00 / 255, green: 0x53 / 255, blue: 0xD6 / 255)
        case .confident: return Color(red: 0x65 / 255, green: 0xCB / 255, blue: 0xF3 / 255)
        case .low: return Color(red: 0xFF / 255, green: 0xDB / 255, blue: 0x13 / 255)
        case .veryLow: return Color(red: 0xFF / 255, green: 0x7D / 255, blue: 0x45 / 255)
        }
    }
}

/// A compact key for the pLDDT colouring. Show it when
/// `ViewerLoadReport.showsConfidenceLegend` is true.
struct PlddtLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(PlddtBand.allCases) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(band.color)
                        .frame(width: 10, height: 10)
                    Text("\(band.label) \(band.range)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Controller

/// Owns the viewer's web view and reports its state. Keep one per viewer (for
/// example in `@StateObject`) and pass it to `MolStarView`: the page then
/// stays loaded while jobs change, and you can read `state` for an error or a
/// pLDDT legend, or call `snapshotPNG()` for "Save image…".
@MainActor
final class MolStarController: NSObject, ObservableObject {
    enum State: Equatable {
        /// The page or Mol* is starting.
        case starting
        /// Ready, with nothing loaded.
        case idle
        case loading
        case loaded(ViewerLoadReport)
        case failed(String)
    }

    enum ViewerError: LocalizedError {
        case notReady
        case badSnapshot
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notReady: return "The structure viewer is not ready yet."
            case .badSnapshot: return "The structure viewer did not return an image."
            case .timedOut: return "The structure viewer did not answer in time."
            }
        }
    }

    @Published private(set) var state: State = .starting
    /// Receives every bridge event, for callers that prefer a callback.
    var onEvent: ((ViewerEvent) -> Void)?

    let webView: WKWebView

    private let viewerDirectory: URL?
    private var theme: ViewerTheme = .dark
    private var pageRequested = false
    private var ready = false
    /// What the caller asked to show. Loaded once the page is ready, and
    /// again if WebKit's content process has to be restarted.
    private var shown: (structures: [ViewerStructure], colorMode: ViewerColorMode)?
    /// Identifies the latest load, so replies to superseded loads are ignored.
    private var generation = 0
    /// The load of the viewer page itself, to tell its failures from refused navigations.
    private var pageNavigation: WKNavigation?
    private var recentTerminations: [Date] = []

    init(viewerDirectory: URL? = MolStarController.bundledViewerDirectory()) {
        self.viewerDirectory = viewerDirectory
        let configuration = WKWebViewConfiguration()
        // Nothing to keep between launches: no cookies, caches or storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // WKUserContentController retains its handlers; the proxy holds the
        // controller weakly so the two do not keep each other alive.
        configuration.userContentController.add(ScriptMessageProxy(self), name: "dimitri")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
    }

    /// Where the viewer page lives: `Contents/Resources/Viewer` in a packaged
    /// app, otherwise SwiftPM's resource bundle (`swift run`). Returns nil
    /// instead of trapping when neither exists.
    nonisolated static func bundledViewerDirectory() -> URL? {
        let fileManager = FileManager.default
        func viewer(in directory: URL?) -> URL? {
            guard let directory else { return nil }
            let candidate = directory.appendingPathComponent("Viewer", isDirectory: true)
            let index = candidate.appendingPathComponent("index.html").path
            return fileManager.fileExists(atPath: index) ? candidate : nil
        }
        if let directory = viewer(in: Bundle.main.resourceURL) {
            return directory
        }
        #if SWIFT_PACKAGE
        // SwiftPM's generated `Bundle.module` calls fatalError when its bundle
        // is missing, so only touch it after finding the bundle where it looks.
        let bundleName = "DimitriStudio_DimitriStudio.bundle"
        let bundleExists = [Bundle.main.resourceURL, Bundle.main.bundleURL].contains { base in
            guard let base else { return false }
            return fileManager.fileExists(atPath: base.appendingPathComponent(bundleName).path)
        }
        if bundleExists, let directory = viewer(in: Bundle.module.resourceURL) {
            return directory
        }
        #endif
        return nil
    }

    // MARK: Commands

    /// Loads the viewer page once. `MolStarView` calls this with the current
    /// appearance so the first frame already has the right background.
    func start(theme: ViewerTheme? = nil) {
        if let theme {
            self.theme = theme
        }
        guard !pageRequested else { return }
        pageRequested = true
        loadPage()
    }

    /// Shows `structures`, replacing whatever is on screen. Calls before the
    /// page is ready are queued (only the latest is kept). Repeating the same
    /// structures with another colour mode recolours them without reloading.
    func show(_ structures: [ViewerStructure], colorMode: ViewerColorMode) {
        start()
        let previous = shown
        shown = (structures, colorMode)
        guard ready else { return }
        if let previous,
           previous.structures.count == structures.count,
           zip(previous.structures, structures).allSatisfy({ $0.hasSameContent(as: $1) }) {
            recolor(from: previous, to: (structures, colorMode))
        } else {
            sendLoad()
        }
    }

    /// Follows the app's light or dark appearance.
    func setTheme(_ theme: ViewerTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        guard ready else { return }
        webView.callAsyncJavaScript(
            "await window.dimitri.setTheme(theme);",
            arguments: ["theme": theme.rawValue],
            in: nil,
            in: .page
        )
    }

    func resetView() {
        guard ready else { return }
        webView.callAsyncJavaScript("await window.dimitri.resetView();", arguments: [:], in: nil, in: .page)
    }

    func clear() {
        shown = nil
        generation += 1
        guard ready else { return }
        state = .idle
        webView.callAsyncJavaScript("await window.dimitri.clear();", arguments: [:], in: nil, in: .page)
    }

    /// The current view as PNG data, rendered by Mol* at the viewport size or
    /// at `width` × `height` pixels.
    func snapshotPNG(width: Int? = nil, height: Int? = nil) async throws -> Data {
        guard ready else { throw ViewerError.notReady }
        var options: [String: Any] = [:]
        if let width, let height {
            options["width"] = width
            options["height"] = height
        }
        let dataURL = try await evaluateString(
            "return await window.dimitri.snapshot(options);",
            arguments: ["options": options]
        )
        let prefix = "data:image/png;base64,"
        guard let dataURL, dataURL.hasPrefix(prefix),
              let data = Data(base64Encoded: String(dataURL.dropFirst(prefix.count))) else {
            throw ViewerError.badSnapshot
        }
        return data
    }

    // MARK: Page

    private func loadPage() {
        ready = false
        guard let directory = viewerDirectory else {
            fail("The structure viewer is missing from this build (Resources/Viewer).")
            return
        }
        var components = URLComponents(
            url: directory.appendingPathComponent("index.html"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "theme", value: theme.rawValue)]
        guard let page = components?.url else {
            fail("The structure viewer page could not be located.")
            return
        }
        state = .starting
        pageNavigation = webView.loadFileURL(page, allowingReadAccessTo: directory)
    }

    private func sendLoad() {
        guard let shown else { return }
        generation += 1
        let request = generation
        state = shown.structures.isEmpty ? .idle : .loading
        let payload: [[String: Any]] = shown.structures.map { structure in
            var item: [String: Any] = [
                "id": structure.id,
                "text": structure.text,
                "format": structure.format.rawValue,
                "label": structure.label,
                "color": (structure.colorMode ?? shown.colorMode).rawValue,
            ]
            if let uniformColor = structure.uniformColor {
                item["uniformColor"] = uniformColor
            }
            return item
        }
        let options: [String: Any] = ["theme": theme.rawValue, "requestId": request]
        // The text goes over as a call argument, not spliced into HTML or JS.
        webView.callAsyncJavaScript(
            "return await window.dimitri.load(structures, options);",
            arguments: ["structures": payload, "options": options],
            in: nil,
            in: .page
        ) { [weak self] result in
            // Failures inside load() arrive as an 'error' message. This only
            // catches the call itself failing, e.g. the page not being there.
            guard let self, request == self.generation, self.state == .loading,
                  case .failure(let error) = result else { return }
            self.fail("The viewer could not take the structure: \(error.localizedDescription)")
        }
    }

    private func recolor(
        from previous: (structures: [ViewerStructure], colorMode: ViewerColorMode),
        to next: (structures: [ViewerStructure], colorMode: ViewerColorMode)
    ) {
        for (old, new) in zip(previous.structures, next.structures) {
            let oldMode = old.colorMode ?? previous.colorMode
            let newMode = new.colorMode ?? next.colorMode
            guard oldMode != newMode || old.uniformColor != new.uniformColor else { continue }
            var arguments: [String: Any] = ["mode": newMode.rawValue, "id": new.id]
            arguments["uniformColor"] = new.uniformColor ?? NSNull()
            webView.callAsyncJavaScript(
                "await window.dimitri.setColor(mode, id, uniformColor);",
                arguments: arguments,
                in: nil,
                in: .page
            )
        }
    }

    /// Runs `body` in the page and returns its string result. Gives up after
    /// `timeout` seconds: a page whose process has gone never answers.
    private func evaluateString(
        _ body: String,
        arguments: [String: Any],
        timeout: TimeInterval = 20
    ) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            let reply = SingleReply(continuation)
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                reply.resume(with: result.map { $0 as? String })
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                reply.resume(with: .failure(ViewerError.timedOut))
            }
        }
    }

    // MARK: Messages

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        let requestID = (message["requestId"] as? NSNumber)?.intValue
        switch type {
        case "ready":
            ready = true
            emit(.ready)
            webView.callAsyncJavaScript(
                "await window.dimitri.setTheme(theme);",
                arguments: ["theme": theme.rawValue],
                in: nil,
                in: .page
            )
            if shown != nil {
                sendLoad()
            } else if case .failed = state {
                // Keep a failure that made us stop showing the structure.
            } else {
                state = .idle
            }
        case "loaded":
            guard requestID == nil || requestID == generation else { return }
            guard let report = Self.decodeReport(message["report"]) else {
                fail("The structure viewer sent a report the app could not read.")
                return
            }
            state = report.structures.isEmpty ? .idle : .loaded(report)
            emit(.loaded(report))
        case "error":
            guard requestID == nil || requestID == generation else { return }
            fail(message["message"] as? String ?? "The structure viewer reported an error.")
        case "log":
            if let text = message["message"] as? String {
                emit(.log(text))
            }
        default:
            break
        }
    }

    private static func decodeReport(_ value: Any?) -> ViewerLoadReport? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(ViewerLoadReport.self, from: data)
    }

    private func fail(_ message: String) {
        state = .failed(message)
        emit(.failed(message))
    }

    private func emit(_ event: ViewerEvent) {
        onEvent?(event)
    }
}

extension MolStarController: WKNavigationDelegate {
    /// Only the bundled page may load here; a stray link or dropped file must
    /// not navigate the viewer away.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.isFileURL, let directory = viewerDirectory else {
            decisionHandler(.cancel)
            return
        }
        let root = directory.resolvingSymlinksInPath().path + "/"
        decisionHandler(url.resolvingSymlinksInPath().path.hasPrefix(root) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error)
    }

    /// Only the viewer page's own load can break the viewer. Any other
    /// navigation was refused (by the policy above or WebKit's sandbox) and
    /// the page is still there.
    private func navigationFailed(_ navigation: WKNavigation?, _ error: Error) {
        guard let navigation, navigation === pageNavigation else {
            emit(.log("Refused a navigation away from the viewer: \(error.localizedDescription)"))
            return
        }
        fail("The structure viewer page failed to load: \(error.localizedDescription)")
    }

    /// WebKit ended the page's process (memory pressure or a crash). Reload
    /// the page; once it is ready, the last structures are shown again,
    /// unless they have now taken the page down three times in a minute.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        recentTerminations = recentTerminations.filter { now.timeIntervalSince($0) < 60 } + [now]
        emit(.log("The viewer's web content process ended; reloading it."))
        loadPage()
        if recentTerminations.count >= 3 {
            shown = nil
            fail("The structure viewer keeps stopping while showing this structure.")
        }
    }
}

/// Resumes a continuation once, whichever of the reply or the timeout comes first.
@MainActor
private final class SingleReply<Value> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Forwards script messages to the controller without retaining it.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var controller: MolStarController?

    init(_ controller: MolStarController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        controller?.receive(message.body)
    }
}

// MARK: - View

/// The 3D structure viewer.
///
///     MolStarView(
///         structures: [ViewerStructure(id: job.id, text: text, format: .pdb, label: job.name)],
///         colorMode: .plddt,
///         controller: viewer
///     )
///
/// New structures are loaded into the running page; it is never reloaded for
/// a structure change. The view follows the app's light or dark appearance.
/// Pass a `MolStarController` you own to observe loading and errors and to
/// take snapshots; without one, the view creates its own.
struct MolStarView: NSViewRepresentable {
    let structures: [ViewerStructure]
    var colorMode: ViewerColorMode = .plddt
    var controller: MolStarController?
    var onEvent: ((ViewerEvent) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller ?? MolStarController())
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = context.coordinator.controller
        controller.start(theme: ViewerTheme(context.environment.colorScheme))
        return controller.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let controller = context.coordinator.controller
        if let onEvent {
            controller.onEvent = onEvent
        }
        controller.setTheme(ViewerTheme(context.environment.colorScheme))
        controller.show(structures, colorMode: colorMode)
    }

    @MainActor
    final class Coordinator {
        let controller: MolStarController

        init(controller: MolStarController) {
            self.controller = controller
        }
    }
}

extension MolStarView {
    /// Transitional: the phase-1 Results call site, which passes the backend's
    /// CIF export. New code passes `ViewerStructure` values with each model's
    /// native text and format, and a long-lived `MolStarController`.
    init(cif: String) {
        self.init(structures: [ViewerStructure(id: "structure", text: cif, format: .mmcif, label: "Structure")])
    }
}
