import Foundation
import HermesLensCore
import Network
import NetworkExtension
import Observation
import UIKit

/// Takes a photo on HeyCyan glasses and brings it to this iPhone, beta.
///
/// The documented flow (community notes; each stage is traced as `heycyan.transfer stage=…`):
/// 1. Bluetooth: hotspot transfer mode (`0x41 02 01 04 02`, as the official iPhone app sends
///    it). The reply holds the glasses' own Wi-Fi name and password; about 8 s later the
///    glasses report their address (event 0x73/08, 192.168.31.1 on the L802).
/// 2. (No step: `0x45` is the AI voice heartbeat, not a "proceed".)
/// 3. The iPhone joins that hidden WPA2 network, with the reported password and then the
///    fixed `123456789` (community notes: the firmware may report a wrong one). With the
///    Hotspot Configuration entitlement (build flag `HERMES_HOTSPOT_JOIN`, paid developer
///    teams) the app joins it itself: one system prompt per password, join once, hidden.
///    Without it the app shows a card with the network's name and password, the user joins it
///    in Settings › Wi-Fi › Other…, and the app polls until the glasses answer (3 minutes).
///    A look in a call has no time for that: without the entitlement it brings the photo over
///    only when this iPhone joined the glasses' network before (iOS then joins it by itself
///    when the phone is not on another Wi-Fi), and otherwise keeps it on the glasses
///    (`HeyCyanFetchPlan`, `HeyCyanCallLookFallback`).
/// 4. Plain HTTP: `http://<glasses>/files/media.config` lists the files; the newest JPEG is
///    downloaded from `/files/<name>` (at most 15 MB).
/// 5. Always, success or failure: leave transfer mode (`0x41 02 01 09`) and remove the Wi-Fi
///    configuration, so the phone returns to its usual network.
///
/// One photo at a time: a second request while one runs is refused (`busy`).
/// Privacy: traces carry stage names, durations, the glasses' private IP and counts. Never the
/// Wi-Fi name or password, file names, file contents or photo bytes. The manual card shows the
/// name and password on screen: it is the glasses' own temporary network.
@MainActor
@Observable
final class HeyCyanPhotoTransfer {
    enum Stage: Equatable {
        case takingPhoto
        case openingGlassesWiFi
        case joiningWiFi
        case waitingForManualJoin
        case waitingForKnownNetwork
        case findingGlasses
        case downloading
        /// A call's look: the small AI photo over Bluetooth.
        case bringingAIPhoto

        /// For the Photo screen and Settings while it runs.
        var displayText: String {
            switch self {
            case .takingPhoto: "Taking the photo on your glasses"
            case .openingGlassesWiFi: "Asking the glasses for the photo"
            case .joiningWiFi: "Joining your glasses' Wi-Fi. Tap Join if the iPhone asks."
            case .waitingForManualJoin: "Waiting for you to join the glasses' Wi-Fi"
            case .waitingForKnownNetwork: "Waiting for the iPhone to join the glasses' Wi-Fi"
            case .findingGlasses: "Finding the glasses on their Wi-Fi"
            case .downloading: "Bringing the photo to this iPhone"
            case .bringingAIPhoto: "Bringing a small photo over Bluetooth"
            }
        }
    }

    /// The manual join card: the glasses' network, its password while the user needs it, and
    /// the card's state. It stays after the transfer ("you can go back to your normal Wi-Fi")
    /// until dismissed or the next photo.
    struct ManualJoinCard: Equatable {
        var ssid: String
        /// Shown on screen while waiting for the join; cleared once the glasses answer.
        var password: String?
        var state: HeyCyanManualJoin
    }

    /// What is happening now; nil when idle.
    private(set) var stage: Stage?
    var isBusy: Bool { stage != nil }
    private(set) var manualJoin: ManualJoinCard?

