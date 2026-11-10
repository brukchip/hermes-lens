import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The two plain HTTP routes the app reads from the Hermes Lens plugin. Live calls,
/// tools and approvals go through `LunaNativeBrokerClient`.
public protocol HermesClient: Sendable {
    func health() async throws -> HermesHealth
    func lensConfiguration() async throws -> HermesLensConfiguration
}

public enum HermesClientError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case insecureEndpoint
    case missingToken
    case unexpectedResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Luna's server address is invalid."
        case .insecureEndpoint: "Live connections must use HTTPS."
        case .missingToken: "Luna's access token is missing."
        case .unexpectedResponse: "Luna sent an unexpected response."
        case .httpStatus(401), .httpStatus(403): "Luna's server did not accept the access token. Check it in Settings."
        case .httpStatus(let status): "Luna's server returned an error (\(status))."
        }
    }
}

public struct HermesEndpointConfiguration: Hashable, Sendable {
    public var baseURL: URL
    public var token: String
    public var sessionKey: String
    public var deviceID: UUID

    public init(
        baseURL: URL,
        token: String,
        sessionKey: String = "hermes-lens",
        deviceID: UUID
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(), baseURL.host != nil else {
            throw HermesClientError.invalidBaseURL
        }

        let isLocal = baseURL.host == "localhost" || baseURL.host == "127.0.0.1"
        guard scheme == "https" || (isLocal && scheme == "http") else {
            throw HermesClientError.insecureEndpoint
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HermesClientError.missingToken
        }

        self.baseURL = baseURL
        self.token = token
        self.sessionKey = sessionKey
        self.deviceID = deviceID
    }

    public func url(path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

public actor LiveHermesClient: HermesClient {
    private let configuration: HermesEndpointConfiguration
    private let session: URLSession

    public init(
        configuration: HermesEndpointConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func health() async throws -> HermesHealth {
        var request = URLRequest(url: configuration.url(path: "health"))
        request.httpMethod = "GET"
        identify(&request)
        authorize(&request)
        let (_, response) = try await session.data(for: request)
        let status = try validatedStatus(response)
        return HermesHealth(isHealthy: status == 200, detail: "Luna is online.")
    }

    public func lensConfiguration() async throws -> HermesLensConfiguration {
        var request = URLRequest(url: configuration.url(path: "v1/lens/config"))
        request.httpMethod = "GET"
        identify(&request)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        _ = try validatedStatus(response)
        return try JSONDecoder.hermes.decode(HermesLensConfiguration.self, from: data)
    }

    private func identify(_ request: inout URLRequest) {
        request.setValue(configuration.sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        request.setValue(configuration.deviceID.uuidString, forHTTPHeaderField: "X-Hermes-Device-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
    }

    private func validatedStatus(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.unexpectedResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw HermesClientError.httpStatus(http.statusCode)
        }
        return http.statusCode
    }
}

public extension JSONEncoder {
    static var hermes: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var hermes: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp."
            )
        }
        return decoder
    }
}
