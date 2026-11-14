import Foundation

// The HeyCyan (AM01 family: L802, M01) "big-data" Bluetooth LE channel, written from the frame
// format observed on real L802 glasses (firmware AM01L2_2.20.03). Pure Swift, no CoreBluetooth:
// the app's Bluetooth service feeds notification bytes in and writes `HeyCyanCommand` frames out.
//
// Frame: 0xBC | command | payload length (UInt16 LE) | CRC-16/MODBUS of the payload (UInt16 LE,
// 0xFFFF when the payload is empty) | payload.

public enum HeyCyanUUID {
    /// The big-data service. The glasses do not advertise it; it appears once connected.
    public static let bigDataService = "DE5BF728-D711-4E47-AF26-65E3012A5DC7"
    /// Notifications from the glasses.
    public static let bigDataNotify = "DE5BF729-D711-4E47-AF26-65E3012A5DC7"
    /// Commands to the glasses.
    public static let bigDataWrite = "DE5BF72A-D711-4E47-AF26-65E3012A5DC7"
}

/// CRC-16/MODBUS: polynomial 0x8005 reflected (0xA001), initial value 0xFFFF, no final XOR.
public enum CRC16Modbus {
    public static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

/// One complete big-data frame.
public struct HeyCyanFrame: Equatable, Sendable {
    public static let magic: UInt8 = 0xBC
    public static let headerLength = 6
    /// Larger lengths are treated as garbage. Live audio frames carry 40 bytes, media counts 11.
    public static let maximumPayloadLength = 4096

    public let command: UInt8
    public let payload: [UInt8]

    /// Internal on purpose: the app can only build outgoing frames through `HeyCyanCommand`.
    init(command: UInt8, payload: [UInt8]) {
        self.command = command
        self.payload = payload
    }

    /// The checksum field for `payload`.
    static func checksum(of payload: [UInt8]) -> UInt16 {
        payload.isEmpty ? 0xFFFF : CRC16Modbus.checksum(payload)
    }

    /// The frame on the wire. Internal: see `HeyCyanCommand.bytes`.
    var encoded: [UInt8] {
        let length = UInt16(payload.count)
        let crc = Self.checksum(of: payload)
        return [Self.magic, command, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(crc & 0xFF), UInt8(crc >> 8)]
            + payload
    }
}

/// Reassembles frames from Bluetooth notifications: a frame may be split across notifications,
/// and one notification may hold several frames. Bytes before a 0xBC are dropped.
///
/// Every incoming frame's checksum is verified. All frames captured from the L802 (events,
/// replies and live audio) carried a correct CRC-16/MODBUS, so a mismatch means the bytes are
/// not a frame start (a 0xBC inside earlier garbage or a payload). Then only that one 0xBC is
/// dropped and the search resumes from the next byte, so a real frame behind it is not lost.
public struct HeyCyanFrameParser: Sendable {
    private var buffer: [UInt8] = []
    /// Bytes skipped while looking for a frame start (trace counts only).
    public private(set) var droppedBytes = 0
    /// Candidate frames rejected for a wrong checksum or impossible length.
    public private(set) var rejectedFrames = 0

    public init() {}

    /// Bytes held while waiting for the rest of a frame.
    public var pendingByteCount: Int { buffer.count }

    public mutating func push<Bytes: Sequence>(_ bytes: Bytes) -> [HeyCyanFrame] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [HeyCyanFrame] = []
        var start = 0
        while start < buffer.count {
            guard buffer[start] == HeyCyanFrame.magic else {
                start += 1
                droppedBytes += 1
                continue
            }
            let available = buffer.count - start
            guard available >= HeyCyanFrame.headerLength else { break }
            let length = Int(buffer[start + 2]) | Int(buffer[start + 3]) << 8
            guard length <= HeyCyanFrame.maximumPayloadLength else {
                rejectedFrames += 1
                droppedBytes += 1
                start += 1
                continue
            }
            guard available >= HeyCyanFrame.headerLength + length else { break }
            let crc = UInt16(buffer[start + 4]) | UInt16(buffer[start + 5]) << 8
            let payloadStart = start + HeyCyanFrame.headerLength
            let payload = Array(buffer[payloadStart..<payloadStart + length])
            guard HeyCyanFrame.checksum(of: payload) == crc else {
                rejectedFrames += 1
                droppedBytes += 1
                start += 1
                continue
            }
            frames.append(HeyCyanFrame(command: buffer[start + 1], payload: payload))
            start = payloadStart + length
        }
        buffer.removeFirst(start)
        return frames
    }

    /// Forgets a half-received frame (after a disconnect).
    public mutating func reset() {
        buffer.removeAll()
    }
}

/// The only commands the app can send. Each is read-only or takes a photo; there is no way to
/// build any other frame (factory reset `02 01 0A`, restart `02 01 0E`, OTA mode `02 01 05`,
/// Wi-Fi transfer mode, DFU and firmware opcodes are deliberately absent).
public enum HeyCyanCommand: CaseIterable, Equatable, Sendable {
    /// Glasses control: take one photo. It is stored on the glasses.
    case takePhoto
    /// Glasses control: how many photos, videos and recordings are on the glasses.
    case mediaCount

    static let glassesControl: UInt8 = 0x41

    var command: UInt8 {
        switch self {
        case .takePhoto, .mediaCount: Self.glassesControl
        }
    }

