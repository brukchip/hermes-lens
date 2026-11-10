import Foundation
import HermesLensCore
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class AppModel {
    private static let lensConfigurationCacheKey = "hermes.lens.last-valid-configuration"

    enum ConnectionState: Equatable {
        case unchecked
        case checking
        case connected(String)
        case offline(String)
    }

    let settings: AppSettings
    private let persistence: PersistenceStore
    private let callStore = CallRecordStore()
    /// Finished calls, newest first. Local only; 30-day retention.
    private(set) var callRecords: [CallRecord] = []
    private let notifications: NotificationService

    var memories: [MemoryRecord] = []
    var reminders: [ReminderRecord] = []
    var artifacts: [CaptureArtifact] = []
    var connectionState: ConnectionState = .unchecked
    var glassesState: GlassesConnectionState = .disconnected
    var glassesRegistrationState: GlassesRegistrationState = .unavailable
    /// Battery, worn, folded and heat as the glasses report them (nil: no glasses known).
    var glassesInfo: GlassesDeviceInfo?
    /// Set when "Hey Meta, start Luna" arrives; the shell starts a call.
    var voiceLaunchRequest: UUID?
    var isObserverActive = false
    var isWorking = false
    var isAutoConnectingGlasses = false
    var glassesConnectionDetail = "Waiting for Ray-Ban Meta."
    var lastRefreshAt: Date?
    var errorMessage: String?
    var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    var lensConfiguration = HermesLensConfiguration.fallback
    /// False until a configuration came from the server (now or cached from an earlier run).
    /// The fallback keeps live voice off, so it must not stand once the server is reachable.
    private(set) var hasServerConfiguration = false

    private var hermesClient: any HermesClient
    /// Why the saved server address can't be used, so a placeholder client is never reported as online.
    @ObservationIgnored private var endpointProblem: String?
    private var glassesService: any GlassesService

    init(
        settings: AppSettings? = nil,
        persistence: PersistenceStore = PersistenceStore(),
        notifications: NotificationService = NotificationService()
    ) {
        self.settings = settings ?? AppSettings()
        self.persistence = persistence
        self.notifications = notifications
        hermesClient = MockHermesClient()
        glassesService = MockGlassesService()
    }

    func bootstrap() async {
        LunaStorageRoot.resetForUITestRun()
        if let cachedConfiguration = Self.cachedLensConfiguration() {
            lensConfiguration = cachedConfiguration
            hasServerConfiguration = true
        }
        let snapshot = await persistence.load()
        memories = snapshot.memories.sorted { $0.capturedAt > $1.capturedAt }
        reminders = snapshot.reminders.sorted { $0.dueAt < $1.dueAt }
        artifacts = snapshot.artifacts.sorted { $0.capturedAt > $1.capturedAt }
        callRecords = await callStore.load()
        notificationAuthorization = await notifications.authorizationStatus()
        rebuildServices()
        await refreshLensConfiguration()
        await checkConnection()
    }

    func rebuildServices() {
        endpointProblem = nil
        if settings.usesMockHermes {
            hermesClient = MockHermesClient()
        } else {
            do {
                guard let url = URL(string: settings.bridgeURL) else { throw HermesClientError.invalidBaseURL }
                let configuration = try HermesEndpointConfiguration(
                    baseURL: url,
                    token: settings.accessToken,
                    sessionKey: settings.sessionKey,
                    deviceID: settings.deviceID
                )
                hermesClient = LiveHermesClient(configuration: configuration)
            } catch {
                hermesClient = MockHermesClient()
                endpointProblem = settings.bridgeURL.isEmpty
                    ? "Add your Hermes server in Settings."
                    : error.localizedDescription
                connectionState = .offline(endpointProblem ?? "")
            }
        }

        if settings.usesMockGlasses {
            glassesService = MockGlassesService()
        } else {
            #if canImport(MWDATCore)
            glassesService = MetaWearablesGlassesService()
            #else
            glassesService = MockGlassesService()
            #endif
        }
        glassesState = glassesService.state
        glassesRegistrationState = glassesService.registrationState
    }

    func checkConnection() async {
        guard settings.usesMockHermes || settings.hasServerConfiguration else {
            connectionState = .offline("Add your Hermes server in Settings.")
            return
        }
        if !settings.usesMockHermes, let endpointProblem {
            connectionState = .offline(endpointProblem)
            return
        }
        connectionState = .checking
        do {
            let health = try await hermesClient.health()
            connectionState = health.isHealthy
                ? .connected(health.detail)
                : .offline(health.detail)
        } catch {
            connectionState = .offline(error.localizedDescription)
        }
    }

    func refreshLensConfiguration() async {
        guard !settings.usesMockHermes, settings.hasServerConfiguration, endpointProblem == nil else {
            lensConfiguration = .fallback
            return
        }
        do {
            lensConfiguration = try await hermesClient.lensConfiguration()
            hasServerConfiguration = true
            Self.cacheLensConfiguration(lensConfiguration)
        } catch {
            // Keep the last valid configuration (or the fail-safe defaults).
            // A configuration failure must never block voice communication.
        }
    }

    private static func cachedLensConfiguration() -> HermesLensConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: lensConfigurationCacheKey) else {
            return nil
        }
        return try? JSONDecoder.hermes.decode(HermesLensConfiguration.self, from: data)
    }

    private static func cacheLensConfiguration(_ configuration: HermesLensConfiguration) {
        guard let data = try? JSONEncoder.hermes.encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: lensConfigurationCacheKey)
    }

    /// A native call keeps the glasses camera streaming after its first capture so
    /// later looks skip the cold start (a cold look took 15.9 s on the glasses,
    /// 2026-10-31). Released when the call ends; never started without a capture.
    /// True while a call holds the glasses camera stream (Home shows a camera-on dot).
    private(set) var isGlassesCameraHeld = false
    @ObservationIgnored private var glassesIdleRelease: Task<Void, Never>?
    /// A call has used the glasses; its session stays open (camera may be off) until the call ends.
    @ObservationIgnored private var glassesInCall = false
    @ObservationIgnored private var lastGlassesTrace: String?
    /// Why the last capture failed, shown inline by the capture screen or spoken by
    /// Luna in a call. Never raised as a global alert.
    private(set) var lastCaptureError: String?

    func holdGlassesCameraForCall() async {
        glassesIdleRelease?.cancel()
        glassesInCall = true
        guard !isGlassesCameraHeld, glassesService.state != .observing else { return }
        do {
            try await glassesService.startObserving()
            isGlassesCameraHeld = true
        } catch {
            // The capture itself reports the failure; holding is only an optimization.
        }
        glassesState = glassesService.state
    }

    /// The view for a call's `look`. The held camera stream's newest frame (720 × 1280,
    /// video-compressed) is immediate; a still photo is sharper (1080 × 1440 on 2026-11-07)
    /// but took ~9.5 s on 2026-11-01. So a look asks for the still and waits at most
    /// `stillBudget` for it, and otherwise uses the frame. Either is saved to the Library.
    ///
    /// Only a frame from the last second counts. On 2026-11-01 the stream stalled and
    /// every `look` returned the same old frame, so Luna kept describing one picture;
    /// a stalled stream is restarted once. A cold stream can take longer than 3 s to
    /// start, so it gets up to 10 s before falling back to a full photo.
    func captureCallFrame() async throws -> Data {
        await holdGlassesCameraForCall()
        var restarted = false
        var frame = try await freshCallFrame()
        if frame == nil, glassesService.latestPreviewAt != nil {
            await glassesService.stopObserving()
            isGlassesCameraHeld = false
            await holdGlassesCameraForCall()
            restarted = true
            frame = try await freshCallFrame()
        }
        if let frame {
            let started = Date.now
            let still = await stillWithin(Self.stillBudget)
            let image = still ?? frame
            VoiceDiagnosticLog.record("glasses.call_frame",
                "fresh=true restarted=\(restarted) source=\(still == nil ? "frame" : "still") "
                + "still_ms=\(Int(Date.now.timeIntervalSince(started) * 1000)) \(Self.imageShape(image))")
            _ = try? await beginArtifact(data: image, kind: .photo, request: "Photo from a Luna call")
            if !settings.keepsCameraReadyInCalls { await releaseGlassesCameraForCall() }
            return image
        }
        VoiceDiagnosticLog.record("glasses.call_frame", "fresh=false restarted=\(restarted)")
        guard let artifact = await captureArtifact(kind: .photo, request: "Photo from a Luna call"),
              let jpeg = await captureData(for: artifact) else { throw GlassesServiceError.photoCaptureFailed }
        return jpeg
    }

    /// The longest a look waits for a still photo before using the stream frame.
    static let stillBudget: Duration = .seconds(3)

    /// A still photo from the running stream, or nil if it fails or takes longer than `budget`.
    private func stillWithin(_ budget: Duration) async -> Data? {
        let capture = Task { @MainActor in try? await self.glassesService.captureJPEG() }
        let deadline = Task { try? await Task.sleep(for: budget); capture.cancel() }
        let still = await capture.value
        deadline.cancel()
        return still
    }

    /// Pixel size and bytes of a captured image, for the diagnostics log (never its content).
    static func imageShape(_ jpeg: Data?) -> String {
        guard let jpeg, let image = UIImage(data: jpeg) else { return "size=none" }
        return "size=\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale)) bytes=\(jpeg.count)"
    }

    /// Waits for a frame under a second old: up to 10 s for a stream still starting
    /// (no frame yet), 0.5 s for one that already delivered frames (15 fps) and went quiet.
    private func freshCallFrame() async throws -> Data? {
        let cold = glassesService.latestPreviewAt == nil
        for _ in 0..<(cold ? 100 : 5) {
            if let frame = glassesService.latestPreviewJPEG, let at = glassesService.latestPreviewAt,
               Date.now.timeIntervalSince(at) < 1 {
                return frame
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func releaseGlassesCameraForCall() async {
        guard isGlassesCameraHeld else { return }
        isGlassesCameraHeld = false
        await glassesService.stopObserving()
        glassesState = glassesService.state
    }

    /// The call ended: stop the camera now and close the session once the glasses are idle.
    /// Glasses buttons control the running call (Settings may turn this off). Keeps the
    /// glasses session for the call; `finishGlassesForCall` lets it go.
    func startGlassesGestures(_ handler: @escaping @MainActor @Sendable (GlassesGesture) -> Void) async {
        guard settings.usesGlassesGestures, !settings.usesMockGlasses,
              glassesRegistrationState == .registered else { return }
        glassesIdleRelease?.cancel()
        glassesInCall = true
        do {
            try await glassesService.startGestures(handler)
        } catch {
            VoiceDiagnosticLog.record("glasses.gestures", "failed error=\(String(describing: type(of: error)))")
        }
        glassesState = glassesService.state
    }

    func finishGlassesForCall() async {
        await glassesService.stopGestures()
        glassesInCall = false
        await releaseGlassesCameraForCall()
        releaseGlassesWhenIdle()
    }

    /// Closes the glasses session once nothing has used it for 20 s, so Meta AI and other
    /// apps can use the glasses (a session held while idle left Meta AI reporting them as
    /// livestreaming, 2026-11-07). A new look, capture or observer reopens it on demand.
    func releaseGlassesWhenIdle(after delay: Duration = .seconds(20)) {
        glassesIdleRelease?.cancel()
        glassesIdleRelease = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.disconnectGlassesIfIdle()
        }
    }

    func disconnectGlassesIfIdle() async {
        guard !glassesInCall, !isGlassesCameraHeld, !isWorking, !isObserverActive else { return }
        await glassesService.disconnect()
        glassesState = glassesService.state
    }

    /// Settings: close the session and ask Meta AI to remove Luna's access to the glasses.
    func unregisterGlasses() async {
        glassesIdleRelease?.cancel()
        isGlassesCameraHeld = false
        isObserverActive = false
        glassesInCall = false
        do {
            try await glassesService.unregister()
        } catch {
            errorMessage = error.localizedDescription
        }
        glassesState = glassesService.state
        glassesRegistrationState = glassesService.registrationState
    }

    func captureData(for artifact: CaptureArtifact) async -> Data? {
        await persistence.captureData(filename: artifact.localFilename)
    }

    func captureURL(for artifact: CaptureArtifact) async -> URL? {
        await persistence.captureURL(filename: artifact.localFilename)
    }

    func saveCaptureToPhotos(_ artifact: CaptureArtifact) async -> Bool {
        guard let data = await persistence.captureData(filename: artifact.localFilename) else {
            errorMessage = PhotoLibraryExportError.missingCapture.localizedDescription
            return false
        }
        do {
            try await PhotoLibraryExportService().save(data, kind: artifact.kind)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Captures and stores the original locally without waiting for Luna analysis.
    /// The dedicated Photo/Record UI uses this split so it can show truthful
    /// capture, preview, and analysis phases instead of opening voice listening.
    func captureArtifact(
        kind: VisualCaptureKind,
        request: String
    ) async -> CaptureArtifact? {
        isWorking = true
        glassesIdleRelease?.cancel()
        defer {
            isWorking = false
            glassesState = glassesService.state
            releaseGlassesWhenIdle()
        }

        lastCaptureError = nil
        if let blocker = glassesCameraBlocker {
            lastCaptureError = switch blocker {
            case "glasses_folded": "Your glasses are folded. Open them, then try again."
            case "glasses_not_worn": "Put your glasses on, then try again."
            default: "Your glasses are too hot for the camera. Give them a few minutes."
            }
            return nil
        }
        do {
            let data: Data
            let artifactKind: CaptureArtifactKind
            switch kind {
            case .photo:
                // The deliberate Photo: the glasses' high-quality photo when it works,
                // otherwise the camera stream's still.
                let started = Date.now
                var source = "high_quality"
                var jpeg = try? await glassesService.captureHighQualityPhoto()
                if jpeg == nil {
                    source = "still"
                    jpeg = try await glassesService.captureJPEG()
                }
                guard let jpeg else { throw GlassesServiceError.photoCaptureFailed }
                VoiceDiagnosticLog.record("glasses.photo", "source=\(source) ms=\(Int(Date.now.timeIntervalSince(started) * 1000)) \(Self.imageShape(jpeg))")
                data = jpeg
                artifactKind = .photo
            case .video:
                guard let clip = try await glassesService.captureShortVideo() else {
                    throw GlassesServiceError.videoCaptureFailed
                }
                data = clip
                artifactKind = .video
            }

            let id = try await beginArtifact(
                data: data,
                kind: artifactKind,
                request: request
            )
            return artifacts.first { $0.id == id }
        } catch {
            lastCaptureError = error.localizedDescription
            return nil
        }
    }

    func deleteArtifact(_ artifact: CaptureArtifact) async {
        do {
            try await persistence.deleteCapture(filename: artifact.localFilename)
            artifacts.removeAll { $0.id == artifact.id }
            try await persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteMemory(_ memory: MemoryRecord) async {
        memories.removeAll { $0.id == memory.id }
        try? await persist()
    }

    /// Edits a note's text. The summary follows the text, as for a new note.
    func updateMemory(_ memory: MemoryRecord, note: String) async {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        memories[index].note = text
        memories[index].summary = text
        try? await persist()
    }

    func deleteReminder(_ reminder: ReminderRecord) async {
        await notifications.cancel(reminder)
        reminders.removeAll { $0.id == reminder.id }
        try? await persist()
    }

    /// Edits a reminder and re-schedules its notification for the new time.
    func updateReminder(_ reminder: ReminderRecord, title: String, note: String, dueAt: Date) async {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        await notifications.cancel(reminders[index])
        reminders[index].title = title
        reminders[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        reminders[index].dueAt = dueAt
        if !reminders[index].isCompleted, dueAt > .now,
           notificationAuthorization == .authorized || notificationAuthorization == .provisional {
            try? await notifications.schedule(reminders[index])
        }
        reminders.sort { $0.dueAt < $1.dueAt }
        try? await persist()
    }

    func exportPersonalData() async -> URL? {
        do {
            return try await persistence.exportBundle(
                memories: memories,
                reminders: reminders,
                artifacts: artifacts
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteAllPersonalData() async {
        for reminder in reminders {
            await notifications.cancel(reminder)
        }
        do {
            try await persistence.deleteAllPersonalData()
            try await callStore.deleteAll()
            callRecords = []
            memories = []
            reminders = []
            artifacts = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves a finished call. Photos and clips captured during it are linked by
    /// time and origin, so the record opens straight to them.
    func saveCall(startedAt: Date, endedAt: Date, turns: [LunaCallTurn], actions: [LunaCallAction]) async {
        guard !turns.isEmpty || !actions.isEmpty else { return }
        let captures = artifacts.filter {
            $0.capturedAt >= startedAt && $0.capturedAt <= endedAt.addingTimeInterval(15)
                && $0.request.hasSuffix("from a Luna call")
        }
        let record = CallRecord(id: UUID(), startedAt: startedAt, endedAt: endedAt, turns: turns,
                                actions: actions, captureIDs: captures.map(\.id))
        callRecords.insert(record, at: 0)
        do { try await callStore.save(callRecords) } catch { errorMessage = error.localizedDescription }
    }

    func deleteCall(_ record: CallRecord) async {
        callRecords.removeAll { $0.id == record.id }
        try? await callStore.save(callRecords)
    }

    func toggleObserver() async {
        do {
            if isObserverActive {
                await glassesService.stopObserving()
                isObserverActive = false
                releaseGlassesWhenIdle()
            } else {
                glassesIdleRelease?.cancel()
                try await glassesService.startObserving()
                isObserverActive = true
            }
            glassesState = glassesService.state
        } catch {
            errorMessage = error.localizedDescription
            glassesState = glassesService.state
        }
    }

    func registerGlasses() async {
        do {
            try await glassesService.register()
            glassesRegistrationState = glassesService.registrationState
        } catch {
            errorMessage = error.localizedDescription
            glassesRegistrationState = glassesService.registrationState
        }
    }

    func connectGlasses() async {
        guard !isAutoConnectingGlasses else { return }
        isAutoConnectingGlasses = true
        glassesConnectionDetail = "Looking for nearby Ray-Ban Meta glasses…"
        defer { isAutoConnectingGlasses = false }
        do {
            try await glassesService.connect()
            glassesState = glassesService.state
            glassesRegistrationState = glassesService.registrationState
            glassesConnectionDetail = "Ray-Ban Meta is ready."
            traceGlassesConnect(nil)
        } catch {
            traceGlassesConnect(error)
            errorMessage = error.localizedDescription
            glassesState = glassesService.state
            glassesRegistrationState = glassesService.registrationState
            glassesConnectionDetail = error.localizedDescription
        }
    }

    /// Glasses connection outcomes in the diagnostics log, only when they change (auto-connect
    /// retries every 12 s). Error case names and codes only, never device names.
    private func traceGlassesConnect(_ error: Error?) {
        let outcome: String
        if let error = error as? GlassesServiceError {
            outcome = "error=\(String(describing: error).split(separator: "(").first ?? "unknown")"
        } else if let error {
            let ns = error as NSError
            outcome = "error=\(ns.domain)#\(ns.code)"
        } else {
            outcome = "ok"
        }
        let line = "\(outcome) registration=\(glassesService.registrationState) state=\(glassesService.state)"
        guard line != lastGlassesTrace else { return }
        lastGlassesTrace = line
        VoiceDiagnosticLog.record("glasses.connect", line)
    }

    /// Refreshes inexpensive device, configuration and health state.
    func refreshAll() async {
        await refreshLensConfiguration()
        await checkConnection()
        glassesState = glassesService.state
        glassesRegistrationState = glassesService.registrationState
        lastRefreshAt = .now
    }

    func handleBecameActive() async {
        glassesState = glassesService.state
        // A first launch can run before the phone reaches the server: the one configuration
        // fetch failed and live voice stayed off until a manual refresh.
        if !hasServerConfiguration { await refreshLensConfiguration() }
    }

    func refreshReadiness() async {
        await refreshAll()
    }

    func runCameraAudioProbe() async -> Int? {
        isWorking = true
        defer {
            isWorking = false
            glassesState = glassesService.state
        }
        do {
            if [.disconnected, .ready, .failed].contains(glassesService.state) {
                try await glassesService.connect()
            }
            let jpeg = try await glassesService.captureJPEG()
            return jpeg?.count
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func monitorGlassesState() async {
        // State only. Luna opens a glasses session when a call, photo, video or
        // observer needs it, never just because the app is running. Glasses events
        // refresh it at once; the poll is a backup.
        let watcher = glassesService.watchDevices { [weak self] in self?.refreshGlassesState() }
        defer { watcher?.cancel() }
        while !Task.isCancelled {
            refreshGlassesState()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func refreshGlassesState() {
        glassesState = glassesService.state
        glassesRegistrationState = glassesService.registrationState
        if glassesRegistrationState == .registered, !settings.usesMockGlasses {
            glassesService.startVoiceLaunch { [weak self] in self?.voiceLaunchRequest = UUID() }
        }
        let info = glassesService.deviceInfo
        if info?.trace != glassesInfo?.trace { VoiceDiagnosticLog.record("glasses.state", info?.trace ?? "none") }
        glassesInfo = info
    }

    /// Why the glasses camera cannot be used right now, from what the glasses report;
    /// nil when nothing says no. Unknown states never block.
    var glassesCameraBlocker: String? { glassesInfo?.cameraBlocker }

    func openGlassesFirmwareUpdate() async {
        do { try await glassesService.openFirmwareUpdate() } catch { errorMessage = "Couldn't open Meta AI. Is it installed?" }
    }

    func openGlassesAppUpdate() async {
        do { try await glassesService.openGlassesAppUpdate() } catch { errorMessage = "Couldn't open Meta AI. Is it installed?" }
    }

    func glassesCameraPermission() async -> Bool? { await glassesService.cameraPermissionGranted() }

    func requestGlassesCameraPermission() async -> Bool {
        (try? await glassesService.requestCameraPermission()) ?? false
    }

    func handleOpenURL(_ url: URL) async {
        do {
            _ = try await glassesService.handleOpenURL(url)
            glassesRegistrationState = glassesService.registrationState
            glassesState = glassesService.state
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves a note to the local Library.
    func remember(note: String) async -> Bool {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        memories.insert(MemoryRecord(note: text, summary: text), at: 0)
        do {
            try await persist()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func requestNotificationAuthorization() async {
        do {
            _ = try await notifications.requestAuthorization()
            notificationAuthorization = await notifications.authorizationStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addReminder(
        title: String,
        note: String,
        dueAt: Date
    ) async -> Bool {
        let reminder = ReminderRecord(title: title, note: note, dueAt: dueAt)
        do {
            if notificationAuthorization == .notDetermined {
                await requestNotificationAuthorization()
            }
            if notificationAuthorization == .authorized || notificationAuthorization == .provisional {
                try await notifications.schedule(reminder)
            }
            reminders.append(reminder)
            reminders.sort { $0.dueAt < $1.dueAt }
            try await persist()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleReminder(_ reminder: ReminderRecord) async {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index].isCompleted.toggle()
        if reminders[index].isCompleted {
            reminders[index].completedAt = .now
            await notifications.cancel(reminders[index])
        } else if reminders[index].dueAt > .now {
            reminders[index].completedAt = nil
            try? await notifications.schedule(reminders[index])
        } else {
            reminders[index].completedAt = nil
        }
        try? await persist()
    }

    private func persist() async throws {
        try await persistence.save(
            memories: memories,
            reminders: reminders,
            artifacts: artifacts
        )
    }

    private func beginArtifact(
        data: Data,
        kind: CaptureArtifactKind,
        request: String
    ) async throws -> UUID {
        let id = UUID()
        let filename = try await persistence.storeCapture(data, kind: kind, id: id)
        artifacts.insert(
            CaptureArtifact(
                id: id,
                kind: kind,
                localFilename: filename,
                request: request
            ),
            at: 0
        )
        try await persist()
        return id
    }


}
