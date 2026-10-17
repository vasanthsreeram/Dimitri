import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation

/// Starts, watches and stops the local Python backend, so nobody needs a
/// terminal.
///
/// Inside the .app the backend's source lives in Contents/Resources/backend
/// and its Python environment is created on first launch, outside the signed
/// bundle, in ~/Library/Application Support/Dimitri Studio, using the uv binary
/// bundled in Contents/Helpers. Run from the repository (`swift run`), it uses
/// backend/.venv. A backend that is already listening (for example one started
/// with scripts/run-backend.sh) is reused and left running on quit.
@MainActor
@Observable
final class BackendController {
    enum Phase: Equatable {
        case idle
        case connecting
        case preparing(String)
        case starting
        case ready
        case failed(Problem)
    }

    struct Problem: Equatable {
        var title: String
        var message: String
        var command: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var baseURL = URL(string: "http://127.0.0.1:8642/")!
    private(set) var ownsProcess = false
    private(set) var setupLines: [String] = []
    private(set) var firstLaunch = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var crashes = 0

    static let defaultPort = 8642

    var isReady: Bool { phase == .ready }

    var logURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Dimitri Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("backend.log")
    }

    // MARK: - Lifecycle

    func start() {
        guard startTask == nil, phase != .ready else { return }
        stopping = false
        startTask = Task.detached { @MainActor [weak self] in
            await self?.bringUp()
            self?.startTask = nil
        }
    }

    func restart() {
        stop()
        phase = .idle
        crashes = 0
        start()
    }

    /// Stop the backend if this app started it. Waits briefly so model
    /// workers get a clean shutdown; they also exit on their own if not.
    func stop() {
        stopping = true
        startTask?.cancel()
        startTask = nil
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning { kill(pid, SIGKILL) }
        self.process = nil
        ownsProcess = false
    }

    private func bringUp() async {
        phase = .connecting
        // 1. A backend already listening on the default port?
        let defaultURL = URL(string: "http://127.0.0.1:\(Self.defaultPort)/")!
        switch await probe(defaultURL) {
        case .dimitri:
            baseURL = defaultURL
            ownsProcess = false
            phase = .ready
            return
        case .other:
            baseURL = URL(string: "http://127.0.0.1:\(Self.freePort() ?? 8643)/")!
        case .nothing:
            baseURL = defaultURL
        }

        // 2. Find the backend and its Python environment.
        guard let layout = Layout.locate() else {
            fail("Backend files are missing",
                 "This copy of Dimitri Studio has no backend. Reinstall the app, or run it from the repository.")
            return
        }
        guard let python = await prepareEnvironment(layout) else { return }
        if Task.isCancelled { return }

        // 3. Launch it and wait until it answers.
        phase = .starting
        do {
            try launch(python: python, layout: layout)
        } catch {
            fail("The backend could not start", error.localizedDescription)
            return
        }
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !Task.isCancelled {
            if await probe(baseURL) == .dimitri {
                phase = .ready
                return
            }
            if let process, !process.isRunning {
                fail("The backend stopped while starting",
                     "See the backend log for details.")
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !Task.isCancelled {
            fail("The backend did not respond", "It started but did not answer within 90 seconds.")
        }
    }

    private func fail(_ title: String, _ message: String, command: String? = nil) {
        phase = .failed(Problem(title: title, message: message, command: command))
    }

    // MARK: - Environment

    private func prepareEnvironment(_ layout: Layout) async -> URL? {
        if layout.bundled {
            let env = Layout.supportDirectory.appendingPathComponent("backend-venv", isDirectory: true)
            let python = env.appendingPathComponent("bin/python")
            let marker = env.appendingPathComponent(".dimitri-lock")
            let expected = Layout.lockHash(layout.backend)
            if FileManager.default.isExecutableFile(atPath: python.path),
               (try? String(contentsOf: marker, encoding: .utf8)) == expected {
                return python
            }
            guard let uv = Layout.uv() else {
                fail("uv is needed to set up Dimitri Studio",
                     "Dimitri uses uv to create its Python environment. Install it, then reopen the app.",
                     command: "curl -LsSf https://astral.sh/uv/install.sh | sh")
                return nil
            }
            firstLaunch = true
            phase = .preparing("Setting up Dimitri Studio's Python environment (first launch only)…")
            let ok = await runSetup(
                uv,
                ["sync", "--frozen", "--no-dev", "--no-install-project"],
                in: layout.backend,
                extraEnv: ["UV_PROJECT_ENVIRONMENT": env.path]
            )
            guard ok, FileManager.default.isExecutableFile(atPath: python.path) else {
                fail("Setting up the Python environment failed",
                     "uv could not install the backend's packages. Check the network connection and try again.")
                return nil
            }
            try? expected.write(to: marker, atomically: true, encoding: .utf8)
            return python
        }

        let python = layout.backend.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: python.path) {
            return python
        }
        guard let uv = Layout.uv() else {
            fail("uv is needed to run the backend",
                 "Install uv, then reopen the app.",
                 command: "curl -LsSf https://astral.sh/uv/install.sh | sh")
            return nil
        }
        firstLaunch = true
        phase = .preparing("Creating the backend environment…")
        guard await runSetup(uv, ["sync", "--extra", "dev"], in: layout.backend, extraEnv: [:]),
              FileManager.default.isExecutableFile(atPath: python.path) else {
            fail("Setting up the backend failed", "uv sync did not finish. See the backend log.")
            return nil
        }
        return python
    }

    private func runSetup(_ executable: URL, _ arguments: [String], in directory: URL, extraEnv: [String: String]) async -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = Layout.baseEnvironment()
        environment.merge(extraEnv) { $1 }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = (try? FileHandle(forWritingTo: logURL)) ?? Self.createLog(logURL)
        log?.seekToEndOfFile()
        do {
            try process.run()
        } catch {
            return false
        }
        for await line in Self.lines(pipe.fileHandleForReading) {
            log?.write(Data((line + "\n").utf8))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            setupLines.append(trimmed)
            if setupLines.count > 40 { setupLines.removeFirst(setupLines.count - 40) }
            if let progress = Self.describe(trimmed) {
                phase = .preparing(progress)
            }
        }
        process.waitUntilExit()
        try? log?.close()
        return process.terminationStatus == 0
    }