    /// Whether this build may join the glasses' Wi-Fi itself (the Hotspot Configuration
    /// entitlement, opt-in with `HERMES_HOTSPOT_JOIN = YES`; see README).
    static var automaticJoinAvailable: Bool {
        #if HERMES_HOTSPOT_JOIN
        true
        #else
        false
        #endif
    }

    private let glasses: HeyCyanGlassesService
    private let clock = ContinuousClock()
    private let clockOrigin = ContinuousClock.now
    @ObservationIgnored private var stopRequested = false
    /// When the credentials arrived, and whether the glasses' IP event was traced since.
    @ObservationIgnored private var credentialsAt: ContinuousClock.Instant?
    @ObservationIgnored private var wifiIPTraced = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(glasses: HeyCyanGlassesService) {
        self.glasses = glasses
    }

    /// Sent to Luna in a call once the photo is taken and is coming over a known network.
    static let comingOverNote = "The photo was taken on the user's HeyCyan glasses and is coming over to the phone now; that takes about 20 seconds. Tell the user so in one short sentence (for example: got the photo, bringing it over from your glasses, about 20 seconds), then wait: the look result follows by itself. Do not call look again."

    /// Takes one photo on the glasses and, when `fetch` is true, brings it to this iPhone as
    /// `HeyCyanFetchPlan` allows for `context`, within the plan's budget counted from
    /// `startedAt` (a reconnect before it included). `knownNetwork`: the paired glasses'
    /// network this iPhone joined before. `onComingOver` runs once the photo is taken and a
    /// call's transfer over a known network starts.
    func takePhoto(fetch: Bool, context: HeyCyanFetchPlan.Context,
                   startedAt: ContinuousClock.Instant = .now, knownNetwork: String? = nil,
                   onComingOver: (@MainActor () -> Void)? = nil) async -> HeyCyanPhotoOutcome {
        guard stage == nil else {
            trace("stage=start ms=0 result=busy")
            return .busy
        }
        let plan = HeyCyanFetchPlan.plan(for: context, automaticJoinAvailable: Self.automaticJoinAvailable,
                                         networkKnown: knownNetwork != nil)
        if fetch { trace("stage=plan ms=0 result=\(plan.traceLabel) budget_s=\(plan.budgetSeconds)") }
        let deadline = startedAt + .seconds(plan.budgetSeconds)
        stage = .takingPhoto
        manualJoin = nil
        stopRequested = false
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
        let mode: JoinMode
        switch plan {
        case .keepOnGlasses:
            // A call cannot wait for the user to join a Wi-Fi network in Settings.
            trace("stage=fallback ms=0 result=\(HeyCyanCallLookFallback.setupNeeded.traceLabel)")
            return .callFallback(.setupNeeded, photosOnGlasses: count)
        case .automaticJoin: mode = .automatic
        case .manualJoin: mode = .manual
        case .knownNetwork:
            mode = .known(knownNetwork ?? "")
            onComingOver?()
        }
        do {
            let (jpeg, network) = try await fetchNewestPhoto(deadline: deadline, mode: mode)
            return .fetched(jpeg: jpeg, photosOnGlasses: count, network: network)
        } catch {
            guard case .known = mode else { return .keptOnGlasses(photosOnGlasses: count, reason: error.reason) }
            let fallback = HeyCyanCallLookFallback.choose(
                networkKnown: true, cause: error.callLookCause,
                onWiFi: lastFailureWiFi?.onWiFi ?? false, onGlassesWiFi: lastFailureWiFi?.onGlassesWiFi ?? false)
            trace("stage=fallback ms=0 result=\(fallback.traceLabel) cause=\(error.traceLabel) "
                + "on_wifi=\(lastFailureWiFi?.onWiFi ?? false) on_glasses_wifi=\(lastFailureWiFi?.onGlassesWiFi ?? false)")
            return .callFallback(fallback, photosOnGlasses: count)
        }
    }

