import Foundation
import Testing
@testable import HermesLensCore

/// Frames received from real L802 glasses on 2026-11-14, in order (hex only; no audio).
private let capturedFrames = [
    "bc73080073070103000000000001",
    "bc730e003a99120100100f02000f0f0300100a03",
    "bc730e000b3c120100101002000f0f0300100a03",
    "bc730e003a99120100100f02000f0f0300100a03",
    "bc73080005c70104000000000001",
    "bc7303004931056300",
    "bc730200c0800301",
    "bc730200c6d00a01",
    "bc4105000c4c020101ffff",
    "bc73080015070105000000000001",
    "bc73080026070106000000000001",
    "bc73080036c70107000000000001",
    "bc410b003b790204070000000000010000",
    "bc730200469a0b27",
    "bc4105008c3d0201010002",
    "bc7308000b070107000100000001",
    "bc73030048a1056200",
    "bc730800f4070108000100000001",
    "bc410b006a490204080001000000010000",
    "bc730800e4c70109000100000001",
].map(hex)

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

private func parseAll(_ chunks: [[UInt8]]) -> (frames: [HeyCyanFrame], parser: HeyCyanFrameParser) {
    var parser = HeyCyanFrameParser()
    let frames = chunks.flatMap { parser.push($0) }
    return (frames, parser)
}

private func decode(_ frameHex: String) -> HeyCyanEvent? {
    var parser = HeyCyanFrameParser()
    return parser.push(hex(frameHex)).first.map(HeyCyanEvent.init)
}

/// A synthetic live-audio frame like the glasses send every 20 ms (40-byte payload).
private func audioFrame(_ seed: UInt8) -> [UInt8] {
    HeyCyanFrame(command: 0x59, payload: [0x4B, 0x41] + (0..<38).map { seed &+ UInt8($0) }).encoded
}

// MARK: CRC

@Test func crc16ModbusMatchesTheStandardCheckValue() {
    #expect(CRC16Modbus.checksum(Array("123456789".utf8)) == 0x4B37)
    #expect(CRC16Modbus.checksum([UInt8]()) == 0xFFFF)
}

@Test func everyCapturedFrameCarriesACorrectChecksum() {
    for frame in capturedFrames {
        let crc = UInt16(frame[4]) | UInt16(frame[5]) << 8
        #expect(CRC16Modbus.checksum(frame[6...]) == crc)
    }
}

// MARK: Builder and allowlist

@Test func theTakePhotoFrameIsByteForByteTheOneThatWorkedOnTheGlasses() {
    #expect(HeyCyanCommand.takePhoto.bytes == hex("bc4103001050020101"))
    #expect(HeyCyanCommand.mediaCount.bytes == hex("bc4102000113" + "0204"))
}

@Test func anEmptyPayloadUsesFFFFAsItsChecksum() {
    #expect(HeyCyanFrame(command: 0x10, payload: []).encoded == [0xBC, 0x10, 0, 0, 0xFF, 0xFF])
}

@Test func onlyTakePhotoAndMediaCountCanBeBuilt() {
    #expect(HeyCyanCommand.allCases == [.takePhoto, .mediaCount])
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x01]) == .takePhoto)
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x04]) == .mediaCount)
}

@Test func dangerousCommandsCannotBeBuilt() {
    let forbidden: [[UInt8]] = [
        [0x02, 0x01, 0x0A],  // factory reset
        [0x02, 0x01, 0x0E],  // restart
        [0x02, 0x01, 0x05],  // OTA mode
        [0x02, 0x01, 0x04],  // Wi-Fi transfer mode (step 2, not now)
        [0x02, 0x01, 0x09],  // leave transfer mode
    ]
    for payload in forbidden {
        #expect(HeyCyanCommand(command: 0x41, payload: payload) == nil)
        for command in HeyCyanCommand.allCases { #expect(command.bytes != HeyCyanFrame(command: 0x41, payload: payload).encoded) }
    }
    // Firmware-update (DFU) opcodes: no command byte other than glasses control is reachable.
    for dfu: UInt8 in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0C, 0x60] {
        #expect(HeyCyanCommand(command: dfu, payload: []) == nil)
        #expect(HeyCyanCommand(command: dfu, payload: [0x01]) == nil)
    }
}

