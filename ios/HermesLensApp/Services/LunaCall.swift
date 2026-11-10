import Foundation
import HermesLensCore
import Observation
import SwiftUI

/// One tool Luna is running during a call, shown as a chip on Home.
struct LunaToolActivity: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The request Luna passed to her back office (the user's own words, display only).
    let request: String?
    var startedAt: Date = .now

    /// Plain words for the chip: never tool or model names.
    var label: String {
        switch name {
        case "look": "Looking through your glasses"
        case "record_video": "Recording a short video"
        default:
            if let request, !request.isEmpty { "Checking: \(request)" } else { "Checking with your workspace" }
        }
    }

    var systemImage: String {
        switch name {
        case "look": "eye"
        case "record_video": "record.circle"
        default: "sparkle.magnifyingglass"
        }
    }
}

/// One spoken turn of a call, kept for the call record (local only).
struct LunaCallTurn: Codable, Hashable, Sendable {
    enum Speaker: String, Codable, Sendable { case you, luna }
    let speaker: Speaker
    let text: String
}

/// An action Luna asked to take and what the user chose.
struct LunaCallAction: Codable, Hashable, Sendable {
    let summary: String
    let approved: Bool
}

extension Array where Element == LunaCallTurn {
    /// Appends what was heard and said in a finished (or interrupted) turn,
    /// skipping repeats so a turn is never recorded twice.
    mutating func record(heard: String, said: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty, !contains(where: { $0.speaker == .you && $0.text == heard }) {
            append(LunaCallTurn(speaker: .you, text: heard))
        }
        if !said.isEmpty, last != LunaCallTurn(speaker: .luna, text: said) {
            append(LunaCallTurn(speaker: .luna, text: said))
        }
    }
}

/// What Home needs from a live call. The real Gemini session and the demo
/// engine both provide it, so Home, demo mode and UI tests share one surface.
@MainActor
protocol LunaCall: AnyObject {
    var state: LunaNativeCallState { get }
    var errorMessage: String? { get }
    var routeTitle: String { get }
    var inputLevel: Double { get }
    var tools: [LunaToolActivity] { get }
    var toolsAvailable: Bool { get }
    var approval: LunaNativeToolResult.Approval? { get }
    var approvalBusy: Bool { get }
    var approvalShownAt: Date? { get }
    /// A contact Luna read from a card, waiting for the user to check and save.
    var contactDraft: LunaContactDraft? { get }
    /// False when the call failed for a reason an immediate retry cannot fix.
    var retryable: Bool { get }
    var turns: [LunaCallTurn] { get }
    var actions: [LunaCallAction] { get }
    func start() async
    func end()
    func toggleMute()
    func decideApproval(_ approve: Bool)
    /// The user saved the contact in Apple's sheet, or closed the card without saving.
    func finishContact(saved: Bool)
    func ask(_ text: String)
}

extension LunaNativeSession: LunaCall {}

/// Owns the one live call for the whole app. It lives in the app shell, so
/// switching tabs, opening a notification or running a shortcut never ends a
/// call; only End does. A call that drops on its own is retried once.
@MainActor
@Observable
final class LunaCallController {
    private(set) var call: (any LunaCall)?
    /// Set while the controller is replacing a dropped call.
    private(set) var isReconnecting = false
    @ObservationIgnored private var makeCall: (() -> any LunaCall)?
    @ObservationIgnored private var retriesLeft = 0
    @ObservationIgnored private var startedAt: Date?
    /// Turns and actions from a dropped call that was retried, so the record keeps them.
    @ObservationIgnored private var carriedTurns: [LunaCallTurn] = []
    @ObservationIgnored private var carriedActions: [LunaCallAction] = []
    /// Receives the finished call (start, end, turns, actions) to save as a record.
    @ObservationIgnored var onFinished: ((Date, Date, [LunaCallTurn], [LunaCallAction]) -> Void)?

    var isActive: Bool { call != nil }

    /// Starts a call, or reuses the running one. `ask` is sent once it connects.
    func start(_ make: @escaping () -> any LunaCall, ask text: String? = nil) {
        if let call, ![.failed, .ended].contains(call.state.phase) {
            if let text { call.ask(text) }
            return
        }
        makeCall = make
        retriesLeft = 1
        startedAt = .now
        carriedTurns = []; carriedActions = []
        launch(ask: text)
    }

    func end() {
        if let call {
            let turns = carriedTurns + call.turns
            let actions = carriedActions + call.actions
            call.end()
            if let startedAt { onFinished?(startedAt, .now, turns, actions) }
        }
        call = nil
        makeCall = nil
        startedAt = nil
        carriedTurns = []; carriedActions = []
        isReconnecting = false
    }

    /// Called by Home when the call's phase changes. Retries one unexpected drop, but not
    /// one a retry cannot fix, and not from the background, where iOS refuses the microphone.
    func callPhaseChanged(_ phase: LunaNativeCallState.Phase) {
        guard phase == .failed, retriesLeft > 0, makeCall != nil, call?.retryable != false,
              UIApplication.shared.applicationState == .active else { return }
        retriesLeft -= 1
        isReconnecting = true
        if let call { carriedTurns += call.turns; carriedActions += call.actions }
        launch(ask: nil)
    }

    private func launch(ask text: String?) {
        guard let makeCall else { return }
        let next = makeCall()
        call = next
        if let text { next.ask(text) }
        Task { [weak self] in
            await next.start()
            self?.isReconnecting = false
        }
    }
}

