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

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func photosAreStagedThenReferencedByIDOnTheToolCall() async throws {
        let client = try broker()
        let requests = NativeRequests()
        let photoID = String(repeating: "ab", count: 16)
        NativeStub.handler = { request in
            _ = requests.append(request)
            if request.url?.path == "/v1/lens/native/photos" {
                return (200, Data(#"{"photoID":"\#(photoID)"}"#.utf8))
            }
            return (200, Data(#"{"response":{"result":"ok"}}"#.utf8))
        }
        defer { NativeStub.handler = nil }
        let callID = UUID()
        let id = try await client.uploadPhoto(callID: callID, jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(id == photoID)
        let upload = try #require(requests.values.first)
        #expect(upload.httpMethod == "POST")
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(upload.value(forHTTPHeaderField: "X-Call-ID") == callID.uuidString.lowercased())
        #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-device-token")
        let call = LunaNativeToolCall(id: "fc-9", name: "ask_luna", request: "Keep these", arguments: ["attach_photos": "true"])
        _ = try await client.runTool(callID: callID, call: call, photoIDs: [id])
        _ = try await client.runTool(callID: callID, call: call)
        let withPhotos = Self.body(requests.values[1])["args"] as? [String: Any]
        let without = Self.body(requests.values[2])["args"] as? [String: Any]
        #expect(withPhotos?["photoIDs"] as? [String] == [id] && withPhotos?["request"] as? String == "Keep these")
        #expect(without?.keys.sorted() == ["request"])
    }

    @Test func aRefusedPhotoUploadThrowsInsteadOfSilentlyDroppingIt() async throws {
        let client = try broker()
        NativeStub.handler = { _ in (415, Data()) }
        defer { NativeStub.handler = nil }
        await #expect(throws: (any Error).self) {
            _ = try await client.uploadPhoto(callID: UUID(), jpeg: Data([1, 2, 3]))
        }
    }
}