@Test func noOtherByteCombinationMapsToACommand() {
    var accepted: [HeyCyanCommand] = []
    for command in UInt8.min...UInt8.max {
        if let match = HeyCyanCommand(command: command, payload: []) { accepted.append(match) }
        for x in UInt8.min...UInt8.max {
            for payload in [[x], [0x02, x], [0x02, 0x01, x], [x, 0x01, 0x01]] {
                if let match = HeyCyanCommand(command: command, payload: payload) { accepted.append(match) }
            }
        }
    }
    // takePhoto is reached twice ([2,1,x] and [x,1,1] with x = 1/2), mediaCount once.
    #expect(Set(accepted.map(\.label)) == ["take_photo", "media_count"])
    #expect(accepted.filter { $0 == .mediaCount }.count == 1)
}

// MARK: Parser

@Test func everyCapturedFrameParsesAndRebuildsExactly() {
    for bytes in capturedFrames {
        var parser = HeyCyanFrameParser()
        let frames = parser.push(bytes)
        #expect(frames.count == 1)
        #expect(frames.first?.encoded == bytes)
        #expect(parser.pendingByteCount == 0)
        #expect(parser.droppedBytes == 0)
    }
}

@Test func framesSplitAcrossNotificationsAtAnyPointAreReassembled() {
    let stream = capturedFrames.flatMap { $0 }
    for size in 1...stream.count {
        let chunks = stride(from: 0, to: stream.count, by: size).map { Array(stream[$0..<min($0 + size, stream.count)]) }
        let (frames, parser) = parseAll(chunks)
        #expect(frames.map(\.encoded) == capturedFrames, "chunk size \(size)")
        #expect(parser.pendingByteCount == 0)
        #expect(parser.rejectedFrames == 0)
    }
}

@Test func severalFramesInOneNotificationAllCome() {
    let audio = audioFrame(7)
    let one = capturedFrames[5] + audio + capturedFrames[6] + capturedFrames[12]
    let (frames, _) = parseAll([one])
    #expect(frames.map(HeyCyanEvent.init) == [
        .battery(percent: 99), .micAudio(byteCount: 40), .micStarted,
        .mediaCount(HeyCyanMediaCount(photos: 7, videos: 0, recordings: 0)),
    ])
}

@Test func liveAudioInterleavedWithEventsIn20ByteNotificationsLosesNothing() {
    var expected: [[UInt8]] = []
    for (index, frame) in capturedFrames.enumerated() {
        expected.append(audioFrame(UInt8(index)))
        expected.append(frame)
    }
    let stream = expected.flatMap { $0 }
    let chunks = stride(from: 0, to: stream.count, by: 20).map { Array(stream[$0..<min($0 + 20, stream.count)]) }
    let (frames, parser) = parseAll(chunks)
    #expect(frames.map(\.encoded) == expected)
    #expect(parser.rejectedFrames == 0)
}

@Test func garbageBeforeAFrameIsDropped() {
    let (frames, parser) = parseAll([[0x00, 0x13, 0x37, 0xFF] + capturedFrames[6]])
    #expect(frames.map(\.encoded) == [capturedFrames[6]])
    #expect(parser.droppedBytes == 4)
}

@Test func aStray0xBCWithAWrongChecksumDoesNotHideTheNextFrame() {
    // 0xBC, command, length 2, wrong CRC, 2 bytes: a lookalike that must be rejected.
    let fake: [UInt8] = [0xBC, 0x73, 0x02, 0x00, 0x00, 0x00, 0x03, 0x01]
    let (frames, parser) = parseAll([fake + capturedFrames[7]])
    #expect(frames.map(\.encoded) == [capturedFrames[7]])
    #expect(parser.rejectedFrames == 1)
}

