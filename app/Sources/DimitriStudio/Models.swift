import Foundation

// Codable mirror of the backend API (snake_case keys are converted). The app
// decodes only what it uses, so new backend fields never break it.

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
    var isPending: Bool { status == "pending" }
}

struct Metrics: Codable, Hashable {
    let plddt: Double?
    let ptm: Double?
    let iptm: Double?
}

struct JobResult: Codable, Hashable {
    let modelId: String
    let modelName: String
    let metrics: Metrics
    let perResiduePlddt: [Double]
    let paeSize: Int?
    let paeNote: String?
    let residues: Int
    let atoms: Int
    let chains: Int
    let models: Int?
    let polymerTypes: [String]?
    let format: String
    let hasConfidence: Bool?
    let device: String?
    let durationS: Double?
    let warm: Bool?
    let timings: [String: Double]?
    let peakMemoryGb: Double?
    let note: String?
    let extra: [String: JSONValue]?

    var dotBracket: String? {
        if case .string(let value)? = extra?["dot_bracket"] { return value }
        return nil
    }

    var confident: Bool { hasConfidence ?? !perResiduePlddt.isEmpty }
}

/// Full job record (GET /api/jobs/{id}).
struct Job: Codable, Identifiable, Hashable {
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

    var isTerminal: Bool { JobStatus.isTerminal(status) }
    var isActive: Bool { status == "running" || status == "queued" }
}

/// Light job record for lists and the live event stream.
struct JobSummary: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
    let modelId: String
    let entityType: String
    let length: Int
    let sequenceKey: String
    let seed: Int
    let samples: Int
    var status: String
    var progress: Double
    var currentStage: String?
    var stageName: String?
    var stageMessage: String?
    let createdAt: Double
    var startedAt: Double?
    var finishedAt: Double?
    var error: String?
    var hint: String?
    var plddt: Double?
    var ptm: Double?
    var iptm: Double?
    var device: String?
    var durationS: Double?
    var warm: Bool?
    var residues: Int

    var isTerminal: Bool { JobStatus.isTerminal(status) }
    var isActive: Bool { status == "running" || status == "queued" }
    var isCompleted: Bool { status == "completed" }
    var isImport: Bool { kind == "import" }
    var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
    var startedDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0) } }
    var finishedDate: Date? { finishedAt.map { Date(timeIntervalSince1970: $0) } }
}

enum JobStatus {
    static func isTerminal(_ status: String) -> Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }
}

/// Live stages and the latest log lines of a job, from the event stream.
struct JobLive: Hashable {
    var stages: [Stage]
    var log: [String]
}

// MARK: - Live events

struct EventSnapshot: Codable {
    let jobs: [JobSummary]
    let version: Int
}

struct JobEvent: Codable {
    let summary: JobSummary
    let stages: [Stage]
    let log: [String]
}

struct DeletedEvent: Codable {
    let id: String
}

struct RunnersEvent: Codable {
    let runners: [RunnerStatus]
    let workers: [WorkerStatus]
}

enum BackendEvent {
    case snapshot(EventSnapshot)
    case job(JobEvent)
    case deleted(String)
    case runners(RunnersEvent)
}

// MARK: - Runners, catalogue, device

struct RunnerManifest: Codable, Identifiable, Hashable {
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
    let warmCapable: Bool?
}

struct RunnerStatus: Codable, Identifiable, Hashable {
    let id: String
    let installed: Bool
    let ready: Bool
    let weightsPresent: Bool
    let detail: String
    let paths: [String: String]
    let warm: Bool?
    let version: String?
}

struct WorkerStatus: Codable, Identifiable, Hashable {
    var id: String { runnerId }
    let runnerId: String
    let state: String
    let pid: Int?
    let startedAt: Double
    let lastUsed: Double
    let jobsServed: Int
    let loadS: Double?
    let device: String?
    let rssMb: Double?
    let detail: String?
}

struct CatalogEntry: Codable, Identifiable, Hashable {
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
    let statusDetail: String?
    let warm: Bool?

    var modelID: String { runnerId ?? id }
}

struct CatalogResponse: Codable {
    let entries: [CatalogEntry]
    let sources: CatalogSources
}

struct CatalogSources: Codable, Hashable {
    let local: SourceInfo?
    let bioRodeo: BioRodeoSource?
}

struct SourceInfo: Codable, Hashable {
    let file: String?
    let entries: Int?
}

struct BioRodeoSource: Codable, Hashable {
    let baseUrl: String?
    let fetchedAt: Double?
    let entries: Int?
    let mode: String?
    let api: String?
    let note: String?
}

struct DiskUsage: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let bytes: Int
    let exists: Bool
}

struct LmStudioStatus: Codable, Hashable {
    let reachable: Bool
    let baseUrl: String
    let models: [String]
    let detail: String
}

struct DeviceInfo: Codable, Hashable {
    let chip: String
    let memoryGb: Double
    let performanceCores: Int?
    let efficiencyCores: Int?
    let macos: String
    let tier: String
    let tierLabel: String
    let keepWarmMinutes: Int
    let maxResidentModels: Int
    let gpuBudgetGb: Double
    let mlxCacheLimitGb: Double
    let notes: [String]
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
    let bioRodeo: BioRodeoSource?
    let device: DeviceInfo?
    let workers: [WorkerStatus]?
}

