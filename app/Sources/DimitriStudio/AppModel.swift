import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var runners: [RunnerManifest] = []
    @Published private(set) var catalog: [CatalogEntry] = []
    @Published private(set) var catalogSources: CatalogSources?
    @Published private(set) var status: StatusResponse?
    @Published private(set) var settings: BackendSettings?
    @Published var selectedJobID: String?
    @Published private(set) var connected = false
    @Published private(set) var connectionDetail = "Connecting to the local backend…"
    @Published var banner: String?
    @Published private(set) var savingSettings = false
    @Published private(set) var refreshingCatalog = false

    private let client = BackendClient()
    private var pollTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var structureCache: [String: String] = [:]
    private var refreshGeneration = 0

    init() {
        startPolling()
    }

    // MARK: - Connection

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll(quiet: true)
                let interval: UInt64 = self?.connected == true ? 5_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func refreshAll(quiet: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            async let statusTask: StatusResponse = client.get("api/status")
            async let catalogTask: CatalogResponse = client.get("api/models")
            async let jobsTask: [Job] = client.get("api/jobs")
            async let runnersTask: [RunnerManifest] = client.get("api/runners")
            let (newStatus, newCatalog, newJobs, newRunners) = try await (
                statusTask, catalogTask, jobsTask, runnersTask
            )
            guard generation == refreshGeneration else { return }
            status = newStatus
            catalog = newCatalog.entries
            catalogSources = newCatalog.sources
            jobs = newJobs
            runners = newRunners
            connected = true
            connectionDetail = "Backend \(newStatus.version) · Python \(newStatus.python)"
            if settings == nil {
                settings = try? await client.get("api/settings")
            }
            reconcileSelection()
        } catch {
            connected = false
            connectionDetail = "Backend offline. Start it with ./scripts/run-backend.sh"
            if !quiet {
                banner = error.localizedDescription
            }
        }
    }

    func refreshJobs() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let newJobs: [Job] = try await client.get("api/jobs")
            guard generation == refreshGeneration else { return }
            jobs = newJobs
            connected = true
            reconcileSelection()
        } catch {
            connected = false
            connectionDetail = "Backend offline. Start it with ./scripts/run-backend.sh"
        }
    }

    private func reconcileSelection() {
        let available = predictions
        if let id = selectedJobID, !available.contains(where: { $0.id == id }) {
            selectedJobID = available.first?.id
        } else if selectedJobID == nil {
            selectedJobID = available.first?.id
        }
    }

    var predictions: [Job] {
        jobs.filter { $0.kind == "predict" }
    }

    var selectedJob: Job? {
        guard let id = selectedJobID else { return nil }
        return predictions.first(where: { $0.id == id })
    }

    func job(id: String) -> Job? {
        jobs.first(where: { $0.id == id })
    }

    // MARK: - Predictions

    func submitPrediction(
        modelID: String,
        entity: EntityKind,
        sequence: String,
        seed: Int,
        samples: Int
    ) async -> Job? {
        banner = nil
        let payload = PredictionPayload(
            modelId: modelID,
            entityType: entity.rawValue,
            sequence: sequence,
            name: "\(entity.label) fold",
            seed: seed,
            samples: samples
        )
        do {
            let response: CreateJobResponse = try await client.post("api/jobs", body: payload)
            jobs.insert(response.job, at: 0)
            selectedJobID = response.job.id
            watch(jobID: response.job.id)
            return response.job
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    func cancel(jobID: String) async {
        do {
            let _: [String: Bool] = try await client.postEmpty("api/jobs/\(jobID)/cancel")
            await refreshJobs()
        } catch {
            banner = error.localizedDescription
        }
    }

    func delete(jobID: String) async {
        do {
            try await client.delete("api/jobs/\(jobID)")
            structureCache[jobID] = nil
            await refreshJobs()
        } catch {
            banner = error.localizedDescription
        }
    }

    func watch(jobID: String) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled {
                do {
                    for try await job in self.client.events(jobID: jobID) {
                        self.merge(job)
                        if job.isTerminal { break }
                    }
                    if self.job(id: jobID)?.isTerminal == true { break }
                } catch {
                    if Task.isCancelled { break }
                }
                if self.job(id: jobID) == nil { break }
                if self.job(id: jobID)?.isTerminal == true { break }
                failures += 1
                if failures > 30 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await self.refreshJobs()
        }
    }

    private func merge(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    // MARK: - Library

    func install(_ entry: CatalogEntry) async {
        banner = nil
        do {
            let response: CreateJobResponse = try await client.postEmpty(
                "api/models/\(entry.id)/install"
            )
            merge(response.job)
            watch(jobID: response.job.id)
            banner = "Installing \(entry.name). Progress is shown in the Library."
        } catch {
            banner = error.localizedDescription
        }
    }

    func refreshCatalog() async {
        refreshingCatalog = true
        defer { refreshingCatalog = false }
        do {
            let _: [String: JSONValue] = try await client.postEmpty("api/catalog/refresh")
            await refreshAll(quiet: true)
            banner = "Catalog refreshed from bio.rodeo."
        } catch {
            banner = error.localizedDescription
        }
    }

    func installJob(for entry: CatalogEntry) -> Job? {
        guard let runnerID = entry.runnerId else { return nil }
        let latest = jobs.first { $0.kind == "install" && $0.modelId == runnerID }
        guard let latest else { return nil }
        return (latest.isRunning || latest.status == "failed") ? latest : nil
    }

    // MARK: - Structures and exports

    func structureText(jobID: String) async -> String? {
        if let cached = structureCache[jobID] { return cached }
        do {
            let (data, _) = try await client.download(jobID: jobID, format: "cif")
            guard !Task.isCancelled else { return nil }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            structureCache[jobID] = text
            return text
        } catch {
            if Task.isCancelled { return nil }
            banner = error.localizedDescription
            return nil
        }
    }

    func export(jobID: String, format: String) async -> (data: Data, filename: String)? {
        do {
            return try await client.download(jobID: jobID, format: format)
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    // MARK: - Settings

    func saveSettings(_ updated: BackendSettings) async -> Bool {
        savingSettings = true
        defer { savingSettings = false }
        do {
            let saved: BackendSettings = try await client.put("api/settings", body: updated)
            settings = saved
            await refreshAll(quiet: true)
            banner = "Settings saved."
            return true
        } catch {
            banner = error.localizedDescription
            return false
        }
    }

    func statusEntry(for entry: CatalogEntry) -> RunnerStatus? {
        guard let runnerID = entry.runnerId else { return nil }
        return status?.runners.first(where: { $0.id == runnerID })
    }

    func runner(for job: Job) -> RunnerManifest? {
        runners.first(where: { $0.id == job.modelId })
    }

    // MARK: - Helpers

    func present(_ message: String) {
        banner = message
    }

    var totalJobsRunning: Int {
        predictions.filter { $0.isRunning }.count
    }
}

/// Minimal JSON value used when a response is not modelled.
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSONValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
