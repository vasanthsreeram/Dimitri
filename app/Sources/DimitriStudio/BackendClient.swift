import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Typed HTTP client for the local backend, plus its server-sent event stream.
struct BackendClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let eventsSession: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
        let eventConfiguration = URLSessionConfiguration.ephemeral
        eventConfiguration.timeoutIntervalForRequest = 3600
        eventConfiguration.timeoutIntervalForResource = 7 * 86_400
        eventConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.eventsSession = URLSession(configuration: eventConfiguration)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "No response from the backend.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = envelope["detail"] {
                if let text = detail as? String {
                    throw APIError(status: http.statusCode, message: text)
                }
                if let list = detail as? [[String: Any]],
                   let message = list.first?["msg"] as? String {
                    throw APIError(status: http.statusCode, message: message)
                }
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError(
                status: http.statusCode,
                message: "Backend error \(http.statusCode). \(body.prefix(200))"
            )
        }
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        do {
            return try Self.decoder().decode(T.self, from: data)
        } catch {
            throw APIError(
                status: 0,
                message: "Could not read the backend response: \(error.localizedDescription)"
            )
        }
    }

    func get<T: Decodable>(_ path: String, timeout: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: url(path))
        if let timeout { request.timeoutInterval = timeout }
        return try await send(request)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder().encode(body)
        return try await send(request)
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        return try await send(request)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder().encode(body)
        return try await send(request)
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: url(path))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    /// Structure text exactly as the model wrote it, with its format.
    func structure(jobID: String) async throws -> (text: String, format: String) {
        let (data, response) = try await session.data(for: URLRequest(url: url("api/jobs/\(jobID)/structure")))
        try check(response, data)
        let format = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Structure-Format") ?? "pdb"
        return (String(decoding: data, as: UTF8.self), format)
    }

    func download(jobID: String, format: String) async throws -> (data: Data, filename: String) {
        var request = URLRequest(url: url("api/jobs/\(jobID)/download/\(format)"))
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        var filename = "dimitri.\(format)"
        if let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=\"") {
            let rest = disposition[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                filename = String(rest[..<end])
            }
        }
        return (data, filename)
    }

    /// The app-wide event stream: one snapshot, then only changes.
    func events() -> AsyncThrowingStream<BackendEvent, Error> {
        let request: URLRequest = {
            var request = URLRequest(url: url("api/events"))
            request.timeoutInterval = 3600
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return request
        }()
        let session = eventsSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Live updates unavailable.")
                    }
                    let decoder = Self.decoder()
                    var kind: String?
                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            kind = String(line.dropFirst(7))
                            continue
                        }
                        guard line.hasPrefix("data: "), let current = kind else { continue }
                        kind = nil
                        let data = Data(line.dropFirst(6).utf8)
                        switch current {
                        case "snapshot":
                            if let value = try? decoder.decode(EventSnapshot.self, from: data) {
                                continuation.yield(.snapshot(value))
                            }
                        case "job":
                            if let value = try? decoder.decode(JobEvent.self, from: data) {
                                continuation.yield(.job(value))
                            }
                        case "deleted":
                            if let value = try? decoder.decode(DeletedEvent.self, from: data) {
                                continuation.yield(.deleted(value.id))
                            }
                        case "runners":
                            if let value = try? decoder.decode(RunnersEvent.self, from: data) {
                                continuation.yield(.runners(value))
                            }
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
