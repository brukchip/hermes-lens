import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error answer from the Hermes Lens plugin: the HTTP status and the fixed
/// `{"error": {"code": ...}}` code. Never carries server text.
public struct LunaServerError: Error, Equatable, Sendable {
    public let status: Int
    public let code: String?

    public init(status: Int, code: String?) {
        self.status = status; self.code = code
    }

    /// Reads the code from an error body; anything that is not a short code is ignored.
    public init(status: Int, body: Data) {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let code = (object?["error"] as? [String: Any])?["code"] as? String
        self.init(status: status, code: code.flatMap { code in
            code.count <= 64 && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? code : nil
        })
    }

    /// The approval card is gone on the server: it expired (two minutes) or its turn ended.
    public var isExpiredApproval: Bool { status == 404 && code == "native_approval_not_found" }

    /// What Luna is told when a back-office request (or its photos) fails with this answer.
    public var spokenFailure: String {
        if status == 401 || status == 403 {
            return "Luna's server no longer accepts this phone's access token. Tell the user to check the token in Settings."
        }
        switch code {
        case "native_call_not_found":
            return "This call has already ended on the server. Tell the user to start a new call."
        case "native_photo_not_found":
            return "The photos from this call are no longer on the server. Take a new one with look, then ask again."
        case "native_photo_size":
            return "The photo was too large for the server. Tell the user briefly; a new look may work."
        case "native_photo_type", "native_photo_invalid":
            return "The server could not read the photo. Tell the user briefly; a new look may work."
        case "native_photo_limit":
            return "Only four photos can go with requests in one call. Tell the user to start a new call to send more."
        case "rate_limited":
            return "Luna's server is getting too many requests. Tell the user to wait a minute, then ask again."
        case "native_tool_in_progress":
            return "That request is still running. Wait for its result instead of asking again."
        case "native_tool_size", "native_tool_invalid":
            return "The server did not accept the request as worded. Rephrase it more briefly, without a leading slash, and ask again."
        case "native_tool_unknown":
            return "That request is not available in this call."
        default:
            return "Luna's back office had a problem with that request. Tell the user briefly; they can try again."
        }
    }
}

public extension LunaNativeError {
    /// The user-facing error for a refused call set-up, from the plugin's status and code.
    init(_ error: LunaServerError) {
        if error.status == 401 || error.status == 403 { self = .wrongToken; return }
        switch error.code {
        case "native_voice_unavailable": self = .unavailable
        case "native_provider_unavailable": self = .providerKeyRefused
        case "native_configuration_invalid": self = .serverSetup
        case "native_connection_failed", "native_provider_response_invalid": self = .providerUnreachable
        case "native_usage_limit": self = .usageLimit
        case "rate_limited", "native_call_limit": self = .rateLimited
        default:
            switch error.status {
            case 409: self = .activeCall
            case 429: self = .usageLimit
            case 404 where error.code == nil: self = .notLensServer
            case 400, 413, 415: self = .incompatible
            default: self = .connection
            }
        }
    }

    /// Trying again at once cannot help: the user (or the server's owner) must change something.
    var isLasting: Bool {
        switch self {
        case .unavailable, .microphone, .usageLimit, .serverUnreachable, .microphoneBusy, .wrongToken,
             .providerKeyRefused, .serverSetup, .incompatible, .notLensServer: true
        case .connection, .invalidResponse, .activeCall, .audioBacklog, .microphoneSilent, .rateLimited,
             .providerUnreachable: false
        }
    }
}

/// Why Luna's server can't be used, from a failed health or settings check.
public enum HermesServerProblem: Equatable, Sendable {
    case wrongToken, unreachable, notLensServer, serverError(Int), unexpectedResponse

    /// nil for set-up problems that already explain themselves (bad address, missing token).
    public init?(_ error: Error) {
        if let error = error as? HermesClientError {
            switch error {
            case .httpStatus(401), .httpStatus(403): self = .wrongToken
            case .httpStatus(404): self = .notLensServer
            case .httpStatus(let status): self = .serverError(status)
            case .unexpectedResponse: self = .unexpectedResponse
            case .invalidBaseURL, .insecureEndpoint, .missingToken: return nil
            }
        } else if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            self = .unreachable
        } else if error is DecodingError {
            self = .unexpectedResponse
        } else {
            return nil
        }
    }

    public var message: String {
        switch self {
        case .wrongToken: "Luna's server didn't accept the access token. Check the token in Settings."
        case .unreachable: "Luna's server can't be reached. Check your connection to your Hermes server, then try again."
        case .notLensServer: "That address doesn't answer like a Hermes Lens server. Check the server address in Settings."
        case .serverError(let status): "Luna's server returned an error (\(status)). Try again in a moment."
        case .unexpectedResponse: "Luna's server sent an unexpected response. Check that the Hermes Lens plugin is up to date."
        }
    }

    /// The fix is in Settings (token or address), not a retry.
    public var needsSettings: Bool { self == .wrongToken || self == .notLensServer }
}