struct BackendSettings: Codable, Equatable {
    var home: String
    var modelsDir: String
    var resultsDir: String
    var cacheDir: String
    var lmsBaseUrl: String
    var af3Repo: String
    var af3WeightsDir: String
    var macAf3Repo: String
    var rhofoldRepo: String
    var openfold3Repo: String
    var openfold3Cache: String
    var bioRodeoCacheHours: Int
    var warmWorkers: Bool
    var keepWarmMinutes: Int?

    // keep_warm_minutes is null for "follow the device"; encode the null too.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(home, forKey: .home)
        try container.encode(modelsDir, forKey: .modelsDir)
        try container.encode(resultsDir, forKey: .resultsDir)
        try container.encode(cacheDir, forKey: .cacheDir)
        try container.encode(lmsBaseUrl, forKey: .lmsBaseUrl)
        try container.encode(af3Repo, forKey: .af3Repo)
        try container.encode(af3WeightsDir, forKey: .af3WeightsDir)
        try container.encode(macAf3Repo, forKey: .macAf3Repo)
        try container.encode(rhofoldRepo, forKey: .rhofoldRepo)
        try container.encode(openfold3Repo, forKey: .openfold3Repo)
        try container.encode(openfold3Cache, forKey: .openfold3Cache)
        try container.encode(bioRodeoCacheHours, forKey: .bioRodeoCacheHours)
        try container.encode(warmWorkers, forKey: .warmWorkers)
        try container.encode(keepWarmMinutes, forKey: .keepWarmMinutes)
    }
}

struct CreateJobResponse: Codable {
    let job: Job
}

struct CreateJobsResponse: Codable {
    let jobs: [Job]
}

struct HealthResponse: Codable {
    let status: String
    let app: String?
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

struct BatchPredictionPayload: Codable {
    let modelIds: [String]
    let entityType: String
    let sequence: String
    let name: String
    let seed: Int
    let samples: Int
}

struct ImportPayload: Codable {
    let filename: String
    let text: String
    let name: String?
}

struct PaeMatrix: Codable, Hashable {
    let size: Int
    let stride: Int
    let matrix: [[Double]]
    let note: String?
}

struct Comparison: Codable, Hashable {
    let referenceId: String
    let otherId: String
    let rmsd: Double
    let aligned: Int
    let atoms: String
    let perResidueDistance: [Double?]
    let movedText: String
    let movedFormat: String
}

/// Minimal JSON value for loosely typed fields.
enum JSONValue: Codable, Hashable {
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

// MARK: - Inputs

enum EntityKind: String, CaseIterable, Identifiable, Codable {
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
        case .rna: return "waveform.path"
        case .dna: return "line.3.crossed.swirl.circle"
        case .ligand: return "hexagon"
        }
    }

    var unit: String {
        switch self {
        case .protein: return "aa"
        case .rna, .dna: return "nt"
        case .ligand: return "chars"
        }
    }

    var alphabet: Set<Character>? {
        switch self {
        case .protein: return Set("ACDEFGHIKLMNPQRSTVWYX")
        case .rna: return Set("ACGU")
        case .dna: return Set("ACGT")
        case .ligand: return nil
        }
    }

    /// Best guess from the letters alone; used when text is pasted or dropped.
    static func guess(for sequence: String) -> EntityKind {
        let letters = Set(sequence.uppercased().filter { $0.isLetter })
        guard !letters.isEmpty else { return .protein }
        if sequence.contains(where: { "()[]=#@+\\/%".contains($0) }) { return .ligand }
        if letters.isSubset(of: Set("ACGU")), letters.contains("U") { return .rna }
        if letters.isSubset(of: Set("ACGT")), letters.contains("T") { return .dna }
        if letters.isSubset(of: Set("ACGUN")) { return .rna }
        return .protein
    }
}

/// Built-in examples, small enough to finish in seconds.
struct SequenceExample: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let entity: EntityKind
    let sequence: String

    static let all: [SequenceExample] = [
        SequenceExample(
            id: "6tb7",
            title: "52-nt RNA (PDB 6TB7, chain A)",
            detail: "rhofold-mac's sample · folds in seconds with RhoFold+",
            entity: .rna,
            sequence: "GGCUUCAACAACCCCGUAGGUUGGGCCGAAAGGCAGCGAAUCUACUGGAGCC"
        ),
        SequenceExample(
            id: "1l2y",
            title: "Trp-cage miniprotein (PDB 1L2Y)",
            detail: "20 residues · a classic fast-folding protein",
            entity: .protein,
            sequence: "NLYIQWLKDGGPSSGRPPPS"
        ),
    ]
}

// MARK: - Formatting

enum Format {
    static func bytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func score(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    static func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 10 { return String(format: "%.1f s", value) }
        if value < 120 { return String(format: "%.0f s", value) }
        let minutes = Int(value) / 60
        let rest = Int(value) % 60
        return "\(minutes) min \(rest) s"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func elapsed(since date: Date, until end: Date = Date()) -> String {
        let seconds = max(0, end.timeIntervalSince(date))
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return minutes > 0 ? String(format: "%d:%02d", minutes, rest) : String(format: "0:%02d", rest)
    }
}
