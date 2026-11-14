import Foundation
import HermesLensCore
import NetworkExtension
import Observation

/// Takes a photo on HeyCyan glasses and brings it to this iPhone, beta.
///
/// The documented flow (community notes; each stage is traced as `heycyan.transfer stage=…`):
/// 1. Bluetooth: transfer mode (`0x41 02 01 04`). The reply holds the glasses' own Wi-Fi name
///    and password.
/// 2. Bluetooth: "proceed" (`0x45 04 01`). Some firmware then reports its Wi-Fi address.
/// 3. The iPhone joins that network (`NEHotspotConfiguration`, one system prompt, join once).
/// 4. Plain HTTP: `http://<glasses>/files/media.config` lists the files; the newest JPEG is
///    downloaded from `/files/<name>` (at most 15 MB).
/// 5. Always, success or failure: leave transfer mode (`0x41 02 01 09`) and remove the Wi-Fi
///    configuration, so the phone returns to its usual network.
///
/// One photo at a time: a second request while one runs is refused (`busy`).
/// Privacy: traces carry stage names, durations, the glasses' private IP and counts. Never the
/// Wi-Fi name or password, file names, file contents or photo bytes.
@MainActor
@Observable
final class HeyCyanPhotoTransfer {
    enum Stage: Equatable {
        case takingPhoto
        case openingGlassesWiFi
        case joiningWiFi
        case findingGlasses
        case downloading

        /// For the Photo screen and Settings while it runs.
        var displayText: String {
            switch self {
            case .takingPhoto: "Taking the photo on your glasses"
            case .openingGlassesWiFi: "Asking the glasses for the photo"
            case .joiningWiFi: "Joining your glasses' Wi-Fi. Tap Join if the iPhone asks."
            case .findingGlasses: "Finding the glasses on their Wi-Fi"
            case .downloading: "Bringing the photo to this iPhone"
            }
        }
    }

    /// What is happening now; nil when idle.
    private(set) var stage: Stage?
    var isBusy: Bool { stage != nil }

    /// A look in a call must finish or give up within about 25 s in total.
    static let callBudget: Duration = .seconds(25)
    /// The Photo flow and the Settings test: the user is watching and may need a moment for the
    /// system's "Join network" prompt.
    static let interactiveBudget: Duration = .seconds(45)

    private let glasses: HeyCyanGlassesService
    private let clock = ContinuousClock()

    init(glasses: HeyCyanGlassesService) {
        self.glasses = glasses
    }

    /// Takes one photo on the glasses and, when `fetch` is true, brings it to this iPhone
    /// within `budget` (counted from now, the photo included).
    func takePhoto(fetch: Bool, budget: Duration) async -> HeyCyanPhotoOutcome {
        guard stage == nil else {
            trace("stage=start ms=0 result=busy")
            return .busy
        }
        let deadline = clock.now + budget
        stage = .takingPhoto
        defer { stage = nil }
        let photo: HeyCyanGlassesService.PhotoResult
        do {
            photo = try await glasses.takePhoto()
        } catch HeyCyanError.notConnected {
            return .notConnected
        } catch {
            return .failed(error.localizedDescription)
        }
        guard photo.confirmed else { return .unconfirmed }
        let count = photo.after.photos
        guard fetch else { return .keptOnGlasses(photosOnGlasses: count, reason: nil) }
        do {
            return .fetched(jpeg: try await fetchNewestPhoto(deadline: deadline), photosOnGlasses: count)
        } catch {
            return .keptOnGlasses(photosOnGlasses: count, reason: error.reason)
        }
    }

    // MARK: The transfer