    /// A call's look: the small AI photo over Bluetooth (`HeyCyanGlassesService.captureAIPhoto`),
    /// about 4 s, no Wi-Fi. One photo at a time, with the Wi-Fi transfer too.
    func takeAIPhoto() async throws(HeyCyanAIPhotoFailure) -> Data {
        guard stage == nil else {
            VoiceDiagnosticLog.record("heycyan.aiphoto", "stage=fail result=busy chunks=0/? bytes=0 ms=0")
            throw .busy
        }
        stage = .bringingAIPhoto
        defer { stage = nil }
        return try await glasses.captureAIPhoto()
    }

    /// How the phone gets onto the glasses' network.
    private enum JoinMode: Equatable {
        /// The app joins it (Hotspot Configuration entitlement).
        case automatic
        /// The user joins it in Settings while the card shows.
        case manual
        /// iOS joins it by itself: this iPhone joined the network with this name before.
        case known(String)
    }

    /// The phone's Wi-Fi when a known-network transfer failed, measured before transfer mode
    /// is left (the glasses' network goes away then).
    @ObservationIgnored private var lastFailureWiFi: (onWiFi: Bool, onGlassesWiFi: Bool)?

    // MARK: The transfer

    /// Stops waiting for a manual join (the card's Stop button).
    func stopManualJoin() {
        guard manualJoin?.state.phase == .waitingForJoin else { return }
        stopRequested = true
    }

    /// Hides a finished card.
    func dismissManualJoin() {
        guard let phase = manualJoin?.state.phase, phase == .finished || phase == .gaveUp else { return }
        manualJoin = nil
    }

    /// The photo and the name of the network it came over.
    private func fetchNewestPhoto(deadline: ContinuousClock.Instant, mode: JoinMode) async throws(HeyCyanTransferFailure) -> (Data, String) {
        let started = clock.now
        var joinedSSID: String?
        var enteredTransferMode = false
        credentialsAt = nil
        wifiIPTraced = false
        lastFailureWiFi = nil
        do {
            let fetched = try await transfer(deadline: deadline, mode: mode, enteredTransferMode: &enteredTransferMode,
                                             joinedSSID: &joinedSSID)
            traceWiFiIP(final: true)
            cleanUp(enteredTransferMode: enteredTransferMode, joinedSSID: joinedSSID)
            trace("stage=total ms=\(ms(since: started)) result=ok")
            return fetched
        } catch {
            traceWiFiIP(final: true)
            if case .known = mode, error != .cancelled {
                let onWiFi = await HeyCyanLocalNetwork.isOnWiFi()
                let address = HeyCyanLocalNetwork.wifiAddress()
                lastFailureWiFi = (onWiFi, HeyCyanGlassesAddress.isOnGlassesNetwork(
                    address: address?.address, netmask: address?.netmask, glassesAddress: glasses.reportedWiFiAddress))
            }
            cleanUp(enteredTransferMode: enteredTransferMode, joinedSSID: joinedSSID)
            trace("stage=total ms=\(ms(since: started)) result=\(error.traceLabel)")
            throw error
        }
    }

