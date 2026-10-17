import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Screen: String, CaseIterable, Identifiable {
    case predict, results, library
    var id: String { rawValue }

    var title: String {
        switch self {
        case .predict: return "Predict"
        case .results: return "Results"
        case .library: return "Library"
        }
    }

    var icon: String {
        switch self {
        case .predict: return "wand.and.stars"
        case .results: return "cube.transparent"
        case .library: return "books.vertical"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .predict: return "1"
        case .results: return "2"
        case .library: return "3"
        }
    }
}

/// What the Predict screen is about to run. Lives in the model so a file
/// dropped anywhere in the window lands here.
struct PredictionDraft: Equatable {
    var name = ""
    var sequence = ""
    var entity: EntityKind = .protein
    /// The user picked the entity type; stop guessing from the letters.
    var entityPinned = false
    var modelIDs: [String] = []
    /// The user chose the models; stop choosing for them.
    var modelsPinned = false
    var seed = 42
    var samples = 5

    var cleanedSequence: String {
        let stripped = sequence.filter { !$0.isWhitespace }
        return entity == .ligand ? stripped : stripped.uppercased()
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, failure }
    let id = UUID()
    var kind: Kind
    var title: String
    var message: String?
}

/// All app state. The backend pushes changes over one event stream; nothing
/// polls except a slow status refresh.
@MainActor
@Observable
final class AppModel {
    let backend = BackendController()
    /// One Mol* instance for the app, so switching jobs or screens never
    /// re-initialises the viewer.
    @ObservationIgnored let viewer = MolStarController()

    var screen: Screen = .predict
    var selectedJobID: String?
    var draft = PredictionDraft()
    var toast: Toast?
    var showOnboarding: Bool
    var compareMode = false

    private(set) var jobs: [JobSummary] = []
    private(set) var live: [String: JobLive] = [:]
    private(set) var details: [String: Job] = [:]
    private(set) var runners: [RunnerManifest] = []
    private(set) var runnerStatus: [String: RunnerStatus] = [:]
    private(set) var workers: [WorkerStatus] = []
    private(set) var catalog: [CatalogEntry] = []
    private(set) var catalogSources: CatalogSources?
    private(set) var status: StatusResponse?
    private(set) var settings: BackendSettings?
    private(set) var connected = false
    private(set) var submitting = false
    private(set) var refreshingCatalog = false

    @ObservationIgnored private var structureCache: [String: ViewerStructure] = [:]
    @ObservationIgnored private var structureOrder: [String] = []
    @ObservationIgnored private var paeCache: [String: PaeMatrix] = [:]
    @ObservationIgnored private var comparisonCache: [String: Comparison] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var catalogRefresh: Task<Void, Never>?

    init() {
        showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingFinished")
    }

    var client: BackendClient { BackendClient(baseURL: backend.baseURL) }

    // MARK: - Connection

    /// Start the backend and keep the live stream open for the app's lifetime.
    ///
    /// Called once from the app delegate. The loops run in detached tasks so
    /// they never inherit context from a SwiftUI view update.
    func start() {
        guard !started else { return }
        started = true
        backend.start()
        Task.detached { await self.liveLoop() }
        Task.detached { await self.statusLoop() }
    }