    private func fetchNewestPhoto(deadline: ContinuousClock.Instant) async throws(HeyCyanTransferFailure) -> Data {
        let started = clock.now
        var joinedSSID: String?
        var enteredTransferMode = false
        do {
            let jpeg = try await transfer(deadline: deadline, enteredTransferMode: &enteredTransferMode,
                                          joinedSSID: &joinedSSID)
            cleanUp(enteredTransferMode: enteredTransferMode, joinedSSID: joinedSSID)
            trace("stage=total ms=\(ms(since: started)) result=ok")
            return jpeg
        } catch {
            cleanUp(enteredTransferMode: enteredTransferMode, joinedSSID: joinedSSID)
            trace("stage=total ms=\(ms(since: started)) result=\(error.traceLabel)")
            throw error
        }
    }

    private func transfer(deadline: ContinuousClock.Instant, enteredTransferMode: inout Bool,
                          joinedSSID: inout String?) async throws(HeyCyanTransferFailure) -> Data {
        // 1. Transfer mode: the glasses' Wi-Fi name and password over Bluetooth.
        stage = .openingGlassesWiFi
        var stageStart = clock.now
        let credentials: HeyCyanWiFiCredentials
        do {
            enteredTransferMode = true
            credentials = try await glasses.enterTransferMode(timeout: min(.seconds(6), remaining(deadline)))
        } catch {
            let failure: HeyCyanTransferFailure = switch error as? HeyCyanError {
            case .notConnected: .disconnected
            case .transferRefused: .refused
            default: Task.isCancelled ? .cancelled : .noCredentials
            }
            trace("stage=credentials ms=\(ms(since: stageStart)) result=\(failure.traceLabel)")
            throw failure
        }
        trace("stage=credentials ms=\(ms(since: stageStart)) result=ok has_password=\(!credentials.password.isEmpty)")

        // 2. Proceed: some firmware reports its Wi-Fi address only after this.
        do {
            try glasses.sendTransferProceed()
            trace("stage=proceed ms=0 result=sent")
        } catch {
            trace("stage=proceed ms=0 result=not_connected")
            throw .disconnected
        }
        try checkTime(deadline, need: .seconds(6))

        // 3. Join the glasses' Wi-Fi (one system prompt).
        stage = .joiningWiFi
        stageStart = clock.now
        joinedSSID = credentials.ssid
        let joinTimeout = max(.seconds(3), remaining(deadline) - .seconds(4))
        let joinResult = await join(credentials, timeout: joinTimeout)
        switch joinResult {
        case .joined(let already):
            trace("stage=join ms=\(ms(since: stageStart)) result=ok already=\(already)")
        case .failed(let failure, let code):
            trace("stage=join ms=\(ms(since: stageStart)) result=\(failure.traceLabel) code=\(code)")
            throw failure
        }

        // 4. Find the glasses' HTTP server and read the file list.
        stage = .findingGlasses
        stageStart = clock.now
        if glasses.reportedWiFiAddress == nil {
            let wait = min(.seconds(3), remaining(deadline) - .seconds(3))
            if wait > .zero { _ = await glasses.waitForWiFiAddress(timeout: wait) }
        }
        let found = try await findGlasses(deadline: deadline)
        trace("stage=find ms=\(ms(since: stageStart)) result=ok ip=\(found.host) source=\(found.source) "
            + "rounds=\(found.rounds) file_count=\(found.fileCount)")

        // 5. Download the newest photo.
        stage = .downloading
        stageStart = clock.now
        guard let url = HeyCyanGlassesAddress.fileURL(host: found.host, name: found.photo) else {
            trace("stage=download ms=0 result=bad_name")
            throw .noPhotoListed
        }
        let seconds = max(1, remaining(deadline).seconds)
        do {
            let jpeg = try await HeyCyanHTTP.get(url, timeout: seconds, maxBytes: HeyCyanMediaList.maximumPhotoBytes)
            guard HeyCyanMediaList.looksLikeJPEG(jpeg) else {
                trace("stage=download ms=\(ms(since: stageStart)) result=not_jpeg bytes=\(jpeg.count)")
                throw HeyCyanTransferFailure.notAPhoto
            }
            trace("stage=download ms=\(ms(since: stageStart)) result=ok bytes=\(jpeg.count)")
            return jpeg
        } catch let failure as HeyCyanTransferFailure {
            throw failure
        } catch {
            let failure: HeyCyanTransferFailure = switch error as? HeyCyanHTTPError {
            case .tooLarge: .tooLarge
            default: Task.isCancelled ? .cancelled : .downloadFailed
            }
            trace("stage=download ms=\(ms(since: stageStart)) result=\(failure.traceLabel) "
                + "error=\(HeyCyanHTTP.label(error))")
            throw failure
        }
    }

