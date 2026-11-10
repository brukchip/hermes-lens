import AppIntents
import Foundation
import Observation

enum IntentDestination: Equatable {
    case talk
    case look
    case remember(prefill: String)
    case endCall
}

@MainActor
@Observable
final class AppIntentRouter {
    struct HandledIntent: Identifiable, Equatable {
        let id = UUID()
        let destination: IntentDestination
    }

    static let shared = AppIntentRouter()
    var handledIntent: HandledIntent?

    private init() {}
}

struct TalkToLunaIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Luna"
    static let description = IntentDescription("Open Luna and start a live conversation through your glasses.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppIntentRouter.shared.handledIntent = .init(destination: .talk) }
        return .result()
    }
}

struct LookWithLunaIntent: AppIntent {
    static let title: LocalizedStringResource = "Look with Luna"
    static let description = IntentDescription("Open Luna and ask her to look through your glasses.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppIntentRouter.shared.handledIntent = .init(destination: .look) }
        return .result()
    }
}

struct RememberThisIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember This"
    static let description = IntentDescription("Open Luna to save a note with optional dictated context.")
    static let openAppWhenRun = true

    @Parameter(
        title: "What should I remember?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var note: String?

    func perform() async throws -> some IntentResult {
        let prefill = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await MainActor.run {
            AppIntentRouter.shared.handledIntent = .init(destination: .remember(prefill: prefill))
        }
        return .result()
    }
}

/// Hangs up Luna's call from Siri or the Action Button.
struct EndLunaCallIntent: AppIntent {
    static let title: LocalizedStringResource = "End Luna Call"
    static let description = IntentDescription("Hang up your call with Luna.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppIntentRouter.shared.handledIntent = .init(destination: .endCall) }
        return .result()
    }
}

struct HermesLensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToLunaIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start a call with \(.applicationName)",
            ],
            shortTitle: "Talk to Luna",
            systemImageName: "waveform.and.mic"
        )

        AppShortcut(
            intent: LookWithLunaIntent(),
            phrases: [
                "Look with \(.applicationName)",
                "What am I looking at, \(.applicationName)",
            ],
            shortTitle: "Look with Luna",
            systemImageName: "eye"
        )

        AppShortcut(
            intent: EndLunaCallIntent(),
            phrases: [
                "End my \(.applicationName) call",
                "Hang up \(.applicationName)",
            ],
            shortTitle: "End Luna Call",
            systemImageName: "phone.down"
        )

        AppShortcut(
            intent: RememberThisIntent(),
            phrases: [
                "Remember this with \(.applicationName)",
                "Save a note in \(.applicationName)",
            ],
            shortTitle: "Remember This",
            systemImageName: "brain.head.profile"
        )
    }
}