    private func transfer(deadline: ContinuousClock.Instant, mode: JoinMode, enteredTransferMode: inout Bool,
                          joinedSSID: inout String?) async throws(HeyCyanTransferFailure) -> (Data, String) {
        // 1. Transfer mode: the glasses' Wi-Fi name and password over Bluetooth.
        stage = .openingGlassesWiFi
        let stageStart = clock.now
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
        trace("stage=credentials ms=\(ms(since: stageStart)) result=ok has_password=\(!credentials.password.isEmpty) "
            + "password_is_fixed=\(credentials.password == HeyCyanWiFiCredentials.fallbackPassword)")
        credentialsAt = clock.now

        try checkTime(deadline, need: .seconds(6))

        let found: Found
        switch mode {
        case .manual:
            // 3–4. The user joins in Settings › Wi-Fi; the app polls until the glasses answer.
            found = try await waitForManualJoin(credentials, deadline: deadline)
        case .automatic:
            found = try await joinAndFind(credentials, deadline: deadline, joinedSSID: &joinedSSID)
        case .known(let ssid):
            // 3–4. iOS joins the remembered network by itself (not while the phone is on another
            // Wi-Fi); the app only polls until the glasses answer.
            guard credentials.ssid == ssid else {
                trace("stage=known_network ms=0 result=ssid_changed")
                throw .networkChanged
            }
            stage = .waitingForKnownNetwork
            let stageStart = clock.now
            do {
                found = try await findGlasses(deadline: deadline)
            } catch {
                trace("stage=known_network ms=\(ms(since: stageStart)) result=\(error.traceLabel)")
                throw error
            }
            trace("stage=known_network ms=\(ms(since: stageStart)) result=ok ip=\(found.host) source=\(found.source) "
                + "rounds=\(found.rounds) file_count=\(found.fileCount)")
        }

        // 5. Download the newest photo.
        stage = .downloading
        let downloadStart = clock.now
        guard let url = HeyCyanGlassesAddress.fileURL(host: found.host, name: found.photo) else {
            trace("stage=download ms=0 result=bad_name")
            throw .noPhotoListed
        }
        let downloadSeconds = max(1, remaining(deadline).seconds)
        do {
            let jpeg = try await HeyCyanHTTP.get(url, timeout: downloadSeconds, maxBytes: HeyCyanMediaList.maximumPhotoBytes)
            guard HeyCyanMediaList.looksLikeJPEG(jpeg) else {
                trace("stage=download ms=\(ms(since: downloadStart)) result=not_jpeg bytes=\(jpeg.count)")
                throw HeyCyanTransferFailure.notAPhoto
            }
            trace("stage=download ms=\(ms(since: downloadStart)) result=ok bytes=\(jpeg.count)")
            return (jpeg, credentials.ssid)
        } catch let failure as HeyCyanTransferFailure {
            throw failure
        } catch {
            let failure: HeyCyanTransferFailure = switch error as? HeyCyanHTTPError {
            case .tooLarge: .tooLarge
            default: Task.isCancelled ? .cancelled : .downloadFailed
            }
            trace("stage=download ms=\(ms(since: downloadStart)) result=\(failure.traceLabel) "
                + "error=\(HeyCyanHTTP.label(error))")
            throw failure
        }
    }

