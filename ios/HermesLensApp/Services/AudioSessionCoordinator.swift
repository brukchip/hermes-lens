import AVFAudio
import Foundation
import Observation

enum HermesAudioOwner: String, Equatable, Sendable {
    case none
    case luna
    case nativeVoice
    case visualCapture
}

enum AudioSessionCoordinatorError: LocalizedError {
    case occupied(HermesAudioOwner)

    var errorDescription: String? {
        switch self {
        case .occupied(let owner):
            "Audio is currently in use by \(owner.rawValue). Finish it and try again."
        }
    }
}

@MainActor
@Observable
final class AudioSessionCoordinator {
    private(set) var owner: HermesAudioOwner = .none

    func claim(_ requestedOwner: HermesAudioOwner) throws {
        guard owner == .none || owner == requestedOwner else {
            throw AudioSessionCoordinatorError.occupied(owner)
        }
        owner = requestedOwner
    }

    func release(_ requestedOwner: HermesAudioOwner) {
        guard owner == requestedOwner else { return }
        owner = .none
    }
}
