import Foundation
import NodeGraphCore

/// Sends one HTTP request. A protocol so tests can answer without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real network, through `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse("The server did not answer with HTTP.") }
        return (data, http)
    }
}

/// Why a request to a hosted or local model failed, in words for the person (decision 235).
public enum ProviderError: Error, Hashable, Sendable, LocalizedError {
    case missingKey
    case unauthorized(String)
    case rateLimited(retryAfter: Int?)
    case contextTooLong
    case server(status: Int, message: String)
    case unreachable(String)
    case refused
    case incomplete
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "This model needs an API key. Add one in the model settings."
        case .unauthorized(let message): "The server did not accept the API key. \(message)"
        case .rateLimited(let seconds): "The model is rate limited" + (seconds.map { ", try again in \($0) seconds" } ?? ", try again shortly") + "."
        case .contextTooLong: "The request is too long for this model's context window."
        case .server(let status, let message): "The server answered \(status): \(message)"
        case .unreachable(let host): "Could not reach \(host). Is the server running and the address right?"
        case .refused: "The model declined this request."
        case .incomplete: "The model's answer was cut off."
        case .badResponse(let detail): "The model's answer could not be read. \(detail)"
        }
    }

    /// The error for a non-success response, from the body's own message where it has one.
    static func from(status: Int, data: Data, retryAfter: String?) -> ProviderError {
        let message = Self.message(in: data)
        switch status {
        case 401, 403: return .unauthorized(message)
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        default:
            let lower = message.lowercased()
            if status == 400 || status == 413, lower.contains("context") || lower.contains("too long") || lower.contains("too many tokens") {
                return .contextTooLong
            }
            return .server(status: status, message: message)
        }
    }

    /// `error.message` in the JSON both Claude and OpenAI-style servers use, else the start of the body.
    static func message(in data: Data) -> String {
        if case .object(let top)? = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if case .object(let error)? = top["error"], case .string(let text)? = error["message"] { return text }
            if case .string(let text)? = top["message"] { return text }
            if case .string(let text)? = top["error"] { return text }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.isEmpty ? "no details" : text
    }

    /// A failure to connect, as `unreachable` naming the host; any other error passes through.
    static func wrap(_ error: any Error, host: String) -> any Error {
        guard let url = error as? URLError else { return error }
        switch url.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut, .dnsLookupFailed:
            return ProviderError.unreachable(host)
        default: return error
        }
    }
}
