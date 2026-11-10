import Foundation
import HermesLensCore
import Testing
import UIKit
@testable import HermesLens

@Test @MainActor func freshInstallHasNoServerAndNoDemoMode() {
    let suite = UserDefaults(suiteName: "HermesLensTests.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: suite)
    #expect(!settings.usesMockHermes)
    #expect(!settings.usesMockGlasses)
    #expect(settings.bridgeURL.isEmpty)
}

@Test @MainActor func serverConfigurationNeedsAddressAndToken() {
    let suite = UserDefaults(suiteName: "HermesLensTests.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: suite)
    settings.bridgeURL = "https://hermes.example.com"
    settings.accessToken = ""
    #expect(!settings.hasServerConfiguration)
    settings.accessToken = "token"
    #expect(settings.hasServerConfiguration)
    settings.bridgeURL = "  "
    #expect(!settings.hasServerConfiguration)
}

@Test @MainActor func demoCallDrivesStatesCaptionsToolsAndApprovals() async throws {
    let call = LunaDemoCall()
    await call.start()
    #expect(call.state.phase == .listening)
    call.ask("Look at this")
    #expect(call.state.heard == "Look at this")
    try await Task.sleep(for: .milliseconds(200))
    #expect(call.tools.first?.name == "look")
    #expect(call.tools.first?.label == "Looking through your glasses")
    try await Task.sleep(for: .seconds(1.4))
    #expect(call.tools.isEmpty)
    #expect(call.state.transcript.contains("desk"))
    call.ask("Send a message to Sam")
    try await Task.sleep(for: .seconds(1.5))
    #expect(call.approval != nil && call.approvalShownAt != nil)
    call.decideApproval(false)
    #expect(call.approval == nil)
    #expect(call.state.transcript.contains("cancelled"))
}

@Test @MainActor func callControllerKeepsOneCallAndRetriesOneDrop() async throws {
    let controller = LunaCallController()
    var made = 0
    let make: () -> any LunaCall = { made += 1; return LunaDemoCall() }
    controller.start(make)
    try await Task.sleep(for: .milliseconds(800))
    #expect(controller.isActive && made == 1)
    controller.start(make) // a second Talk reuses the running call
    #expect(made == 1)
    controller.callPhaseChanged(.failed)
    #expect(made == 2) // one automatic retry
    controller.callPhaseChanged(.failed)
    #expect(made == 2) // and only one
    controller.end()
    #expect(!controller.isActive)
}

@Test @MainActor func unavailableCallFailsWithItsReasonInsteadOfFallingBack() async {
    let call = LunaUnavailableCall(reason: "Luna's live voice is turned off on the server right now.")
    await call.start()
    #expect(call.state.phase == .failed)
    #expect(call.errorMessage?.contains("turned off") == true)
}

@Test @MainActor func lunaMoodFollowsTheCallNotDecoration() async {
    #expect(LunaMood(call: nil, isReconnecting: false, isOffline: false) == .ready)
    #expect(LunaMood(call: nil, isReconnecting: false, isOffline: true) == .offline)
    let call = LunaDemoCall()
    await call.start()
    #expect(LunaMood(call: call, isReconnecting: false, isOffline: false) == .listening)
    #expect(LunaMood(call: call, isReconnecting: true, isOffline: false) == .connecting)
    call.end()
    let failed = LunaUnavailableCall(reason: "off")
    await failed.start()
    #expect(LunaMood(call: failed, isReconnecting: false, isOffline: false) == .didntWork)
    #expect(LunaToolActivity(id: "1", name: "ask_luna", request: "Quarterly sales").label == "Checking: Quarterly sales")
    #expect(LunaToolActivity(id: "2", name: "unknown_tool", request: nil).label == "Checking with your workspace")
}

@Test func persistenceEnforcesRetentionExportAndDeletion() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("HermesLensRetentionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let reference = Date(timeIntervalSince1970: 2_000_000)
    let policy = DataRetentionPolicy(
        captureLifetime: 100,
        memoryLifetime: 100,
        completedReminderLifetime: 100
    )
    let store = PersistenceStore(
        rootURL: root,
        policy: policy,
        now: { reference }
    )
    let oldDate = reference.addingTimeInterval(-101)
    let currentDate = reference.addingTimeInterval(-10)
    let oldCaptureID = UUID()
    let currentCaptureID = UUID()
    let oldFilename = try await store.storeCapture(
        Data("old".utf8),
        kind: .photo,
        id: oldCaptureID
    )
    let currentFilename = try await store.storeCapture(
        Data("current".utf8),
        kind: .photo,
        id: currentCaptureID
    )
    let oldMemory = MemoryRecord(capturedAt: oldDate, note: "old", summary: "old")
    let currentMemory = MemoryRecord(
        capturedAt: currentDate,
        note: "current",
        summary: "current"
    )
    let oldReminder = ReminderRecord(
        title: "old",
        dueAt: oldDate,
        isCompleted: true
    )
    let currentReminder = ReminderRecord(title: "current", dueAt: currentDate)
    let recentlyCompletedReminder = ReminderRecord(
        title: "recently completed",
        dueAt: oldDate,
        isCompleted: true,
        completedAt: currentDate
    )
    let artifacts = [
        CaptureArtifact(
            id: oldCaptureID,
            capturedAt: oldDate,
            kind: .photo,
            localFilename: oldFilename,
            request: "old"
        ),
        CaptureArtifact(
            id: currentCaptureID,
            capturedAt: currentDate,
            kind: .photo,
            localFilename: currentFilename,
            request: "current"
        )
    ]
    try await store.save(
        memories: [oldMemory, currentMemory],
        reminders: [oldReminder, currentReminder, recentlyCompletedReminder],
        artifacts: artifacts
    )

    let loaded = await store.load()
    #expect(loaded.memories.map(\.id) == [currentMemory.id])
    #expect(Set(loaded.reminders.map(\.id)) == Set([currentReminder.id, recentlyCompletedReminder.id]))
    #expect(loaded.artifacts.map(\.id) == [currentCaptureID])
    #expect(await store.captureData(filename: oldFilename) == nil)
    #expect(await store.captureData(filename: currentFilename) == Data("current".utf8))

    let exportURL = try await store.exportBundle(
        memories: loaded.memories,
        reminders: loaded.reminders,
        artifacts: loaded.artifacts
    )
    #expect(fileManager.fileExists(atPath: exportURL.appendingPathComponent("HermesLensData.json").path))
    #expect(
        fileManager.fileExists(
            atPath: exportURL.appendingPathComponent("Captures/\(currentFilename)").path
        )
    )

    try await store.deleteAllPersonalData()
    let deleted = await store.load()
    #expect(deleted.memories.isEmpty)
    #expect(deleted.reminders.isEmpty)
    #expect(deleted.artifacts.isEmpty)
    #expect(await store.captureData(filename: currentFilename) == nil)
}

@Test func callRecordsAreKeptThirtyDaysNewestFirst() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("calls-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let store = CallRecordStore(rootURL: root, now: { now })
    func record(daysAgo: Double) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return CallRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(60),
                          turns: [.init(speaker: .you, text: "Day \(daysAgo)"), .init(speaker: .luna, text: "Answer")],
                          actions: [], captureIDs: [])
    }
    try await store.save([record(daysAgo: 31), record(daysAgo: 2), record(daysAgo: 1)])
    let loaded = await store.load()
    #expect(loaded.map(\.title) == ["Day 1.0", "Day 2.0"]) // 31-day-old call dropped; newest first
    #expect(loaded.first?.summary == "Answer")
    try await store.deleteAll()
    #expect(await store.load().isEmpty)
}