    /// Steps 3–4 with the entitlement: join the hidden network with `NEHotspotConfiguration`,
    /// then find the glasses; with the reported password first, then the fixed one, splitting
    /// the time left between the attempts.
    private func joinAndFind(_ credentials: HeyCyanWiFiCredentials, deadline: ContinuousClock.Instant,
                             joinedSSID: inout String?) async throws(HeyCyanTransferFailure) -> Found {
        let passwords = credentials.passwordsToTry
        var lastFailure = HeyCyanTransferFailure.glassesNotFound
        for (index, password) in passwords.enumerated() {
            if Task.isCancelled { throw .cancelled }
            let which = password == credentials.password ? "reported" : "fixed"
            let attemptDeadline = clock.now + remaining(deadline) / (passwords.count - index)
            guard remaining(attemptDeadline) > .seconds(4) else { break }

            // 3. Join the glasses' hidden Wi-Fi (one system prompt).
            stage = .joiningWiFi
            var stageStart = clock.now
            if let previous = joinedSSID {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: previous)
            }
            joinedSSID = credentials.ssid
            let joinTimeout = max(.seconds(3), remaining(attemptDeadline) - .seconds(3))
            switch await join(ssid: credentials.ssid, password: password, timeout: joinTimeout) {
            case .joined(let already):
                trace("stage=join ms=\(ms(since: stageStart)) result=ok already=\(already) password=\(which) attempt=\(index + 1)")
            case .failed(let failure, let code):
                trace("stage=join ms=\(ms(since: stageStart)) result=\(failure.traceLabel) code=\(code) "
                    + "password=\(which) attempt=\(index + 1)")
                // The user said no, or Luna is in the background: another password won't help.
                if failure == .joinDenied || failure == .notInForeground { throw failure }
                lastFailure = failure
                continue
            }

            // 4. Find the glasses' HTTP server and read the file list.
            stage = .findingGlasses
            stageStart = clock.now
            if glasses.reportedWiFiAddress == nil {
                let wait = min(.seconds(3), remaining(attemptDeadline) - .seconds(3))
                if wait > .zero { _ = await glasses.waitForWiFiAddress(timeout: wait) }
            }
            do {
                let found = try await findGlasses(deadline: attemptDeadline)
                trace("stage=find ms=\(ms(since: stageStart)) result=ok ip=\(found.host) source=\(found.source) "
                    + "rounds=\(found.rounds) file_count=\(found.fileCount) password=\(which)")
                return found
            } catch .glassesNotFound {
                lastFailure = .glassesNotFound  // perhaps the wrong password: try the next one
            }
        }
        throw lastFailure
    }

    // MARK: The manual join card

    /// Steps 3–4 without the entitlement: shows the card and asks every candidate address for
    /// `media.config` every 1.5 s for up to 3 minutes (`HeyCyanManualJoin`). Background time is
    /// requested so polling can go on for a while when the user switches to Settings.
    private func waitForManualJoin(_ credentials: HeyCyanWiFiCredentials,
                                   deadline: ContinuousClock.Instant) async throws(HeyCyanTransferFailure) -> Found {
        stage = .waitingForManualJoin
        let stageStart = clock.now
        var state = HeyCyanManualJoin(startedAt: seconds(clock.now))
        manualJoin = ManualJoinCard(ssid: credentials.ssid, password: credentials.password, state: state)
        beginBackgroundTime()
        trace("stage=manual_join ms=0 result=card_shown has_password=\(!credentials.password.isEmpty)")
        var answeredWithoutPhoto: (host: String, fileCount: Int)?
        while state.shouldPoll(at: seconds(clock.now)), remaining(deadline) > .seconds(5), !stopRequested {
            if Task.isCancelled { break }
            let pollStart = seconds(clock.now)
            traceWiFiIP(final: false)
            let reported = glasses.reportedWiFiAddress
            let gateway = HeyCyanLocalNetwork.wifiGateway()
            let hosts = HeyCyanGlassesAddress.candidates(reported: reported, gateway: gateway)
            let result = await Self.probe(hosts, timeout: HeyCyanManualJoin.probeTimeout)
            switch result {
            case .photo(let host, let name, let fileCount):
                state.recordPoll(answered: true, at: seconds(clock.now))
                manualJoin?.state = state
                manualJoin?.password = nil
                let source = host == reported ? "reported" : host == gateway ? "gateway" : "common"
                trace("stage=manual_join ms=\(ms(since: stageStart)) result=ok ip=\(host) source=\(source) "
                    + "polls=\(state.polls) file_count=\(fileCount)")
                return Found(host: host, source: source, rounds: state.polls, fileCount: fileCount, photo: name)
            case .noPhoto(let host, let fileCount):
                state.recordPoll(answered: true, at: seconds(clock.now))
                answeredWithoutPhoto = (host, fileCount)
            case .unreachable:
                state.recordPoll(answered: false, at: seconds(clock.now))
            }
            manualJoin?.state = state
            if answeredWithoutPhoto != nil { break }
            let now = seconds(clock.now)
            try? await Task.sleep(for: .seconds(state.delayBeforeNextPoll(pollStartedAt: pollStart, now: now)))
        }
        if let answeredWithoutPhoto {
            trace("stage=manual_join ms=\(ms(since: stageStart)) result=no_photo_listed ip=\(answeredWithoutPhoto.host) "
                + "polls=\(state.polls) file_count=\(answeredWithoutPhoto.fileCount)")
            throw .noPhotoListed
        }
        let failure: HeyCyanTransferFailure = stopRequested ? .stopped
            : Task.isCancelled ? .cancelled
            : state.shouldPoll(at: seconds(clock.now)) ? .outOfTime : .manualJoinTimedOut
        trace("stage=manual_join ms=\(ms(since: stageStart)) result=\(failure.traceLabel) polls=\(state.polls)")
        throw failure
    }

    /// `stage=wifi_ip`: the glasses' IP event and how long after the credentials it came, once
    /// per transfer; with `final`, `result=none` when it never came.
    private func traceWiFiIP(final: Bool) {
        guard !wifiIPTraced, let credentialsAt else { return }
        if let address = glasses.reportedWiFiAddress {
            let at = glasses.reportedWiFiAddressAt ?? clock.now
            wifiIPTraced = true
            trace("stage=wifi_ip ms=\(max(0, ms(since: credentialsAt) - ms(since: at))) result=ok ip=\(address)")
        } else if final {
            wifiIPTraced = true
            trace("stage=wifi_ip ms=\(ms(since: credentialsAt)) result=none")
        }
    }

    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Glasses photo") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Seconds on the transfer's monotonic clock, for `HeyCyanManualJoin`.
    private func seconds(_ instant: ContinuousClock.Instant) -> TimeInterval {
        (instant - clockOrigin).seconds
    }

    /// Leaves transfer mode and forgets the glasses' network. Runs on every path.
    private func cleanUp(enteredTransferMode: Bool, joinedSSID: String?) {
        if enteredTransferMode { glasses.exitTransferMode() }
        if manualJoin != nil {
            manualJoin?.state.end()
            manualJoin?.password = nil
        }
        endBackgroundTime()
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
    private func join(ssid: String, password: String, timeout: Duration) async -> JoinResult {
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = true
        // The glasses' hotspot does not broadcast its name.
        configuration.hidden = true
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
            traceWiFiIP(final: false)
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
    /// The manual join card waited 3 minutes and the glasses never answered.
    case manualJoinTimedOut
    /// The user tapped Stop on the manual join card.
    case stopped
    /// The glasses opened a network other than the one this iPhone knows.
    case networkChanged

    /// For `HeyCyanCallLookFallback`.
    var callLookCause: HeyCyanCallLookFallback.Cause {
        switch self {
        case .glassesNotFound, .outOfTime: .glassesNotFound
        case .networkChanged: .networkChanged
        default: .other
        }
    }

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
        case .manualJoinTimedOut: "the glasses didn't answer on their Wi-Fi within 3 minutes."
        case .stopped: "you stopped it."
        case .networkChanged: "the glasses opened a different Wi-Fi than the one this iPhone knows."
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
        case .manualJoinTimedOut: "manual_join_timeout"
        case .stopped: "stopped"
        case .networkChanged: "network_changed"
        }
    }
}

/// True for the first caller only, from any thread.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
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
        wifiAddress().flatMap { HeyCyanGlassesAddress.firstHost(address: $0.address, netmask: $0.netmask) }
    }

    /// The phone's IPv4 address and netmask on Wi-Fi (`en0`), when it has one.
    static func wifiAddress() -> (address: String, netmask: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0",
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.ifa_netmask,
                  let addressText = ipv4(address), let netmaskText = ipv4(netmask) else { continue }
            return (addressText, netmaskText)
        }
        return nil
    }

    /// Whether the phone is on a Wi-Fi network right now: the current path has a Wi-Fi
    /// interface (`NWPathMonitor`, interface type only; the network's name would need an
    /// entitlement), or `en0` has an address. Answers within a second.
    static func isOnWiFi() async -> Bool {
        let pathHasWiFi = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            let queue = DispatchQueue(label: "heycyan.path")
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.availableInterfaces.contains { $0.type == .wifi })
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) {
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
        return pathHasWiFi || wifiAddress() != nil
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