    /// Leaves transfer mode and forgets the glasses' network. Runs on every path.
    private func cleanUp(enteredTransferMode: Bool, joinedSSID: String?) {
        if enteredTransferMode { glasses.exitTransferMode() }
        if let joinedSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: joinedSSID) }
        trace("stage=cleanup ms=0 result=done exit_sent=\(enteredTransferMode) wifi_removed=\(joinedSSID != nil)")
    }

    // MARK: Joining the glasses' Wi-Fi

    private enum JoinResult: Sendable {
        case joined(alreadyAssociated: Bool)
        case failed(HeyCyanTransferFailure, code: Int)
    }

    /// Applies a join-once configuration. Waits at most `timeout` (the system prompt included);
    /// a late answer is ignored, and the configuration is removed by `cleanUp` either way.
    private func join(_ credentials: HeyCyanWiFiCredentials, timeout: Duration) async -> JoinResult {
        let configuration = credentials.password.isEmpty
            ? NEHotspotConfiguration(ssid: credentials.ssid)
            : NEHotspotConfiguration(ssid: credentials.ssid, passphrase: credentials.password, isWEP: false)
        configuration.joinOnce = true
        let gate = OnceGate<JoinResult>()
        return await withCheckedContinuation { continuation in
            gate.continuation = continuation
            Task { @MainActor in
                // The async form: no completion closure called from another queue.
                do {
                    try await NEHotspotConfigurationManager.shared.apply(configuration)
                    gate.resume(with: .joined(alreadyAssociated: false))
                } catch {
                    gate.resume(with: Self.joinResult(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume(with: .failed(.joinTimedOut, code: -1))
            }
        }
    }

    private static func joinResult(_ error: Error) -> JoinResult {
        let ns = error as NSError
        guard ns.domain == NEHotspotConfigurationErrorDomain,
              let code = NEHotspotConfigurationError(rawValue: ns.code) else {
            return .failed(.joinFailed, code: ns.code)
        }
        switch code {
        case .alreadyAssociated: return .joined(alreadyAssociated: true)
        case .userDenied: return .failed(.joinDenied, code: ns.code)
        case .applicationIsNotInForeground: return .failed(.notInForeground, code: ns.code)
        case .invalidSSID, .invalidWPAPassphrase, .invalidWEPPassphrase, .invalid, .invalidSSIDPrefix:
            return .failed(.unusableCredentials, code: ns.code)
        default: return .failed(.joinFailed, code: ns.code)
        }
    }

    // MARK: Finding the glasses

    private struct Found {
        var host: String
        var source: String
        var rounds: Int
        var fileCount: Int
        var photo: String
    }

    private enum ProbeResult: Sendable {
        case photo(host: String, name: String, fileCount: Int)
        case noPhoto(host: String, fileCount: Int)
        case unreachable
    }

    /// Asks every candidate address for `media.config` at once, round after round, until one
    /// lists a photo or time runs short. The glasses may report their address late, and the
    /// joined network may need a moment, so each round rebuilds the list.
    private func findGlasses(deadline: ContinuousClock.Instant) async throws(HeyCyanTransferFailure) -> Found {
        var rounds = 0
        var answeredWithoutPhoto: (host: String, fileCount: Int)?
        while remaining(deadline) > .milliseconds(2500) {
            if Task.isCancelled { throw .cancelled }
            rounds += 1
            let reported = glasses.reportedWiFiAddress
            let gateway = HeyCyanLocalNetwork.wifiGateway()
            let hosts = HeyCyanGlassesAddress.candidates(reported: reported, gateway: gateway)
            let probeSeconds = min(rounds == 1 ? 2.0 : 1.5, max(0.5, (remaining(deadline) - .seconds(2)).seconds))
            if rounds == 1 {
                trace("stage=find_round ms=0 round=1 hosts=\(hosts.count) reported=\(reported ?? "none") gateway=\(gateway ?? "none")")
            }
            let result = await Self.probe(hosts, timeout: probeSeconds)
            switch result {
            case .photo(let host, let name, let fileCount):
                let source = host == reported ? "reported" : host == gateway ? "gateway" : "common"
                return Found(host: host, source: source, rounds: rounds, fileCount: fileCount, photo: name)
            case .noPhoto(let host, let fileCount):
                answeredWithoutPhoto = (host, fileCount)
            case .unreachable:
                break
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        if let answeredWithoutPhoto {
            trace("stage=find ms=0 result=no_photo_listed ip=\(answeredWithoutPhoto.host) "
                + "file_count=\(answeredWithoutPhoto.fileCount) rounds=\(rounds)")
            throw .noPhotoListed
        }
        trace("stage=find ms=0 result=not_found rounds=\(rounds)")
        throw Task.isCancelled ? .cancelled : .glassesNotFound
    }

    /// The first host whose file list names a photo; otherwise one that answered without a photo.
    private nonisolated static func probe(_ hosts: [String], timeout: Double) async -> ProbeResult {
        await withTaskGroup(of: ProbeResult.self) { group in
            for host in hosts {
                group.addTask {
                    guard let url = HeyCyanGlassesAddress.mediaListURL(host: host),
                          let data = try? await HeyCyanHTTP.get(url, timeout: timeout, maxBytes: HeyCyanMediaList.maximumListBytes)
                    else { return .unreachable }
                    let text = String(decoding: data, as: UTF8.self)
                    let names = HeyCyanMediaList.fileNames(in: text)
                    guard let photo = HeyCyanMediaList.newestPhoto(in: names) else {
                        return .noPhoto(host: host, fileCount: names.count)
                    }
                    return .photo(host: host, name: photo, fileCount: names.count)
                }
            }
            var fallback = ProbeResult.unreachable
            for await result in group {
                switch result {
                case .photo:
                    group.cancelAll()
                    return result
                case .noPhoto:
                    fallback = result
                case .unreachable:
                    break
                }
            }
            return fallback
        }
    }

    // MARK: Time

    private func remaining(_ deadline: ContinuousClock.Instant) -> Duration {
        max(.zero, deadline - clock.now)
    }

    private func checkTime(_ deadline: ContinuousClock.Instant, need: Duration) throws(HeyCyanTransferFailure) {
        if Task.isCancelled { throw .cancelled }
        guard remaining(deadline) >= need else {
            trace("stage=budget ms=0 result=out_of_time")
            throw .outOfTime
        }
    }

    private func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = clock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func trace(_ detail: String) {
        VoiceDiagnosticLog.record("heycyan.transfer", detail)
    }
}

/// Why a photo stayed on the glasses. `reason` finishes the sentence "I took the photo, but
/// couldn't bring it to your phone: …".
enum HeyCyanTransferFailure: Error, Equatable {
    case disconnected
    case noCredentials
    case refused
    case joinDenied
    case joinTimedOut
    case joinFailed
    case notInForeground
    case unusableCredentials
    case glassesNotFound
    case noPhotoListed
    case tooLarge
    case notAPhoto
    case downloadFailed
    case outOfTime
    case cancelled

    var reason: String {
        switch self {
        case .disconnected: "the glasses disconnected."
        case .noCredentials: "the glasses didn't open their Wi-Fi."
        case .refused: "the glasses said no to opening their Wi-Fi."
        case .joinDenied: "joining the glasses' Wi-Fi was declined."
        case .joinTimedOut: "joining the glasses' Wi-Fi wasn't confirmed in time."
        case .joinFailed: "this iPhone couldn't join the glasses' Wi-Fi."
        case .notInForeground: "Luna has to be open on screen to join the glasses' Wi-Fi."
        case .unusableCredentials: "the glasses sent a Wi-Fi password this iPhone can't use."
        case .glassesNotFound: "the glasses didn't answer on their Wi-Fi."
        case .noPhotoListed: "the glasses didn't list a photo."
        case .tooLarge: "the photo is larger than 15 MB."
        case .notAPhoto: "the glasses sent something that isn't a photo."
        case .downloadFailed: "the download didn't finish."
        case .outOfTime: "it took too long."
        case .cancelled: "it was stopped."
        }
    }

    var traceLabel: String {
        switch self {
        case .disconnected: "disconnected"
        case .noCredentials: "no_credentials"
        case .refused: "refused"
        case .joinDenied: "join_denied"
        case .joinTimedOut: "join_timeout"
        case .joinFailed: "join_failed"
        case .notInForeground: "not_in_foreground"
        case .unusableCredentials: "unusable_credentials"
        case .glassesNotFound: "not_found"
        case .noPhotoListed: "no_photo_listed"
        case .tooLarge: "too_large"
        case .notAPhoto: "not_jpeg"
        case .downloadFailed: "download_failed"
        case .outOfTime: "out_of_time"
        case .cancelled: "cancelled"
        }
    }
}

/// Resumes a continuation once: the first of several racing answers wins.
@MainActor
private final class OnceGate<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Never>?

    func resume(with value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The address of the Wi-Fi network the phone is on (interface `en0`), without the
/// "Access Wi-Fi Information" entitlement: the subnet's first host, the usual gateway.
enum HeyCyanLocalNetwork {
    static func wifiGateway() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0",
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.ifa_netmask,
                  let addressText = ipv4(address), let netmaskText = ipv4(netmask) else { continue }
            return HeyCyanGlassesAddress.firstHost(address: addressText, netmask: netmaskText)
        }
        return nil
    }

    private static func ipv4(_ socketAddress: UnsafeMutablePointer<sockaddr>) -> String? {
        socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var address = pointer.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }
}

enum HeyCyanHTTPError: Error {
    case badStatus(Int)
    case tooLarge
}

/// A plain-HTTP GET on the glasses' network with a time limit and a size cap. Wi-Fi only (no
/// cellular), no cache, no cookies. Cancelling the calling task cancels the request.
enum HeyCyanHTTP {
    static func get(_ url: URL, timeout: Double, maxBytes: Int) async throws -> Data {
        let loader = CappedLoader(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(url, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
    }

    /// The error's kind for a trace line, never a URL.
    static func label(_ error: Error) -> String {
        switch error {
        case HeyCyanHTTPError.badStatus(let status): "http_\(status)"
        case HeyCyanHTTPError.tooLarge: "too_large"
        case let error as URLError: "url_\(error.code.rawValue)"
        case is CancellationError: "cancelled"
        default: "other"
        }
    }
}

private final class CappedLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var received = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func start(_ url: URL, timeout: Double, continuation: CheckedContinuation<Data, Error>) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                                     timeoutInterval: timeout))
        lock.lock()
        if cancelled {
            lock.unlock()
            session.invalidateAndCancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.task = task
        lock.unlock()
        task.resume()
        session.finishTasksAndInvalidate()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(.failure(HeyCyanHTTPError.badStatus(status)))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(maxBytes) else {
            finish(.failure(HeyCyanHTTPError.tooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received.append(data)
        let tooLarge = received.count > maxBytes
        if tooLarge { received = Data() }
        lock.unlock()
        if tooLarge {
            finish(.failure(HeyCyanHTTPError.tooLarge))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            lock.lock()
            let data = received
            lock.unlock()
            finish(.success(data))
        }
    }
}
