import Foundation
import HermesLensCore

/// Which glasses Luna uses. Ray-Ban Meta is the default and works exactly as before; HeyCyan
/// camera glasses are a beta (connect, battery, a small photo over Bluetooth for a call's look,
/// and a full-size photo over the glasses' Wi-Fi).
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
    /// Whether a photo reaches this iPhone. HeyCyan photos come over Bluetooth (a call's look,
    /// a small photo) or the glasses' own Wi-Fi (full size), both beta, so a HeyCyan photo may
    /// still stay on the glasses when that fails.
    var photosReachPhone: Bool
}

/// What happened to a HeyCyan photo request.
enum HeyCyanPhotoOutcome: Equatable {
    /// Taken and brought to this iPhone over the glasses' Wi-Fi, named `network`.
    case fetched(jpeg: Data, photosOnGlasses: Int, network: String)
    /// Taken and confirmed by the photo count; it is stored on the glasses. `reason` says why it
    /// could not be brought over (nil when that was not asked for).
    case keptOnGlasses(photosOnGlasses: Int, reason: String?)
    /// The command went out but the photo count did not go up.
    case unconfirmed
    case notConnected
    /// Another photo is still being taken or brought over.
    case busy
    case failed(String)

    /// For the capture screen and the test button.
    var message: String {
        switch self {
        case .fetched: "Photo taken and brought to this iPhone."
        case .keptOnGlasses(let count, nil): "Photo taken and saved on your glasses (\(count) there now)."
        case .keptOnGlasses(_, let reason?): "I took the photo, but couldn't bring it to your phone: \(reason)"
        case .unconfirmed: "The glasses didn't confirm a new photo. Check them and try again."
        case .notConnected: "Your HeyCyan glasses aren't connected. Connect them in You › Glasses."
        case .busy: "I'm still bringing the last photo over from your glasses. Try again in a moment."
        case .failed(let reason): reason
        }
    }
}