@Test func turnRecorderNeverRecordsATurnTwice() {
    var turns: [LunaCallTurn] = []
    turns.record(heard: "How did the launch go?", said: "")
    turns.record(heard: "How did the launch go?", said: "Sales were up.")
    turns.record(heard: "How did the launch go?", said: "Sales were up.")
    #expect(turns == [.init(speaker: .you, text: "How did the launch go?"), .init(speaker: .luna, text: "Sales were up.")])
}

@Test @MainActor func endingADemoCallHandsOverItsTurnsAndActions() async throws {
    let controller = LunaCallController()
    var finished: (turns: [LunaCallTurn], actions: [LunaCallAction])?
    controller.onFinished = { _, _, turns, actions in finished = (turns, actions) }
    let call = LunaDemoCall()
    controller.start({ call })
    try await Task.sleep(for: .milliseconds(800))
    call.ask("Send a message to Sam")
    try await Task.sleep(for: .seconds(1.5))
    call.decideApproval(true)
    controller.end()
    #expect(finished?.turns.first == .init(speaker: .you, text: "Send a message to Sam"))
    #expect(finished?.actions == [LunaCallAction(summary: "Send a message for you (demo)", approved: true)])
}

@Test @MainActor func privacyAndSetupSettingsDefaultSafelyAndPersist() {
    let suiteName = "HermesLensTests.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: suite)
    #expect(settings.allowsCameraInCalls)
    #expect(!settings.keepsCameraReadyInCalls)
    #expect(!settings.showsDeveloperSettings)
    #expect(!settings.hasCompletedOnboarding)
    settings.allowsCameraInCalls = false
    settings.keepsCameraReadyInCalls = true
    settings.showsDeveloperSettings = true
    settings.hasCompletedOnboarding = true
    let restored = AppSettings(defaults: suite)
    #expect(!restored.allowsCameraInCalls && restored.keepsCameraReadyInCalls)
    #expect(restored.showsDeveloperSettings && restored.hasCompletedOnboarding)
    suite.removePersistentDomain(forName: suiteName)
}