    var payload: [UInt8] {
        switch self {
        case .takePhoto: [0x02, 0x01, 0x01]
        case .mediaCount: [0x02, 0x04]
        }
    }

    /// The allowlisted command these exact bytes stand for, or nil for anything else.
    public init?(command: UInt8, payload: [UInt8]) {
        guard let match = Self.allCases.first(where: { $0.command == command && $0.payload == payload }) else {
            return nil
        }
        self = match
    }

    /// The frame to write to `HeyCyanUUID.bigDataWrite`.
    public var bytes: [UInt8] { HeyCyanFrame(command: command, payload: payload).encoded }

    /// For trace lines.
    public var label: String {
        switch self {
        case .takePhoto: "take_photo"
        case .mediaCount: "media_count"
        }
    }
}

/// What the glasses report holding.
public struct HeyCyanMediaCount: Equatable, Sendable {
    public var photos: Int
    public var videos: Int
    public var recordings: Int

    public init(photos: Int, videos: Int, recordings: Int) {
        self.photos = photos
        self.videos = videos
        self.recordings = recordings
    }
}

/// A decoded incoming frame. Audio and photo content is never kept: only sizes.
public enum HeyCyanEvent: Equatable, Sendable {
    /// Battery level in percent (event 0x73, type 0x05).
    case battery(percent: Int)
    /// The glasses' microphone started: the assistant button (event 0x73, type 0x03).
    case micStarted
    /// The microphone stopped (event 0x73, type 0x0A).
    case micStopped
    /// A volume swipe (event 0x73, type 0x12).
    case volume
    /// A device state change (event 0x73, type 0x01); the fields are not decoded yet.
    case state(sequence: Int)
    /// Another device event type.
    case otherEvent(type: UInt8)
    /// Live microphone audio (0x59); its codec is not decoded yet.
    case micAudio(byteCount: Int)
    /// Reply to `HeyCyanCommand.mediaCount`.
    case mediaCount(HeyCyanMediaCount)
    /// Reply to `HeyCyanCommand.takePhoto`: accepted. Its two status bytes are not understood
    /// and differ by model (`FF FF` and `00 02` on the L802, `FF 01` on the M01), so the app
    /// confirms a photo by the media count going up instead.
    case photoReply
    /// Another glasses control reply (0x41).
    case controlReply(byteCount: Int)
    /// A frame of a command this app does not know.
    case unknown(command: UInt8, byteCount: Int)

    public static let deviceEventCommand: UInt8 = 0x73
    public static let micAudioCommand: UInt8 = 0x59

    public init(_ frame: HeyCyanFrame) {
        let p = frame.payload
        switch frame.command {
        case Self.deviceEventCommand:
            guard let type = p.first else { self = .otherEvent(type: 0); return }
            switch type {
            case 0x05 where p.count >= 2: self = .battery(percent: min(100, Int(p[1])))
            case 0x03: self = .micStarted
            case 0x0A: self = .micStopped
            case 0x12: self = .volume
            case 0x01 where p.count >= 2: self = .state(sequence: Int(p[1]))
            default: self = .otherEvent(type: type)
            }
        case Self.micAudioCommand:
            self = .micAudio(byteCount: p.count)
        case HeyCyanCommand.glassesControl:
            if p.count >= 8, p[0] == 0x02, p[1] == 0x04 {
                func le16(_ i: Int) -> Int { Int(p[i]) | Int(p[i + 1]) << 8 }
                self = .mediaCount(HeyCyanMediaCount(photos: le16(2), videos: le16(4), recordings: le16(6)))
            } else if p.count >= 3, p[0] == 0x02, p[1] == 0x01, p[2] == 0x01 {
                self = .photoReply
            } else {
                self = .controlReply(byteCount: p.count)
            }
        default:
            self = .unknown(command: frame.command, byteCount: p.count)
        }
    }
}

/// Advertised names. The glasses do not advertise their services and names follow no fixed
/// pattern, so the app lists every named device and sorts known model names first; the user picks.
public enum HeyCyanDeviceName {
    /// Seen: `L 802_0A1B` and `M01_0C2D`.
    public static func looksLikeHeyCyan(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["M01", "L 802", "L802"].contains { upper.hasPrefix($0) }
    }
}

/// Tells a press of the assistant button apart from the glasses' own listening after a photo.
///
/// Both arrive as the same "mic started" event. The M01 starts its microphone by itself right
/// after the app's take-photo command (its own "describe the photo" listening, about 5 s of
/// audio), so a mic-started event within `photoQuietSeconds` of the app's last photo command
/// is never treated as the user pressing the button.
public struct HeyCyanAssistantButtonFilter: Sendable {
    public static let photoQuietSeconds: TimeInterval = 10

    private var lastPhotoCommandAt: Date?

    public init() {}

    /// The app just sent `HeyCyanCommand.takePhoto`.
    public mutating func photoCommandSent(at date: Date) {
        lastPhotoCommandAt = date
    }

    /// Whether a mic-started event at `date` counts as an assistant button press.
    public func isButtonPress(micStartedAt date: Date) -> Bool {
        guard let lastPhotoCommandAt else { return true }
        let elapsed = date.timeIntervalSince(lastPhotoCommandAt)
        return elapsed < 0 || elapsed >= Self.photoQuietSeconds
    }
}