/// A scripted call for demo mode and UI tests: real state transitions, captions,
/// tool chips and an approval card, with no network, microphone or camera.
@MainActor
@Observable
final class LunaDemoCall: LunaCall {
    private(set) var state = LunaNativeCallState()
    private(set) var errorMessage: String?
    let routeTitle = "Demo"
    private(set) var inputLevel = 0.0
    private(set) var tools: [LunaToolActivity] = []
    let toolsAvailable = true
    private(set) var approval: LunaNativeToolResult.Approval?
    private(set) var approvalBusy = false
    private(set) var approvalShownAt: Date?
    let contactDraft: LunaContactDraft? = nil
    let retryable = true
    private(set) var turns: [LunaCallTurn] = []
    private(set) var actions: [LunaCallAction] = []
    @ObservationIgnored private var pendingAsk: String?

    func start() async {
        state.begin()
        try? await Task.sleep(for: .milliseconds(600))
        guard state.phase == .connecting else { return }
        state.connected()
        if let pendingAsk { self.pendingAsk = nil; ask(pendingAsk) }
        #if DEBUG
        // UI tests: `-LunaDemoScript approval` makes the demo ask for something that needs an OK.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-LunaDemoScript"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           ProcessInfo.processInfo.arguments[index + 1] == "approval" {
            ask("Send a message to Sam")
        }
        #endif
    }

    func end() { state.end(); tools = []; approval = nil }

    func toggleMute() { state.mute(!state.isMuted) }

    func ask(_ text: String) {
        guard [.listening, .responding, .speaking].contains(state.phase) else { pendingAsk = text; return }
        let id = state.generation
        state.receive(.inputTranscript(text), generation: id)
        let lower = text.lowercased()
        let tool: LunaToolActivity? = lower.contains("look")
            ? LunaToolActivity(id: UUID().uuidString, name: "look", request: nil)
            : lower.contains("record") ? LunaToolActivity(id: UUID().uuidString, name: "record_video", request: nil)
            : lower.contains("send") || lower.contains("message")
                ? LunaToolActivity(id: UUID().uuidString, name: "ask_luna", request: text) : nil
        Task { [weak self] in
            guard let self else { return }
            if let tool {
                self.tools.append(tool)
                try? await Task.sleep(for: .seconds(1.2))
                self.tools.removeAll { $0.id == tool.id }
            }
            guard id == self.state.generation else { return }
            if tool?.name == "ask_luna" {
                self.approval = .init(id: UUID(), summary: "Send a message for you (demo)")
                self.approvalShownAt = .now
                self.speak("That needs your OK. The buttons are on your phone.", generation: id)
            } else {
                self.speak(Self.reply(to: tool?.name), generation: id)
            }
        }
    }

    func decideApproval(_ approve: Bool) {
        guard let approval else { return }
        actions.append(LunaCallAction(summary: approval.summary, approved: approve))
        self.approval = nil; approvalShownAt = nil
        speak(approve ? "Done. I sent it." : "Okay, I cancelled it.", generation: state.generation)
    }

    func finishContact(saved: Bool) {}

    private func speak(_ text: String, generation: UUID) {
        guard generation == state.generation else { return }
        state.receive(.outputTranscript(text), generation: generation)
        turns.record(heard: state.heard, said: state.transcript)
        state.receive(.turnComplete, generation: generation)
    }

    private static func reply(to tool: String?) -> String {
        switch tool {
        case "look": "I can see a desk with a laptop and a cup of coffee."
        case "record_video": "Recorded six seconds and saved it to your Library."
        default: "This is demo Luna. Connect to Luna's server to talk for real."
        }
    }
}

/// Shown when live voice cannot start (server switch off, missing address or
/// token): the call fails at once with the reason and the fix, instead of
/// silently falling back to another voice engine.
@MainActor
@Observable
final class LunaUnavailableCall: LunaCall {
    private(set) var state = LunaNativeCallState()
    let errorMessage: String?
    let routeTitle = ""
    let inputLevel = 0.0
    let tools: [LunaToolActivity] = []
    let toolsAvailable = false
    let approval: LunaNativeToolResult.Approval? = nil
    let approvalBusy = false
    let approvalShownAt: Date? = nil
    let contactDraft: LunaContactDraft? = nil
    let retryable = false
    let turns: [LunaCallTurn] = []
    let actions: [LunaCallAction] = []

    init(reason: String) { errorMessage = reason }

    func start() async { state.begin(); state.fail() }
    func end() { state.end() }
    func toggleMute() {}
    func decideApproval(_ approve: Bool) {}
    func finishContact(saved: Bool) {}
    func ask(_ text: String) {}
}

extension EnvironmentValues {
    /// Ask Luna something from anywhere in the app: starts (or joins) the call on
    /// Home and puts the request into the conversation.
    @Entry var askLuna: (String) -> Void = { _ in }
}

#if DEBUG
/// Self-test launch flags (`-LunaInjectPCM`, `-LunaBuiltInMic`, `-LunaCaptureMic`,
/// `-LunaAutoDecline`) apply only during the `-LunaAutoTalk` call. The app keeps
/// running after the test, and the next real tap must use the real mic: a lingering
/// `-LunaInjectPCM` would feed the test recording instead.
@MainActor enum LunaSelfTest {
    static var isRunning = false

    static func flag(_ name: String) -> Bool {
        isRunning && ProcessInfo.processInfo.arguments.contains(name)
    }
}
#endif