    private func liveLoop() async {
        while !Task.isCancelled {
            guard backend.isReady else {
                connected = false
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            await refreshAll()
            do {
                for try await event in client.events() {
                    connected = true
                    handle(event)
                }
            } catch {}
            connected = false
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    private func statusLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if connected { await refreshStatus() }
        }
    }

    func refreshAll() async {
        let client = self.client
        async let catalogTask: CatalogResponse = client.get("api/models")
        async let runnersTask: [RunnerManifest] = client.get("api/runners")
        async let statusTask: StatusResponse = client.get("api/status")
        async let settingsTask: BackendSettings = client.get("api/settings")
        if let catalog = try? await catalogTask {
            self.catalog = catalog.entries
            catalogSources = catalog.sources
        }
        if let runners = try? await runnersTask { self.runners = runners }
        if let status = try? await statusTask { apply(status) }
        if let settings = try? await settingsTask { self.settings = settings }
        reconcileDraftModels()
    }

    func refreshStatus(lmStudio: Bool = false) async {
        if let status: StatusResponse = try? await client.get(lmStudio ? "api/status?refresh=true" : "api/status") {
            apply(status)
        }
    }

    private func apply(_ status: StatusResponse) {
        self.status = status
        runnerStatus = Dictionary(uniqueKeysWithValues: status.runners.map { ($0.id, $0) })
        workers = status.workers ?? []
    }

    func refreshCatalogSoon() {
        catalogRefresh?.cancel()
        catalogRefresh = Task.detached { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            if let catalog: CatalogResponse = try? await self.client.get("api/models") {
                self.catalog = catalog.entries
                self.catalogSources = catalog.sources
                self.reconcileDraftModels()
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: BackendEvent) {
        switch event {
        case .snapshot(let snapshot):
            withAnimation(.smooth) {
                jobs = snapshot.jobs.sorted { $0.createdAt > $1.createdAt }
            }
            reconcileSelection()
        case .job(let update):
            let summary = update.summary
            let previous = jobs.first { $0.id == summary.id }
            withAnimation(.smooth) {
                if let index = jobs.firstIndex(where: { $0.id == summary.id }) {
                    jobs[index] = summary
                } else {
                    jobs.insert(summary, at: 0)
                }
            }
            live[summary.id] = JobLive(stages: update.stages, log: update.log)
            if previous?.status != summary.status {
                if summary.isTerminal {
                    Task { await self.loadDetail(summary.id, force: true) }
                    announce(summary)
                }
                if summary.kind == "install" { refreshCatalogSoon() }
            }
        case .deleted(let id):
            withAnimation(.smooth) {
                jobs.removeAll { $0.id == id }
            }
            details[id] = nil
            live[id] = nil
            dropCaches(for: id)
            reconcileSelection()
        case .runners(let update):
            runnerStatus = Dictionary(uniqueKeysWithValues: update.runners.map { ($0.id, $0) })
            workers = update.workers
            refreshCatalogSoon()
        }
    }

    private func announce(_ summary: JobSummary) {
        guard summary.kind == "predict" || summary.kind == "install" else { return }
        switch summary.status {
        case "completed":
            let detail = summary.kind == "install"
                ? "Ready to run."
                : summary.plddt.map { "Mean pLDDT \(Format.score($0)) · \(Format.seconds(summary.durationS))" }
            present(.success, summary.kind == "install" ? "\(summary.name) finished" : "\(summary.name) is ready", detail)
        case "failed":
            present(.failure, "\(summary.name) failed", summary.error)
        default:
            break
        }
    }

    // MARK: - Selection

    var predictions: [JobSummary] { jobs.filter { $0.kind != "install" } }

    var selectedSummary: JobSummary? {
        guard let id = selectedJobID else { return nil }
        return jobs.first { $0.id == id }
    }

    var installJobs: [JobSummary] { jobs.filter { $0.kind == "install" } }

    func select(_ id: String?, show: Bool = true) {
        selectedJobID = id
        if show { screen = .results }
        if let id { Task { await loadDetail(id) } }
    }

    private func reconcileSelection() {
        let available = predictions
        if let id = selectedJobID, available.contains(where: { $0.id == id }) { return }
        selectedJobID = available.first?.id
        if let id = selectedJobID { Task { await loadDetail(id) } }
    }

    /// Jobs on the same input as `summary`, completed, newest first.
    func siblings(of summary: JobSummary) -> [JobSummary] {
        guard !summary.sequenceKey.isEmpty else { return [] }
        return predictions.filter {
            $0.sequenceKey == summary.sequenceKey && $0.isCompleted && $0.id != summary.id
        }
    }

    // MARK: - Details and data

    func loadDetail(_ id: String, force: Bool = false) async {
        if !force, let existing = details[id], existing.isTerminal { return }
        if let job: Job = try? await client.get("api/jobs/\(id)") {
            details[id] = job
        }
    }

    func structure(for id: String) async -> ViewerStructure? {
        if let cached = structureCache[id] { return cached }
        guard let (text, format) = try? await client.structure(jobID: id) else { return nil }
        let summary = jobs.first { $0.id == id }
        let structure = ViewerStructure(
            id: id,
            text: text,
            format: ViewerStructure.Format(format) ?? .pdb,
            label: summary?.name ?? id
        )
        structureCache[id] = structure
        structureOrder.append(id)
        if structureOrder.count > 8 {
            structureCache[structureOrder.removeFirst()] = nil
        }
        return structure
    }

    func pae(for id: String) async -> PaeMatrix? {
        if let cached = paeCache[id] { return cached }
        guard let matrix: PaeMatrix = try? await client.get("api/jobs/\(id)/pae?max=200") else { return nil }
        paeCache[id] = matrix
        return matrix
    }

    func compare(_ reference: String, _ other: String) async -> Result<Comparison, Error> {
        let key = "\(reference)|\(other)"
        if let cached = comparisonCache[key] { return .success(cached) }
        do {
            let value: Comparison = try await client.get("api/jobs/\(reference)/compare/\(other)")
            comparisonCache[key] = value
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    private func dropCaches(for id: String) {
        structureCache[id] = nil
        structureOrder.removeAll { $0 == id }
        paeCache[id] = nil
        comparisonCache = comparisonCache.filter { !$0.key.contains(id) }
    }

    // MARK: - Models

    var predictableModels: [CatalogEntry] {
        let order = ["rhofold", "alphafold3-mac", "openfold3"]
        return catalog.filter(\.installable).sorted {
            (order.firstIndex(of: $0.modelID) ?? 99) < (order.firstIndex(of: $1.modelID) ?? 99)
        }
    }

    func entry(for modelID: String) -> CatalogEntry? {
        catalog.first { $0.modelID == modelID || $0.id == modelID }
    }

    func runner(for modelID: String) -> RunnerManifest? {
        runners.first { $0.id == modelID }
    }

    func shortName(for modelID: String) -> String {
        if modelID == "import" { return "Imported" }
        return runner(for: modelID)?.shortName ?? entry(for: modelID)?.name ?? modelID
    }

    func isWarm(_ modelID: String) -> Bool {
        workers.contains { $0.runnerId == modelID && ($0.state == "ready" || $0.state == "busy") }
    }

    /// Keep the draft's model choice valid for its entity type. Until the user
    /// picks models, choose the specialist: RhoFold+ for RNA, AlphaFold 3
    /// otherwise, preferring whichever is ready.
    func reconcileDraftModels() {
        let compatible = predictableModels.filter { $0.entityTypes.contains(draft.entity.rawValue) }
        var chosen = draft.modelIDs.filter { id in compatible.contains { $0.modelID == id } }
        if !draft.modelsPinned || chosen.isEmpty {
            let order = draft.entity == .rna
                ? ["rhofold", "alphafold3-mac", "openfold3"]
                : ["alphafold3-mac", "openfold3", "rhofold"]
            let ranked = compatible.sorted {
                (order.firstIndex(of: $0.modelID) ?? 99) < (order.firstIndex(of: $1.modelID) ?? 99)
            }
            if let pick = ranked.first(where: \.ready) ?? ranked.first {
                chosen = [pick.modelID]
            }
        }
        if chosen != draft.modelIDs { draft.modelIDs = chosen }
    }

    /// Load the model in the background so pressing Run starts at once.
    func prewarm(_ modelID: String) {
        guard entry(for: modelID)?.ready == true, !isWarm(modelID) else { return }
        Task { let _: [String: Bool]? = try? await client.post("api/runners/\(modelID)/warm") }
    }

    func release(_ modelID: String) async {
        let _: [String: Bool]? = try? await client.post("api/runners/\(modelID)/release")
    }

    // MARK: - Draft checks

    /// Why the draft cannot run as typed, or nil when it is fine.
    var draftProblem: String? {
        let sequence = draft.cleanedSequence
        guard !sequence.isEmpty else { return nil }
        if sequence.count > 8_000 { return "Sequences are limited to 8,000 characters." }
        if let alphabet = draft.entity.alphabet {
            let bad = Set(sequence).subtracting(alphabet)
            if !bad.isEmpty {
                let letters = String(bad.sorted())
                if draft.entity == .rna, bad == ["T"] { return "RNA uses U, not T. Replace T with U, or choose DNA." }
                return "Not valid \(draft.entity.label): \(letters)"
            }
        }
        return nil
    }

    var canSubmit: Bool {
        guard !submitting, !draft.cleanedSequence.isEmpty, draftProblem == nil, !draft.modelIDs.isEmpty else {
            return false
        }
        return draft.modelIDs.allSatisfy { id in entry(for: id)?.ready == true }
    }

    // MARK: - Viewer hooks

    /// Set by the visible structure viewer so menus can save its image.
    @ObservationIgnored var snapshotProvider: (() async throws -> Data)?
    var confirmDelete = false

    func requestSnapshot() {
        guard let provider = snapshotProvider else { return }
        let name = selectedSummary?.name ?? "structure"
        Task {
            do {
                saveImage(try await provider(), name: name)
            } catch {
                present(.failure, "Could not capture the image", error.localizedDescription)
            }
        }
    }

    // MARK: - Actions

    func submit() async {
        let draft = self.draft
        let sequence = draft.cleanedSequence
        guard !sequence.isEmpty, !draft.modelIDs.isEmpty else { return }
        submitting = true
        defer { submitting = false }
        let name = draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultName(for: draft)
            : draft.name.trimmingCharacters(in: .whitespaces)
        do {
            let created: [Job]
            if draft.modelIDs.count == 1 {
                let response: CreateJobResponse = try await client.post(
                    "api/jobs",
                    body: PredictionPayload(
                        modelId: draft.modelIDs[0], entityType: draft.entity.rawValue,
                        sequence: sequence, name: name, seed: draft.seed, samples: draft.samples
                    )
                )
                created = [response.job]
            } else {
                let response: CreateJobsResponse = try await client.post(
                    "api/jobs/batch",
                    body: BatchPredictionPayload(
                        modelIds: draft.modelIDs, entityType: draft.entity.rawValue,
                        sequence: sequence, name: name, seed: draft.seed, samples: draft.samples
                    )
                )
                created = response.jobs
            }
            for job in created { details[job.id] = job }
            withAnimation(.smooth) {
                selectedJobID = created.first?.id
                compareMode = created.count > 1
                screen = .results
            }
        } catch {
            present(.failure, "Could not start the prediction", error.localizedDescription)
        }
    }

    private func defaultName(for draft: PredictionDraft) -> String {
        let length = draft.cleanedSequence.count
        return "\(draft.entity.label) · \(length) \(draft.entity.unit)"
    }

    func cancel(_ id: String) async {
        do {
            let _: [String: Bool] = try await client.post("api/jobs/\(id)/cancel")
        } catch {
            present(.failure, "Could not cancel", error.localizedDescription)
        }
    }

    func delete(_ id: String) async {
        do {
            try await client.delete("api/jobs/\(id)")
        } catch {
            present(.failure, "Could not delete the job", error.localizedDescription)
        }
    }

    /// Put a finished job's input back into Predict.
    func reuseInput(_ id: String) async {
        await loadDetail(id)
        guard let job = details[id], let entity = EntityKind(rawValue: job.entityType) else { return }
        draft.sequence = job.sequence
        draft.entity = entity
        draft.entityPinned = true
        draft.name = job.name
        draft.seed = job.seed
        draft.samples = max(1, job.samples)
        if job.kind == "predict" { draft.modelIDs = [job.modelId] }
        reconcileDraftModels()
        withAnimation(.smooth) { screen = .predict }
    }

    func rerun(_ id: String) async {
        await loadDetail(id)
        guard let job = details[id], job.kind == "predict" else { return }
        draft.sequence = job.sequence
        draft.entity = EntityKind(rawValue: job.entityType) ?? .protein
        draft.entityPinned = true
        draft.name = job.name
        draft.seed = job.seed
        draft.samples = job.samples
        draft.modelIDs = [job.modelId]
        await submit()
    }

    func install(_ entry: CatalogEntry) async {
        do {
            let response: CreateJobResponse = try await client.post("api/models/\(entry.id)/install")
            details[response.job.id] = response.job
            present(.info, "Installing \(entry.name)", "Progress is shown on its card in the Library.")
        } catch {
            present(.failure, "Could not start the install", error.localizedDescription)
        }
    }

    func refreshCatalog() async {
        refreshingCatalog = true
        defer { refreshingCatalog = false }
        do {
            let _: [String: JSONValue] = try await client.post("api/catalog/refresh")
            await refreshAll()
            present(.success, "Catalogue refreshed from bio.rodeo")
        } catch {
            present(.failure, "Could not refresh the catalogue", error.localizedDescription)
        }
    }

    @discardableResult
    func saveSettings(_ updated: BackendSettings) async -> Bool {
        do {
            let saved: BackendSettings = try await client.put("api/settings", body: updated)
            settings = saved
            await refreshAll()
            return true
        } catch {
            present(.failure, "Settings not saved", error.localizedDescription)
            return false
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingFinished")
        withAnimation(.smooth) { showOnboarding = false }
    }

    // MARK: - Files

    static let openableTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        for ext in ["fasta", "fa", "fna", "faa", "fas", "pdb", "ent", "cif", "mmcif"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.openableTypes
        panel.message = "Choose a FASTA file to predict, or a PDB/mmCIF structure to view."
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    /// FASTA goes to Predict; PDB and mmCIF are imported as results.
    func open(_ urls: [URL]) {
        Task {
            for url in urls {
                await open(url)
            }
        }
    }

    private func open(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 60_000_000 else {
            present(.failure, "Could not read \(url.lastPathComponent)", "The file is missing, unreadable or larger than 60 MB.")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        switch FileKind.detect(url: url, text: text) {
        case .fasta:
            guard let record = FASTA.parse(text).first else {
                present(.failure, "\(url.lastPathComponent) has no sequence")
                return
            }
            loadIntoDraft(record, fallbackName: url.deletingPathExtension().lastPathComponent)
        case .structure:
            await importStructure(name: url.lastPathComponent, text: text)
        case .unknown:
            present(.failure, "Unsupported file", "Drop a FASTA file (.fasta, .fa) or a structure (.pdb, .cif).")
        }
    }

    func loadIntoDraft(_ record: FASTA.Record, fallbackName: String) {
        draft.sequence = record.sequence
        draft.name = record.name.isEmpty ? fallbackName : record.name
        draft.entity = EntityKind.guess(for: record.sequence)
        draft.entityPinned = false
        draft.modelsPinned = false
        reconcileDraftModels()
        withAnimation(.smooth) { screen = .predict }
        present(.info, "Loaded \(draft.name)", "\(draft.cleanedSequence.count) \(draft.entity.unit) · \(draft.entity.label)")
    }

    func importStructure(name: String, text: String) async {
        do {
            let response: CreateJobResponse = try await client.post(
                "api/imports", body: ImportPayload(filename: name, text: text, name: nil)
            )
            details[response.job.id] = response.job
            if !jobs.contains(where: { $0.id == response.job.id }) {
                withAnimation(.smooth) { jobs.insert(Self.summary(of: response.job), at: 0) }
            }
            select(response.job.id)
            present(.success, "Opened \(name)", response.job.result?.confident == true
                ? "Coloured by its pLDDT values."
                : "No confidence values in this file; coloured by secondary structure.")
        } catch {
            present(.failure, "Could not open \(name)", error.localizedDescription)
        }
    }

    private static func summary(of job: Job) -> JobSummary {
        JobSummary(
            id: job.id, kind: job.kind, name: job.name, modelId: job.modelId,
            entityType: job.entityType, length: job.sequence.count, sequenceKey: "",
            seed: job.seed, samples: job.samples, status: job.status, progress: job.progress,
            currentStage: job.currentStage, stageName: nil, stageMessage: nil,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt,
            error: job.error, hint: job.hint, plddt: job.result?.metrics.plddt,
            ptm: job.result?.metrics.ptm, iptm: job.result?.metrics.iptm,
            device: job.result?.device, durationS: job.result?.durationS, warm: job.result?.warm,
            residues: job.result?.residues ?? 0
        )
    }

    // MARK: - Export

    func export(_ id: String, format: String) {
        Task {
            do {
                let payload = try await client.download(jobID: id, format: format)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = payload.filename
                panel.canCreateDirectories = true
                if let type = UTType(filenameExtension: format) { panel.allowedContentTypes = [type] }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try payload.data.write(to: url)
                present(.success, "Saved \(url.lastPathComponent)")
            } catch {
                present(.failure, "Export failed", error.localizedDescription)
            }
        }
    }

    func saveImage(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            present(.success, "Saved \(url.lastPathComponent)")
        } catch {
            present(.failure, "Could not save the image", error.localizedDescription)
        }
    }

    // MARK: - Toasts

    func present(_ kind: Toast.Kind, _ title: String, _ message: String? = nil) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = Toast(kind: kind, title: title, message: message) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .failure ? 7 : 4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(.smooth) { toast = nil }
    }
}
