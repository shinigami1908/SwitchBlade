import Foundation

enum ServiceError: LocalizedError {
    case missingKey(String)
    case badURL
    case http(Int, String)
    case decoding(String)
    case noResults(String)
    case budgetExhausted(Int)
    case refused(String?)
    case cancelled

    /// Pulls `error.message` out of a provider's JSON error envelope.
    private static func message(fromBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }

        if let status = error["status"] as? String {
            return "\(message) [\(status)]"
        }
        return message
    }

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "No \(provider) API key configured."
        case .badURL:
            return "Could not build a valid request URL."
        case .http(let code, let body):
            // Provider errors put the useful part deep in a JSON envelope, so
            // a short prefix reliably truncates exactly the message you need.
            let detail = ServiceError.message(fromBody: body) ?? String(body.prefix(300))
            return "Request failed (\(code)). \(detail)"
        case .decoding(let detail):
            return "Unexpected response format. \(detail)"
        case .noResults(let query):
            return "Nothing found for “\(query)”."
        case .budgetExhausted(let limit):
            return "Daily AI limit reached (\(limit) calls). Resets at midnight."
        case .refused(let reason):
            // A safety filter declined the request. It arrives as a successful
            // response, so it needs its own message rather than an HTTP error.
            guard let reason else { return "The model declined this request." }
            return "The model declined this request (\(reason))."
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Thin shared wrapper over URLSession. Every provider funnels through here so
/// timeouts, status handling, and retry behaviour are defined in one place.
struct HTTPClient: Sendable {
    static let shared = HTTPClient()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        // Provider responses are stable for the life of an entry; let the URL
        // cache absorb repeats rather than re-hitting the network.
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        self.session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.http(-1, "Non-HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.http(http.statusCode, body)
        }

        return data
    }

    /// Sends a fully-formed request. Needed by providers whose bodies aren't
    /// JSON — IGDB's query language is plain text.
    func send<T: Decodable>(
        _ request: URLRequest,
        as type: T.Type
    ) async throws -> T {
        let data = try await data(for: request)
        return try decode(type, from: data)
    }

    func get<T: Decodable>(_ url: URL, as type: T.Type, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await data(for: request)
        return try decode(type, from: data)
    }

    func postJSON<T: Decodable>(
        _ url: URL,
        body: [String: Any],
        as type: T.Type,
        headers: [String: String] = [:]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await self.data(for: request)
        return try decode(type, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }
}

extension URL {
    /// Builds a URL with query items, percent-encoding values correctly.
    static func build(_ base: String, _ items: [String: String?]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let queryItems = items.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems.sorted { $0.name < $1.name }
        }
        return components.url
    }
}