    private static func describe(_ line: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("downloading cpython") || lower.contains("installing python") {
            return "Downloading Python…"
        }
        if lower.hasPrefix("downloading") || lower.hasPrefix("downloaded") {
            return "Downloading packages · \(line.prefix(60))"
        }
        if lower.hasPrefix("installed") || lower.hasPrefix("prepared") || lower.hasPrefix("resolved") {
            return line
        }
        return nil
    }

    // MARK: - Process

    private func launch(python: URL, layout: Layout) throws {
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-m", "dimitri",
            "--port", String(baseURL.port ?? Self.defaultPort),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        process.currentDirectoryURL = layout.backend
        var environment = Layout.baseEnvironment()
        environment["PYTHONPATH"] = layout.backend.path
        environment["PYTHONUNBUFFERED"] = "1"
        if layout.bundled {
            // Nothing inside the signed bundle may change, bytecode included.
            environment["PYTHONPYCACHEPREFIX"] = Layout.cacheDirectory.appendingPathComponent("pycache").path
        }
        process.environment = environment
        let log = (try? FileHandle(forWritingTo: logURL)) ?? Self.createLog(logURL)
        log?.seekToEndOfFile()
        log?.write(Data("\n=== \(Date()) starting backend on \(baseURL.absoluteString)\n".utf8))
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.processExited(finished) }
        }
        try process.run()
        self.process = process
        ownsProcess = true
    }

    private func processExited(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        ownsProcess = false
        guard !stopping else { return }
        crashes += 1
        if crashes <= 3 {
            phase = .starting
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.phase = .idle
                self?.start()
            }
        } else {
            fail("The backend keeps stopping", "It exited \(crashes) times. See the backend log.")
        }
    }

    // MARK: - Probing

    private enum ProbeResult { case dimitri, other, nothing }

    private func probe(_ url: URL) async -> ProbeResult {
        var request = URLRequest(url: url.appendingPathComponent("api/health"))
        request.timeoutInterval = 1.5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .other }
            let health = try? BackendClient.decoder().decode(HealthResponse.self, from: data)
            // Backends before 0.2 lack the event stream this app needs; treat
            // one of those like any other program on the port.
            return health?.status == "ok" && health?.app == "dimitri-studio" ? .dimitri : .other
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            return .nothing
        } catch {
            return .nothing
        }
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    // MARK: - Helpers

    private static func createLog(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    /// Lines from a pipe, delivered on the main actor.
    private static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached {
                do {
                    for try await line in handle.bytes.lines {
                        continuation.yield(line)
                    }
                } catch {}
                continuation.finish()
            }
        }
    }
}

/// Where the backend source and tools live, in the .app or in the repository.
struct Layout {
    let backend: URL
    let bundled: Bool

    static func locate() -> Layout? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("backend", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("dimitri/__main__.py").path) {
                return Layout(backend: bundled, bundled: true)
            }
        }
        if let override = ProcessInfo.processInfo.environment["DIMITRI_BACKEND_DIR"] {
            return Layout(backend: URL(fileURLWithPath: override, isDirectory: true), bundled: false)
        }
        // Running from the repository: app/Sources/DimitriStudio/<this file>.
        let source = URL(fileURLWithPath: #filePath)
        let repo = source.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let backend = repo.appendingPathComponent("backend", isDirectory: true)
        if FileManager.default.fileExists(atPath: backend.appendingPathComponent("dimitri/__main__.py").path) {
            return Layout(backend: backend, bundled: false)
        }
        return nil
    }

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dimitri Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dimitri Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Directory of the uv bundled with the app, if any.
    static var helpersDirectory: URL? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil
    }

    static func uv() -> URL? {
        var candidates: [String] = []
        if let helpers = helpersDirectory {
            candidates.append(helpers.appendingPathComponent("uv").path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(home)/.cargo/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// A PATH that finds uv, git and Homebrew tools even though GUI apps do
    /// not inherit the shell's PATH.
    static func baseEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let helpers = helpersDirectory {
            path.insert(helpers.path, at: 0)
            environment["DIMITRI_EXTRA_PATH"] = helpers.path
        }
        environment["PATH"] = path.joined(separator: ":")
        environment.removeValue(forKey: "VIRTUAL_ENV")
        environment.removeValue(forKey: "PYTHONHOME")
        return environment
    }

    static func lockHash(_ backend: URL) -> String {
        let lock = (try? Data(contentsOf: backend.appendingPathComponent("uv.lock"))) ?? Data()
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        return SHA256.hash(data: lock + Data(version.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