@Test func aStray0xBCThatOverlapsARealFrameStillLetsTheRealFrameThrough() {
    // The stray header claims 8 bytes of payload, which would swallow the real frame's start.
    let stray: [UInt8] = [0xBC, 0x41, 0x08, 0x00, 0x12, 0x34]
    let (frames, _) = parseAll([stray, capturedFrames[13], capturedFrames[16]])
    #expect(frames.map(\.encoded) == [capturedFrames[13], capturedFrames[16]])
}

@Test func anImpossibleLengthIsTreatedAsGarbage() {
    let huge: [UInt8] = [0xBC, 0x41, 0xFF, 0xFF, 0x00, 0x00]
    let (frames, parser) = parseAll([huge + capturedFrames[6]])
    #expect(frames.map(\.encoded) == [capturedFrames[6]])
    #expect(parser.rejectedFrames == 1)
    #expect(parser.pendingByteCount == 0)
}

@Test func aHalfFrameWaitsAndResetForgetsIt() {
    var parser = HeyCyanFrameParser()
    #expect(parser.push(capturedFrames[12].prefix(9)).isEmpty)
    #expect(parser.pendingByteCount == 9)
    parser.reset()
    #expect(parser.pendingByteCount == 0)
    #expect(parser.push(capturedFrames[6]).map(\.encoded) == [capturedFrames[6]])
}

// MARK: Events

@Test func deviceEventsDecode() {
    #expect(decode("bc7303004931056300") == .battery(percent: 99))
    #expect(decode("bc73030048a1056200") == .battery(percent: 98))
    #expect(decode("bc730200c0800301") == .micStarted)
    #expect(decode("bc730200c6d00a01") == .micStopped)
    #expect(decode("bc730e003a99120100100f02000f0f0300100a03") == .volume)
    #expect(decode("bc73080073070103000000000001") == .state(sequence: 3))
    #expect(decode("bc730800e4c70109000100000001") == .state(sequence: 9))
    #expect(decode("bc730200469a0b27") == .otherEvent(type: 0x0B))
}

@Test func glassesControlRepliesDecode() {
    #expect(decode("bc410b003b790204070000000000010000")
        == .mediaCount(HeyCyanMediaCount(photos: 7, videos: 0, recordings: 0)))
    #expect(decode("bc410b006a490204080001000000010000")
        == .mediaCount(HeyCyanMediaCount(photos: 8, videos: 1, recordings: 0)))
    #expect(decode("bc4105008c3d0201010002") == .photoReply)
    #expect(decode("bc4105000c4c020101ffff") == .photoReply)
}

@Test func audioAndUnknownFramesAreSizesOnly() {
    var parser = HeyCyanFrameParser()
    #expect(parser.push(audioFrame(1)).map(HeyCyanEvent.init) == [.micAudio(byteCount: 40)])
    let unknown = HeyCyanFrame(command: 0x22, payload: [1, 2, 3]).encoded
    #expect(parser.push(unknown).map(HeyCyanEvent.init) == [.unknown(command: 0x22, byteCount: 3)])
    let shortCount = HeyCyanFrame(command: 0x41, payload: [0x02, 0x04, 0x01]).encoded
    #expect(parser.push(shortCount).map(HeyCyanEvent.init) == [.controlReply(byteCount: 3)])
}

@Test func heyCyanNamesSortFirst() {
    #expect(HeyCyanDeviceName.looksLikeHeyCyan("L 802_0A1B"))
    #expect(HeyCyanDeviceName.looksLikeHeyCyan("M01_1234"))
    #expect(!HeyCyanDeviceName.looksLikeHeyCyan("Mars"))
    #expect(!HeyCyanDeviceName.looksLikeHeyCyan("Bruk's AirPods"))
}