@Test @MainActor func lunaSeesGlassesImagesAtFullSizeAndLargerImagesAt1440() throws {
    func jpeg(_ width: Int, _ height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .jpegData(withCompressionQuality: 0.9) { context in
                UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }
    let frame = jpeg(720, 1280)
    #expect(LunaNativeSession.forModel(frame) == frame)
    let still = jpeg(1080, 1440)
    #expect(LunaNativeSession.forModel(still) == still)
    let large = try #require(UIImage(data: LunaNativeSession.forModel(jpeg(2000, 3000))))
    #expect(large.size.width * large.scale == 960)
    #expect(large.size.height * large.scale == 1440)
}

@Test func glassesCameraIsBlockedOnlyByWhatTheGlassesActuallyReport() {
    var info = GlassesDeviceInfo(name: "Glasses", model: "Ray-Ban Meta", battery: 80, isCharging: false,
                                 isWorn: nil, isFolded: nil, heat: .normal)
    #expect(info.cameraBlocker == nil) // unknown never blocks
    info.isWorn = true
    #expect(info.cameraBlocker == nil)
    info.heat = .warm
    #expect(info.cameraBlocker == nil)
    info.heat = .hot
    #expect(info.cameraBlocker == "glasses_too_hot")
    info.isWorn = false
    #expect(info.cameraBlocker == "glasses_not_worn")
    info.isFolded = true
    #expect(info.cameraBlocker == "glasses_folded")
    #expect(!info.trace.contains("Glasses"))
    #expect(info.trace.contains("battery=80"))
}

@Test @MainActor func glassesGesturesDefaultOnAndPersist() {
    let suiteName = "HermesLensTests.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: suite)
    #expect(settings.usesGlassesGestures)
    #expect(!settings.usesCompressedGlassesStream)
    settings.usesGlassesGestures = false
    #expect(!AppSettings(defaults: suite).usesGlassesGestures)
    suite.removePersistentDomain(forName: suiteName)
}
