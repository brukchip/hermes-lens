import Foundation
import Testing
@testable import HermesLensCore

@Suite(.serialized)
struct HermesClientTests {
    @Test func configurationWithoutVoiceKeepsLiveVoiceOff() throws {
        let result = try JSONDecoder.hermes.decode(HermesLensConfiguration.self, from: Data(#"{"build": 1}"#.utf8))
        #expect(result.build == 1)
        #expect(result.voice.nativeAudioEnabled == false)
        #expect(result.supportsNativeVoice == false)
    }

    @Test func configurationIgnoresUnknownFieldsAndReadsNativeVoice() throws {
        let json = """
        {
          "build": 3,
          "assistantIdentity": {"assistantName": "Luna"},
          "voice": {"nativeAudioEnabled": true, "nativeAudioProtocol": "luna.native.v2", "other": 1},
          "extra": [1, 2, 3]
        }
        """
        let result = try JSONDecoder.hermes.decode(HermesLensConfiguration.self, from: Data(json.utf8))
        #expect(result.supportsNativeVoice)
    }

    @Test func configurationWithAnotherProtocolIsNotUsed() throws {
        let json = #"{"voice": {"nativeAudioEnabled": true, "nativeAudioProtocol": "something.else"}}"#
        let result = try JSONDecoder.hermes.decode(HermesLensConfiguration.self, from: Data(json.utf8))
        #expect(result.supportsNativeVoice == false)
    }

    @Test func lensConfigurationUsesAuthenticatedRoute() async throws {
        let recorder = LockedRequestRecorder()
        let configuration = HermesLensConfiguration(
            build: 18,
            voice: .init(nativeAudioEnabled: true, nativeAudioProtocol: LunaNativeVoice.protocolName)
        )
        StubURLProtocol.handler = { request in
            recorder.record(request)
            return (try ok(request), try JSONEncoder.hermes.encode(configuration))
        }
        defer { StubURLProtocol.handler = nil }

        let result = try await makeClient().lensConfiguration()
        let request = try #require(recorder.request)

        #expect(result == configuration)
        #expect(request.url?.path == "/v1/lens/config")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mobile-token")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Device-Id") == testDeviceID.uuidString)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") != nil)
    }

    @Test func healthUsesAuthenticatedRoute() async throws {
        let recorder = LockedRequestRecorder()
        StubURLProtocol.handler = { request in
            recorder.record(request)
            return (try ok(request), Data(#"{"status":"ok"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let health = try await makeClient().health()
        #expect(health.isHealthy)
        #expect(recorder.request?.url?.path == "/health")
        #expect(recorder.request?.value(forHTTPHeaderField: "Authorization") == "Bearer mobile-token")
    }

    @Test func bridgeErrorStatusesRemainVisibleToTheClient() async throws {
        for errorStatus in [400, 401, 403, 409, 413, 429, 502, 503] {
            StubURLProtocol.handler = { request in
                let url = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: errorStatus, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])
                )
                return (response, Data("{\"detail\":\"rejected\"}".utf8))
            }

            do {
                _ = try await makeClient().lensConfiguration()
                Issue.record("Expected HTTP \(errorStatus) to fail")
            } catch let error as HermesClientError {
                #expect(error == .httpStatus(errorStatus))
            } catch {
                Issue.record("Unexpected error for HTTP \(errorStatus): \(error)")
            }
        }
        StubURLProtocol.handler = nil
    }

    @Test func endpointRejectsCleartextRemoteHosts() {
        let url = URL(string: "http://example.com")!
        #expect(throws: HermesClientError.insecureEndpoint) {
            try HermesEndpointConfiguration(baseURL: url, token: "a-token", deviceID: UUID())
        }
    }

    @Test func endpointRequiresAToken() {
        #expect(throws: HermesClientError.missingToken) {
            try HermesEndpointConfiguration(baseURL: URL(string: "https://example.com")!, token: "  ", deviceID: UUID())
        }
    }

    @Test func endpointAllowsLocalDevelopmentHTTP() throws {
        let config = try HermesEndpointConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8642")!,
            token: "development-token",
            deviceID: UUID()
        )
        #expect(config.url(path: "/health").absoluteString == "http://127.0.0.1:8642/health")
    }

    @Test func reminderGetsStableNotificationIdentifier() {
        let id = UUID()
        let reminder = ReminderRecord(id: id, title: "Review notes", dueAt: .now)
        #expect(reminder.notificationIdentifier.contains(id.uuidString))
    }

    @Test func memoryRoundTrips() throws {
        let memory = MemoryRecord(note: "Follow up on the wearable idea.", summary: "Follow up on the wearable idea.")
        let decoded = try JSONDecoder.hermes.decode(MemoryRecord.self, from: JSONEncoder.hermes.encode(memory))
        #expect(decoded.id == memory.id)
        #expect(decoded.note == memory.note)
        #expect(abs(decoded.capturedAt.timeIntervalSince(memory.capturedAt)) < 1)
    }

    private var testDeviceID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    }

    private func makeClient() throws -> LiveHermesClient {
        let configuration = try HermesEndpointConfiguration(
            baseURL: URL(string: "https://hermes.example.test")!,
            token: "mobile-token",
            deviceID: testDeviceID
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return LiveHermesClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
    }
}

private func ok(_ request: URLRequest) throws -> HTTPURLResponse {
    let url = try #require(request.url)
    return try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])
    )
}

private final class LockedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func record(_ request: URLRequest) {
        lock.withLock { storedRequest = request }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
