import Foundation

// The HeyCyan "AI photo" over Bluetooth, no Wi-Fi (confirmed on an L802, firmware
// AM01L2_2.20.03, 2026-11-16): `HeyCyanCommand.takeAIPhoto` fires the shutter and the glasses
// keep a small JPEG copy; about 2 s later event 0x73 type 0x02 says how many chunks it has.
// The phone then pulls chunk 0, 1, … with `HeyCyanCommand.requestAIPhotoChunk`. Each reply is
// a 0xFD frame, longer than one notification, so it arrives through `HeyCyanFrameParser`.
// Measured, trigger to last byte: size 2 gave a 384 × 288 JPEG of 12.8 KB in 13 chunks in
// 3.7 s; size 6 a 1088 × 816 JPEG of 62.5 KB in 62 chunks in 11.6 s (the shot event came
// 2.6 s after the trigger). Other frames (a battery event) can arrive between chunks.

public enum HeyCyanAIPhoto {
    /// The photo size the glasses are asked for (0…6 allowed). Change it here only.
    public static let size: UInt8 = 4

    /// The trigger's payload for a size (`HeyCyanCommand.takeAIPhoto` uses `size`).
    static func triggerPayload(size: UInt8) -> [UInt8] {
        [0x02, 0x01, 0x06, size, size, 0x02]
    }

    /// The most a whole AI photo may take, from the trigger.
    public static let maximumSeconds: Double = 20

    /// How long the pull may take once the chunk count is known, counted from that moment:
    /// 3 s plus 0.25 s per chunk, at most `maximumSeconds`. 13 chunks: 6.25 s; 62 chunks:
    /// 18.5 s. The shot event's count is one byte, so the 16-bit total of the chunk replies
    /// replaces it as soon as the first chunk is in.
    public static func pullSeconds(chunkCount: Int) -> Double {
        min(maximumSeconds, 3 + 0.25 * Double(max(0, chunkCount)))
    }
}

/// One 0xFD reply: `01 <total UInt16 LE> <index UInt16 LE> <JPEG bytes>`. The first byte is
/// `01` in every reply seen; it is not checked.
public struct HeyCyanAIPhotoChunk: Equatable, Sendable {
    public static let headerLength = 5

    public let total: Int
    public let index: Int
    public let bytes: [UInt8]

    public init(total: Int, index: Int, bytes: [UInt8]) {
        self.total = total
        self.index = index
        self.bytes = bytes
    }

    /// The chunk in a 0xFD frame's payload, or nil when it is too short or its numbers are
    /// impossible (no chunks, or an index past the total).
    public init?(payload p: [UInt8]) {
        guard p.count >= Self.headerLength else { return nil }
        let total = Int(p[1]) | Int(p[2]) << 8
        let index = Int(p[3]) | Int(p[4]) << 8
        guard total > 0, index < total else { return nil }
        self.init(total: total, index: index, bytes: Array(p[Self.headerLength...]))
    }

    public init?(_ frame: HeyCyanFrame) {
        guard frame.command == HeyCyanCommand.aiPhotoChunk else { return nil }
        self.init(payload: frame.payload)
    }
}

/// Puts the AI photo together: chunks are accepted in order only (a repeat, a skipped index or
/// a different total is ignored), the next index to request follows, and the JPEG is cut out
/// once the last chunk is in. Completion follows the chunk replies' 16-bit total, never the
/// shot event's one-byte count. A photo whose last chunk brings no JPEG end (`FF D9`) is not
/// a photo.
public struct HeyCyanAIPhotoAssembler: Equatable, Sendable {
    public enum Acceptance: Equatable, Sendable {
        case accepted
        /// Already received (an answer to a repeated request).
        case duplicate
        /// Not the next index, or a total that does not match the first chunk's.
        case unexpected
    }

    /// The JPEG is never larger than this (a size 6 photo stays far below it).
    public static let maximumBytes = 2_000_000

    /// The number of chunks, from the first chunk.
    public private(set) var total: Int?
    /// Chunks accepted so far; also the next index to request.
    public private(set) var received = 0
    private var bytes: [UInt8] = []

    public init() {}

    public var byteCount: Int { bytes.count }

    /// Every chunk is in: the last one accepted had index + 1 == total.
    public var isComplete: Bool { total.map { received >= $0 } ?? false }

    /// The index to request next, or nil once complete.
    public var nextIndex: Int? { isComplete ? nil : received }

    public mutating func accept(_ chunk: HeyCyanAIPhotoChunk) -> Acceptance {
        if let total, chunk.total != total { return .unexpected }
        if chunk.index < received { return .duplicate }
        guard chunk.index == received, bytes.count + chunk.bytes.count <= Self.maximumBytes else { return .unexpected }
        total = chunk.total
        bytes.append(contentsOf: chunk.bytes)
        received += 1
        return .accepted
    }

    /// The photo: from the first `FF D8 FF` to the last `FF D9` after it (the last, so an
    /// embedded thumbnail's end marker cannot cut it short; padding after it is dropped).
    /// Nil until complete, or when the bytes are not a JPEG.
    public var jpeg: Data? {
        guard isComplete, let range = Self.jpegRange(in: bytes) else { return nil }
        return Data(bytes[range])
    }

    static func jpegRange(in bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= 5 else { return nil }
        var start: Int?
        for i in 0...(bytes.count - 3) where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
            start = i
            break
        }
        guard let start else { return nil }
        var i = bytes.count - 2
        while i >= start + 3 {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD9 { return start..<(i + 2) }
            i -= 1
        }
        return nil
    }
}
