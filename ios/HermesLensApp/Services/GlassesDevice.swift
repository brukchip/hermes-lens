import Foundation

/// Which glasses Luna uses. Ray-Ban Meta is the default and works exactly as before; HeyCyan
/// camera glasses are a beta (connect, battery, take a photo that stays on the glasses).
enum GlassesBrand: String, CaseIterable, Identifiable, Sendable {
    case rayBanMeta
    case heyCyan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rayBanMeta: "Ray-Ban Meta"
        case .heyCyan: "HeyCyan (beta)"
        }
    }
}

/// The brand-neutral answer to "which glasses, connected, battery". `AppModel.glassesStatus`
/// builds it from whichever glasses are chosen; taking a photo goes through the existing
/// `AppModel.captureArtifact` and `captureCallFrame`, which pick the brand's path.
struct GlassesStatus: Equatable {
    var brand: GlassesBrand
    /// The model or advertised name, for display only (never logged).
    var name: String
    var isConnected: Bool
    /// 0–100 when the glasses have reported it.
    var battery: Int?
    /// Whether a photo reaches this iPhone. HeyCyan photos stay on the glasses in this version.
    var photosReachPhone: Bool
}

/// What happened to a HeyCyan photo request.
enum HeyCyanPhotoOutcome: Equatable {
    /// Taken and confirmed by the photo count; it is stored on the glasses.
    case keptOnGlasses(photosOnGlasses: Int)
    /// The command went out but the photo count did not go up.
    case unconfirmed
    case notConnected
    case failed(String)

    /// For the capture screen and the test button.
    var message: String {
        switch self {
        case .keptOnGlasses(let count):
            "Photo taken and saved on your glasses (\(count) there now). Bringing photos to this iPhone comes in a later version."
        case .unconfirmed: "The glasses didn't confirm a new photo. Check them and try again."
        case .notConnected: "Your HeyCyan glasses aren't connected. Connect them in You › Glasses."
        case .failed(let reason): reason
        }
    }

    /// The fixed code a call's `look` reports (`LunaCameraError`), never content.
    var lookCode: String {
        switch self {
        case .keptOnGlasses: "heycyan_photo_on_glasses"
        case .unconfirmed, .failed: "heycyan_photo_unconfirmed"
        case .notConnected: "heycyan_not_connected"
        }
    }
}
