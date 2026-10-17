import Foundation

// MARK: - Jobs

struct Stage: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var status: String
    var progress: Double
    var message: String?

    var isDone: Bool { status == "done" || status == "skipped" }
    var isFailed: Bool { status == "failed" }
    var isRunning: Bool { status == "running" }
}

struct Metrics: Codable {
    let plddt: Double?
    let ptm: Double?
    let iptm: Double?
}

struct JobResult: Codable {
    let modelId: String
    let modelName: String
    let metrics: Metrics
    let perResiduePlddt: [Double]
    let pae: [[Double]]?
    let paeNote: String?
    let residues: Int
    let atoms: Int
    let chains: Int
    let format: String
    let device: String?
    let durationS: Double?
    let version: String
    let note: String?
}

struct Job: Codable, Identifiable {
    let id: String
    let kind: String
    let name: String
    let modelId: String
    let entityType: String
    let sequence: String
    let seed: Int
    let samples: Int
    let status: String
    let progress: Double
    let currentStage: String?
    let stages: [Stage]
    let createdAt: Double
    let startedAt: Double?
    let finishedAt: Double?
    let error: String?
    let hint: String?
    let result: JobResult?
    let logTail: [String]

    var isTerminal: Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }
    var isRunning: Bool { status == "running" || status == "queued" }
    var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
}

// MARK: - Runners and catalog

struct RunnerManifest: Codable, Identifiable {
    let id: String
    let name: String
    let shortName: String
    let version: String
    let description: String
    let entityTypes: [String]
    let sourceUrl: String
    let runtime: String?
    let device: String?
    let fallback: String?
    let citation: String?
    let license: String?
    let weightNote: String?
    let weightRequestUrl: String?
    let weightDir: String?
    let requiresWeights: Bool
    let setupHint: String?
    let stages: [Stage]
    let visible: Bool
}

struct RunnerStatus: Codable, Identifiable {
    let id: String
    let installed: Bool
    let ready: Bool
    let weightsPresent: Bool
    let detail: String
    let paths: [String: String]
}

struct CatalogEntry: Codable, Identifiable {
    let id: String
    let name: String
    let runnerId: String?
    let provider: String?
    let description: String
    let tags: [String]
    let license: String?
    let openness: Int?
    let source: String
    let sourceUrl: String?
    let entityTypes: [String]
    let runtime: String?
    let device: String?
    let fallback: String?
    let installed: Bool
    let ready: Bool
    let installable: Bool
    let sizeBytes: Int
    let weightNote: String?
    let weightRequestUrl: String?
    let weightDir: String?
}

struct CatalogResponse: Codable {
    let entries: [CatalogEntry]
    let sources: CatalogSources
}

struct CatalogSources: Codable {
    let local: SourceInfo?
    let bioRodeo: BioRodeoSource?
}

struct SourceInfo: Codable {
    let file: String?
    let entries: Int?
}

struct BioRodeoSource: Codable {
    let baseUrl: String?
    let fetchedAt: Double?
    let entries: Int?
    let mode: String?
    let api: String?
    let note: String?
}

struct DiskUsage: Codable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int
    let exists: Bool
}

struct LmStudioStatus: Codable {
    let reachable: Bool
    let baseUrl: String
    let models: [String]
    let detail: String
}

struct StatusResponse: Codable {
    let status: String
    let version: String
    let python: String
    let platform: String
    let backendUrl: String
    let storage: [DiskUsage]
    let lmStudio: LmStudioStatus
    let runners: [RunnerStatus]
    let activeJobs: Int
    let bioRodeo: BioRodeoSource
}

struct BackendSettings: Codable {
    var home: String
    var modelsDir: String
    var resultsDir: String
    var cacheDir: String
    var lmsBaseUrl: String
    var af3Repo: String
    var af3WeightsDir: String
    var rhofoldRepo: String
    var openfold3Repo: String
    var openfold3Cache: String
    var bioRodeoCacheHours: Int
}

struct CreateJobResponse: Codable {
    let job: Job
}

struct HealthResponse: Codable {
    let status: String
    let version: String
    let python: String
    let platform: String
}

struct PredictionPayload: Codable {
    let modelId: String
    let entityType: String
    let sequence: String
    let name: String
    let seed: Int
    let samples: Int
}

// MARK: - Display helpers

enum EntityKind: String, CaseIterable, Identifiable {
    case protein, rna, dna, ligand
    var id: String { rawValue }
    var label: String {
        switch self {
        case .protein: return "Protein"
        case .rna: return "RNA"
        case .dna: return "DNA"
        case .ligand: return "Ligand"
        }
    }
    var symbol: String {
        switch self {
        case .protein: return "circle.hexagongrid"
        case .rna: return "waveform.path.ecg"
        case .dna: return "allergens"
        case .ligand: return "hexagon"
        }
    }
    var placeholder: String {
        switch self {
        case .protein: return "MKTAYIAKQRQISFVKSHFSRQDILDLWQ"
        case .rna: return "GGGAAACCCGGGAAACCC"
        case .dna: return "GGGAAACCCGGGAAACCC"
        case .ligand: return "ATP"
        }
    }
    var alphabet: Set<Character>? {
        switch self {
        case .protein: return Set("ACDEFGHIKLMNPQRSTVWYXBZUO")
        case .rna: return Set("ACGU")
        case .dna: return Set("ACGT")
        case .ligand: return nil
        }
    }
}

func formatBytes(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: Int64(bytes))
}

func formatPercent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.2f", value)
}

func formatScore(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.1f", value)
}

func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
