import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct BackendClient {
    let baseURL: URL
    private let session: URLSession
    private let eventsSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = URL(string: "http://127.0.0.1:8642")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        let eventConfiguration = URLSessionConfiguration.ephemeral
        eventConfiguration.timeoutIntervalForRequest = 3600
        eventConfiguration.timeoutIntervalForResource = 86_400
        eventConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.eventsSession = URLSession(configuration: eventConfiguration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    private func makeURL(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "No response from the backend.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode([String: String].self, from: data),
               let detail = envelope["detail"] {
                throw APIError(status: http.statusCode, message: detail)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError(
                status: http.statusCode,
                message: "Backend error \(http.statusCode). \(body.prefix(200))"
            )
        }
    }

    func health() async throws -> HealthResponse {
        try await get("api/health")
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: 0, message: "Could not read the backend response: \(error.localizedDescription)")
        }
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(T.self, from: data)
    }

    func postEmpty<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(T.self, from: data)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(T.self, from: data)
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    func download(jobID: String, format: String) async throws -> (data: Data, filename: String) {
        var request = URLRequest(url: makeURL("api/jobs/\(jobID)/download/\(format)"))
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        var filename = "dimitri.\(format)"
        if let disposition = (response as? HTTPURLResponse)?.value(
            forHTTPHeaderField: "Content-Disposition"
        ),
           let range = disposition.range(of: "filename=\"") {
            let rest = disposition[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                filename = String(rest[..<end])
            }
        }
        return (data, filename)
    }

    func events(jobID: String) -> AsyncThrowingStream<Job, Error> {
        let url = makeURL("api/jobs/\(jobID)/events")
        let session = self.eventsSession
        let decoder = self.decoder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3600
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw APIError(
                            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                            message: "Live updates unavailable."
                        )
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if let data = payload.data(using: .utf8),
                           let job = try? decoder.decode(Job.self, from: data) {
                            continuation.yield(job)
                        }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
