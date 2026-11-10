import Foundation
import Testing
@testable import HermesLensCore

private final class NativeStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class NativeRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) -> Int {
        lock.withLock { requests.append(request); return requests.count }
    }
    var values: [URLRequest] { lock.withLock { requests } }
}

@Suite(.serialized) struct LunaNativeBrokerTests {
    private func broker() throws -> LunaNativeBrokerClient {
        let configuration = try HermesEndpointConfiguration(
            baseURL: URL(string: "https://native.example.test")!, token: "fixture-device-token",
            sessionKey: "hermes-lens", deviceID: UUID())
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [NativeStub.self]
        return LunaNativeBrokerClient(configuration: configuration, session: URLSession(configuration: session))
    }

    private func grant() throws -> Data {
        let format = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: [
            "protocol": LunaNativeVoice.protocolName, "callID": UUID().uuidString,
            "token": "auth_tokens/fixture", "websocketURL": LunaNativeVoice.socket,
            "model": LunaNativeVoice.model, "maxSeconds": 540,
            "expiresAt": format.string(from: .now.addingTimeInterval(540)),
            "newSessionExpiresAt": format.string(from: .now.addingTimeInterval(60))
        ])
    }

    @Test func retriesOnlyOneLostRequestUsingSameIdentity() async throws {
        let client = try broker()
        let requests = NativeRequests()
        let data = try grant()
        NativeStub.handler = { request in
            if requests.append(request) == 1 { throw URLError(.networkConnectionLost) }
            return (200, data)
        }
        defer { NativeStub.handler = nil }
        let id = UUID()
        let call = try await client.create(requestID: id)
        #expect(call.protocolName == "luna.native.v2")
        #expect(requests.values.count == 2)
        for request in requests.values {
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-device-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.url?.path == "/v1/lens/realtime/calls")
        }
        #expect(call.socketRequest().value(forHTTPHeaderField: "Authorization") != "Bearer fixture-device-token")
    }

    @Test func retriesFailedCloseBeforeMintingReplacement() async throws {
        let client = try broker()
        let requests = NativeRequests()
        let data = try grant()
        NativeStub.handler = { request in
            if requests.append(request) == 1 { throw URLError(.networkConnectionLost) }
            return request.httpMethod == "DELETE" ? (204, Data()) : (200, data)
        }
        defer { NativeStub.handler = nil }
        await client.end(UUID())
        _ = try await client.create(requestID: UUID())
        #expect(requests.values.map(\.httpMethod) == ["DELETE", "DELETE", "POST"])
    }

    @Test func quotaAndDisabledResponsesAreNotRetriedOrSpoken() async throws {
        let client = try broker()
        let requests = NativeRequests()
        NativeStub.handler = { request in
            _ = requests.append(request)
            return (429, Data(#"{"error":{"code":"native_usage_limit","message":"private-provider-content"}}"#.utf8))
        }
        defer { NativeStub.handler = nil }
        do {
            _ = try await client.create(requestID: UUID())
            Issue.record("Expected the reservation limit to reject this call")
        } catch let error as LunaNativeError {
            #expect(error.errorDescription?.contains("usage limit") == true)
            #expect(error.errorDescription?.contains("private-provider-content") == false)
        }
        #expect(requests.values.count == 1)
    }
}
