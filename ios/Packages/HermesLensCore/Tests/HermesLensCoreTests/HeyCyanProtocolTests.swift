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

/// Every `HeyCyanCommand` case by name. `init(_:)` switches over the command without a
/// default, so a new command case does not compile until it is added here, and then the
/// allowlist tests below cover it (a case missing from `parameterless` fails them).
private enum CommandCase: CaseIterable {
    case takePhoto, mediaCount, batteryLevel, enterTransferMode, exitTransferMode, takeAIPhoto, requestAIPhotoChunk

    init(_ command: HeyCyanCommand) {
        switch command {
        case .takePhoto: self = .takePhoto
        case .mediaCount: self = .mediaCount
        case .batteryLevel: self = .batteryLevel
        case .enterTransferMode: self = .enterTransferMode
        case .exitTransferMode: self = .exitTransferMode
        case .takeAIPhoto: self = .takeAIPhoto
        case .requestAIPhotoChunk: self = .requestAIPhotoChunk
        }
    }

    /// Instances of this case: the parameter's edge values for the chunk request.
    var samples: [HeyCyanCommand] {
        switch self {
        case .takePhoto: [.takePhoto]
        case .mediaCount: [.mediaCount]
        case .batteryLevel: [.batteryLevel]
        case .enterTransferMode: [.enterTransferMode]
        case .exitTransferMode: [.exitTransferMode]
        case .takeAIPhoto: [.takeAIPhoto]
        case .requestAIPhotoChunk: [.requestAIPhotoChunk(index: 0), .requestAIPhotoChunk(index: 1), .requestAIPhotoChunk(index: 0xFFFF)]
        }
    }

    /// Matched by its layout, not listed in `parameterless`.
    var hasParameter: Bool { self == .requestAIPhotoChunk }

    static var everyCommand: [HeyCyanCommand] { allCases.flatMap(\.samples) }
}

/// Glasses control payloads that must never go out: factory reset, restart, OTA mode, reset
/// the glasses' Wi-Fi Direct.
private let forbiddenControlPayloads: [[UInt8]] = [[0x02, 0x01, 0x0A], [0x02, 0x01, 0x0E], [0x02, 0x01, 0x05], [0x02, 0x01, 0x0F]]

@Test func everyCommandCaseIsAllowlistedAndNoneIsDangerous() {
    for kind in CommandCase.allCases {
        for command in kind.samples {
            #expect(CommandCase(command) == kind)
            // Every case without a parameter is on the allowlist the decoder matches against.
            if !kind.hasParameter { #expect(HeyCyanCommand.parameterless.contains(command), "\(command)") }
            // Its bytes are one frame that maps back to the same command through the allowlist.
            var parser = HeyCyanFrameParser()
            let frames = parser.push(command.bytes)
            #expect(frames.count == 1)
            #expect(frames.first.flatMap { HeyCyanCommand(command: $0.command, payload: $0.payload) } == command)
            // Only glasses control, the battery request and chunk requests go out, and no
            // glasses control payload starts like a forbidden one.
            #expect([HeyCyanCommand.glassesControl, HeyCyanCommand.syncBattery, HeyCyanCommand.aiPhotoChunk].contains(command.command))
            if command.command == HeyCyanCommand.glassesControl {
                #expect(!forbiddenControlPayloads.contains { command.payload.starts(with: $0) }, "\(command)")
            }
        }
    }
    #expect(HeyCyanCommand.parameterless.count == CommandCase.allCases.filter { !$0.hasParameter }.count)
}

@Test func onlyTheAllowlistedCommandsCanBeBuilt() {
    #expect(HeyCyanCommand.parameterless == [
        .takePhoto, .mediaCount, .batteryLevel, .enterTransferMode, .exitTransferMode, .takeAIPhoto,
    ])
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x01]) == .takePhoto)
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x04]) == .mediaCount)
    #expect(HeyCyanCommand(command: 0x42, payload: [0x00, 0x00]) == .batteryLevel)
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x04, 0x02]) == .enterTransferMode)
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x09]) == .exitTransferMode)
}

// MARK: Battery request

@Test func theBatteryRequestIsCommand0x42WithTwoZeroBytes() {
    // 0xBC, 0x42, length 2, CRC-16/MODBUS of `00 00` (0xB001, little-endian), payload.
    #expect(HeyCyanCommand.batteryLevel.bytes == hex("bc42020001b00000"))
    #expect(CRC16Modbus.checksum([0x00, 0x00]) == 0xB001)
    #expect(HeyCyanCommand.batteryLevel.label == "battery_level")
}

@Test func theBatteryReplyCarriesPercentAndCharging() {
    var parser = HeyCyanFrameParser()
    let charging = HeyCyanFrame(command: 0x42, payload: [0x57, 0x01]).encoded
    let notCharging = HeyCyanFrame(command: 0x42, payload: [0x3C, 0x00]).encoded
    let percentOnly = HeyCyanFrame(command: 0x42, payload: [0x64]).encoded
    let tooHigh = HeyCyanFrame(command: 0x42, payload: [0xC8, 0x00]).encoded
    let empty = HeyCyanFrame(command: 0x42, payload: []).encoded
    #expect(parser.push(charging + notCharging + percentOnly + tooHigh + empty).map(HeyCyanEvent.init) == [
        .batteryReply(percent: 87, charging: true),
        .batteryReply(percent: 60, charging: false),
        .batteryReply(percent: 100, charging: false),
        .batteryReply(percent: 100, charging: false),
        .unknown(command: 0x42, byteCount: 0),
    ])
    // The reply's percent and charging bytes are frame bytes 6 and 7.
    #expect(charging[6] == 0x57 && charging[7] == 0x01)
}

@Test func theBatteryEventStillDecodesBesideTheReply() {
    #expect(decode("bc7303004931056300") == .battery(percent: 99))
}

@Test func dangerousCommandsCannotBeBuilt() {
    for payload in forbiddenControlPayloads {
        #expect(HeyCyanCommand(command: 0x41, payload: payload) == nil)
        for command in CommandCase.everyCommand { #expect(command.bytes != HeyCyanFrame(command: 0x41, payload: payload).encoded) }
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
    // takePhoto is reached twice ([2,1,x] and [x,1,1] with x = 1/2), mediaCount once, and
    // exit transfer once ([2,1,9]). Enter transfer needs four bytes ([2,1,4,2]), the AI photo
    // six. A chunk request is only 0xFD with `01` and a two-byte index ([1,1,1] here).
    #expect(Set(accepted.map(\.label)) == ["take_photo", "media_count", "exit_transfer_mode", "request_ai_photo_chunk"])
    #expect(accepted.filter { $0.label == "request_ai_photo_chunk" } == [.requestAIPhotoChunk(index: 257)])
    #expect(accepted.filter { $0 == .exitTransferMode }.count == 1)
    #expect(HeyCyanCommand(command: 0x42, payload: [0x00]) == nil)
    #expect(HeyCyanCommand(command: 0x42, payload: [0x00, 0x01]) == nil)
    // 0x45 is the AI voice heartbeat in the vendor header, not a transfer "proceed".
    #expect(HeyCyanCommand(command: 0x45, payload: [0x04, 0x01]) == nil)
    // Only the hotspot variant of transfer mode: not the Android Wi-Fi Direct ones.
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x04]) == nil)
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x04, 0x01]) == nil)
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
    // The M01 answers `02 01 01 FF 01`: still just "accepted".
    var parser = HeyCyanFrameParser()
    let m01Reply = HeyCyanFrame(command: 0x41, payload: [0x02, 0x01, 0x01, 0xFF, 0x01]).encoded
    #expect(parser.push(m01Reply).map(HeyCyanEvent.init) == [.photoReply])
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
    #expect(HeyCyanDeviceName.looksLikeHeyCyan("L802_0001"))
    #expect(HeyCyanDeviceName.looksLikeHeyCyan("M01_0C2D"))
    #expect(!HeyCyanDeviceName.looksLikeHeyCyan("My Phone"))
    #expect(!HeyCyanDeviceName.looksLikeHeyCyan("Someone's AirPods"))
}

// MARK: Assistant button vs. the glasses' own listening after a photo

@Test func micStartedWithoutAPhotoIsAButtonPress() {
    let filter = HeyCyanAssistantButtonFilter()
    #expect(filter.isButtonPress(micStartedAt: Date(timeIntervalSince1970: 1000)))
}

@Test func micStartedWithinTenSecondsOfThePhotoCommandIsNotAButtonPress() {
    let sent = Date(timeIntervalSince1970: 1000)
    var filter = HeyCyanAssistantButtonFilter()
    filter.photoCommandSent(at: sent)
    // The M01 started its mic right after the photo and streamed ~5 s of audio by itself.
    #expect(!filter.isButtonPress(micStartedAt: sent))
    #expect(!filter.isButtonPress(micStartedAt: sent.addingTimeInterval(0.4)))
    #expect(!filter.isButtonPress(micStartedAt: sent.addingTimeInterval(9.9)))
    #expect(filter.isButtonPress(micStartedAt: sent.addingTimeInterval(10)))
    #expect(filter.isButtonPress(micStartedAt: sent.addingTimeInterval(60)))
}

@Test func eachPhotoCommandRestartsTheQuietWindow() {
    let first = Date(timeIntervalSince1970: 1000)
    var filter = HeyCyanAssistantButtonFilter()
    filter.photoCommandSent(at: first)
    filter.photoCommandSent(at: first.addingTimeInterval(8))
    #expect(!filter.isButtonPress(micStartedAt: first.addingTimeInterval(12)))
    #expect(filter.isButtonPress(micStartedAt: first.addingTimeInterval(18)))
}

// MARK: Transfer mode (documented by the community; not yet tried on hardware)

/// A transfer-mode reply as documented: `02 01 04 01 <name len> <password len> <name> <password>`.
private func transferReply(ssid: String, password: String, status: UInt8 = 0x01) -> [UInt8] {
    let name = Array(ssid.utf8), secret = Array(password.utf8)
    return [0x02, 0x01, 0x04, status, UInt8(name.count & 0xFF), UInt8(name.count >> 8),
            UInt8(secret.count & 0xFF), UInt8(secret.count >> 8)] + name + secret
}

@Test func theTransferFramesMatchTheOfficialAppsHotspotFrame() {
    // Byte for byte the frame the official iPhone app sends (captured), which made the L802
    // open its own hotspot.
    #expect(HeyCyanCommand.enterTransferMode.bytes == hex("bc410400d35d02010402"))
    #expect(HeyCyanCommand.exitTransferMode.bytes == hex("bc4103001196020109"))
}

@Test func theTransferReplyGivesTheGlassesWiFiNameAndPassword() {
    let frame = HeyCyanFrame(command: 0x41, payload: transferReply(ssid: "Glasses_1234", password: "example-pass")).encoded
    // Spread over 20-byte notifications, as BLE delivers it.
    let chunks = stride(from: 0, to: frame.count, by: 20).map { Array(frame[$0..<min($0 + 20, frame.count)]) }
    let (frames, _) = parseAll(chunks)
    #expect(frames.map(HeyCyanEvent.init) == [
        .transferCredentials(HeyCyanWiFiCredentials(ssid: "Glasses_1234", password: "example-pass")),
    ])
}

@Test func theReportedPasswordIsTriedFirstThenTheFixedOne() {
    #expect(HeyCyanWiFiCredentials(ssid: "Glasses_1234", password: "abcd12345").passwordsToTry == ["abcd12345", "123456789"])
    #expect(HeyCyanWiFiCredentials(ssid: "Glasses_1234", password: "123456789").passwordsToTry == ["123456789"])
    #expect(HeyCyanWiFiCredentials(ssid: "Glasses_1234", password: "").passwordsToTry == ["123456789"])
}

@Test func aReplyWithWorkType01ToTheHotspotRequestStillGivesCredentials() {
    // The L802 answered `02 01 04 01 …` to `02 01 04 02`; the network name has a space in it.
    let reply = transferReply(ssid: "Glasses 0A1B2C3D4E5F", password: "abcd12345", status: 0x01)
    #expect(HeyCyanWiFiCredentials(controlPayload: reply) == HeyCyanWiFiCredentials(ssid: "Glasses 0A1B2C3D4E5F", password: "abcd12345"))
    let hotspot = transferReply(ssid: "Glasses 0A1B2C3D4E5F", password: "abcd12345", status: 0x02)
    #expect(HeyCyanWiFiCredentials(controlPayload: hotspot)?.ssid == "Glasses 0A1B2C3D4E5F")
}

@Test func anOpenGlassesNetworkHasAnEmptyPassword() {
    let credentials = HeyCyanWiFiCredentials(controlPayload: transferReply(ssid: "Glasses_1234", password: ""))
    #expect(credentials == HeyCyanWiFiCredentials(ssid: "Glasses_1234", password: ""))
}

@Test func aTruncatedOrRefusedTransferReplyHasNoCredentials() {
    var full = transferReply(ssid: "Glasses_1234", password: "example-pass")
    full.removeLast()
    #expect(HeyCyanWiFiCredentials(controlPayload: full) == nil)
    #expect(HeyCyanWiFiCredentials(controlPayload: [0x02, 0x01, 0x04, 0x00]) == nil)
    #expect(HeyCyanWiFiCredentials(controlPayload: transferReply(ssid: "", password: "example-pass")) == nil)
    #expect(HeyCyanWiFiCredentials(controlPayload: transferReply(ssid: String(repeating: "a", count: 33), password: "x")) == nil)
    var parser = HeyCyanFrameParser()
    let refused = HeyCyanFrame(command: 0x41, payload: [0x02, 0x01, 0x04, 0x00]).encoded
    #expect(parser.push(refused).map(HeyCyanEvent.init) == [.transferModeReply(byteCount: 4)])
}

@Test func theCredentialsNeverPrintTheirPasswordOrName() {
    let credentials = HeyCyanWiFiCredentials(ssid: "Glasses_1234", password: "example-pass")
    for text in [String(describing: credentials), String(reflecting: credentials), "\(credentials)",
                 String(describing: HeyCyanEvent.transferCredentials(credentials))] {
        #expect(!text.contains("example-pass"))
        #expect(!text.contains("Glasses_1234"))
    }
}

@Test func theExitReplyTheWiFiAddressAndTheErrorDecode() {
    var parser = HeyCyanFrameParser()
    let heartbeat = HeyCyanFrame(command: 0x45, payload: [0x04, 0x01]).encoded
    let exit = HeyCyanFrame(command: 0x41, payload: [0x02, 0x01, 0x09, 0x01]).encoded
    let address = HeyCyanFrame(command: 0x73, payload: [0x08, 0xC0, 0xA8, 0x1F, 0x01]).encoded
    let zero = HeyCyanFrame(command: 0x73, payload: [0x08, 0, 0, 0, 0]).encoded
    let short = HeyCyanFrame(command: 0x73, payload: [0x08, 0xC0, 0xA8]).encoded
    // A public address (an impersonator pointing the app elsewhere) is not accepted.
    let publicAddress = HeyCyanFrame(command: 0x73, payload: [0x08, 0x08, 0x08, 0x08, 0x08]).encoded
    // Seen on the L802 about 20 s into transfer mode: `09 ff 02`.
    let wifiError = HeyCyanFrame(command: 0x73, payload: [0x09, 0xFF, 0x02]).encoded
    #expect(parser.push(heartbeat + exit + address + zero + short + publicAddress + wifiError).map(HeyCyanEvent.init) == [
        .unknown(command: 0x45, byteCount: 2), .exitTransferReply, .wifiAddress("192.168.31.1"),
        .otherEvent(type: 0x08), .otherEvent(type: 0x08), .otherEvent(type: 0x08), .wifiError(code: 255),
    ])
}

@Test func addressesAreCheckedAndOnlyPrivateOnesCount() {
    #expect(HeyCyanGlassesAddress.isUsableIPv4("192.168.49.14"))
    for bad in ["0.0.0.0", "255.255.255.255", "192.168.49", "192.168.49.256", "a.b.c.d", "192.168.49.1 ", "1..2.3", "+1.2.3.4"] {
        #expect(!HeyCyanGlassesAddress.isUsableIPv4(bad), "\(bad)")
        #expect(!HeyCyanGlassesAddress.isPrivateIPv4(bad), "\(bad)")
    }
    for good in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.1", "192.168.0.1", "192.168.31.1"] {
        #expect(HeyCyanGlassesAddress.isPrivateIPv4(good), "\(good)")
    }
    for publicAddress in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.64.0.1", "169.254.1.1", "127.0.0.1", "11.0.0.1"] {
        #expect(!HeyCyanGlassesAddress.isPrivateIPv4(publicAddress), "\(publicAddress)")
    }
}

@Test func thePhonesSubnetHoldsOnlyOtherPrivateHostsOfItsOwnNetwork() throws {
    let subnet = try #require(HeyCyanPhoneSubnet(address: "192.168.31.23", netmask: "255.255.255.0"))
    #expect(subnet.contains("192.168.31.1"))
    #expect(subnet.contains("192.168.31.254"))
    #expect(!subnet.contains("192.168.31.23"))   // the phone itself
    #expect(!subnet.contains("192.168.31.0"))    // network address
    #expect(!subnet.contains("192.168.31.255"))  // broadcast
    #expect(!subnet.contains("192.168.1.1"))     // another network
    #expect(!subnet.contains("8.8.8.8"))
    #expect(!subnet.contains("nonsense"))
    let wide = try #require(HeyCyanPhoneSubnet(address: "10.20.30.40", netmask: "255.255.0.0"))
    #expect(wide.contains("10.20.0.1"))
    #expect(!wide.contains("10.21.0.1"))
    // A public phone address, a broken or too-small netmask: no subnet at all.
    #expect(HeyCyanPhoneSubnet(address: "8.8.8.23", netmask: "255.255.255.0") == nil)
    #expect(HeyCyanPhoneSubnet(address: "192.168.49.23", netmask: "255.0.255.0") == nil)
    #expect(HeyCyanPhoneSubnet(address: "192.168.49.23", netmask: "255.255.255.255") == nil)
    #expect(HeyCyanPhoneSubnet(address: "192.168.49.23", netmask: "255.255.255.254") == nil)
    #expect(HeyCyanPhoneSubnet(address: "192.168.49.23", netmask: "0.0.0.0") == nil)
    #expect(HeyCyanPhoneSubnet(address: "nonsense", netmask: "255.255.255.0") == nil)
}

@Test func candidatesAreOnlyTheGlassesAddressesInsideThePhonesSubnet() throws {
    let glassesNetwork = HeyCyanPhoneSubnet(address: "192.168.31.23", netmask: "255.255.255.0")
    let homeNetwork = HeyCyanPhoneSubnet(address: "192.168.1.40", netmask: "255.255.255.0")
    // On the glasses' network: the reported address first, then the known one.
    #expect(HeyCyanGlassesAddress.candidates(reported: "192.168.31.7", phone: glassesNetwork)
        == ["192.168.31.7", "192.168.31.1"])
    #expect(HeyCyanGlassesAddress.candidates(reported: "192.168.31.1", phone: glassesNetwork) == ["192.168.31.1"])
    #expect(HeyCyanGlassesAddress.candidates(reported: nil, phone: glassesNetwork) == ["192.168.31.1"])
    // Still on another network, or on none: nothing is asked, not even the known address.
    #expect(HeyCyanGlassesAddress.candidates(reported: "192.168.31.1", phone: homeNetwork).isEmpty)
    #expect(HeyCyanGlassesAddress.candidates(reported: nil, phone: nil).isEmpty)
    // A reported address outside the phone's subnet, or a public one, is never used.
    #expect(HeyCyanGlassesAddress.candidates(reported: "192.168.1.1", phone: glassesNetwork) == ["192.168.31.1"])
    #expect(HeyCyanGlassesAddress.candidates(reported: "8.8.8.8", phone: glassesNetwork) == ["192.168.31.1"])
    // The glasses on another private subnet: their reported address when the phone is there.
    let other = HeyCyanPhoneSubnet(address: "192.168.49.20", netmask: "255.255.255.0")
    #expect(HeyCyanGlassesAddress.candidates(reported: "192.168.49.1", phone: other) == ["192.168.49.1"])
}

@Test func fileURLsArePlainHTTPUnderFiles() {
    #expect(HeyCyanGlassesAddress.mediaListURL(host: "192.168.49.14")?.absoluteString == "http://192.168.49.14/files/media.config")
    #expect(HeyCyanGlassesAddress.fileURL(host: "192.168.49.14", name: "20250102155119977.JPG")?.absoluteString
        == "http://192.168.49.14/files/20250102155119977.JPG")
    #expect(HeyCyanGlassesAddress.fileURL(host: "192.168.49.14", name: "photo 1.jpg")?.absoluteString
        == "http://192.168.49.14/files/photo%201.jpg")
    #expect(HeyCyanGlassesAddress.fileURL(host: "192.168.49.14", name: "../etc/passwd") == nil)
    #expect(HeyCyanGlassesAddress.fileURL(host: "example.com", name: "a.jpg") == nil)
    #expect(HeyCyanGlassesAddress.fileURL(host: "8.8.8.8", name: "a.jpg") == nil)
}

@Test func theMediaListIsOneNamePerLine() {
    let text = "20250102155119977.JPG\r\n20250102155200001.mp4\n\n  20250102155300002.opus \n/files/20250102155400003.jpg\n../secret.jpg\n"
    #expect(HeyCyanMediaList.fileNames(in: text)
        == ["20250102155119977.JPG", "20250102155200001.mp4", "20250102155300002.opus", "20250102155400003.jpg"])
    #expect(HeyCyanMediaList.fileNames(in: "") == [])
}

@Test func aPageThatIsNotAFileListIsRejectedWhole() {
    // A home router answering every path with 200 and its HTML page must not look like glasses
    // that list no photo: `<html>` alone would pass as a file name.
    for text in [
        "<html>\n<body>Router login</body>\n</html>\n",
        "<!DOCTYPE html>",
        "20250102155119977.JPG\n<script>x</script>\n",
        "{\"files\": [\"a.jpg\"]}",
        "a.jpg\n\"b.jpg\"\n",
        "a.jpg\u{0}\n",
        "a.jpg\u{1B}[0m\n",
        String(decoding: [0x61, 0x2E, 0x6A, 0x70, 0x67, 0xFF, 0xFE], as: UTF8.self),
    ] {
        #expect(HeyCyanMediaList.fileNames(in: text) == nil, "\(text.debugDescription)")
    }
    // Tabs and both kinds of line break are fine.
    #expect(HeyCyanMediaList.fileNames(in: "\ta.jpg\t\r\nb.jpg\r") == ["a.jpg", "b.jpg"])
}

@Test func theNewestPhotoIsChosenByItsTimestamp() {
    let names = ["20250102155400003.jpg", "20250102155119977.JPG", "20250102155500004.mp4", "20250101000000000.jpeg"]
    #expect(HeyCyanMediaList.newestPhoto(in: names) == "20250102155400003.jpg")
    // Without timestamps the last photo in the list.
    #expect(HeyCyanMediaList.newestPhoto(in: ["a.jpg", "clip.mp4", "b.JPG", "c.opus"]) == "b.JPG")
    #expect(HeyCyanMediaList.newestPhoto(in: ["clip.mp4", "voice.opus"]) == nil)
    #expect(HeyCyanMediaList.newestPhoto(in: []) == nil)
    // Timestamped names win over names without one.
    #expect(HeyCyanMediaList.newestPhoto(in: ["IMG_20251114_101500.jpg", "cover.jpg"]) == "IMG_20251114_101500.jpg")
}

@Test func onlyJPEGBytesCountAsAPhoto() {
    #expect(HeyCyanMediaList.looksLikeJPEG([0xFF, 0xD8, 0xFF, 0xE0, 0x00]))
    #expect(!HeyCyanMediaList.looksLikeJPEG(Array("<html>".utf8)))
    #expect(!HeyCyanMediaList.looksLikeJPEG([0xFF, 0xD8]))
    #expect(HeyCyanMediaList.looksLikeJPEG(Data([0xFF, 0xD8, 0xFF, 0xDB])))
}

// MARK: Fetch plan and the manual join card

@Test func theFetchPlanFollowsTheEntitlement() {
    #expect(HeyCyanFetchPlan.plan(automaticJoinAvailable: true) == .automaticJoin(budgetSeconds: 45))
    #expect(HeyCyanFetchPlan.plan(automaticJoinAvailable: false) == .manualJoin(budgetSeconds: 220))
    #expect(HeyCyanFetchPlan.manualJoin(budgetSeconds: 220).traceLabel == "manual_join")
    // The manual budget covers the whole 3-minute wait plus the photo and the download.
    #expect(Double(HeyCyanFetchPlan.manualBudgetSeconds) > HeyCyanManualJoin.maximumWait + 30)
}

@Test func theManualJoinCardPollsEveryOneAndAHalfSecondsForThreeMinutes() {
    var join = HeyCyanManualJoin(startedAt: 100)
    var now = 100.0
    while join.shouldPoll(at: now) {
        let pollStarted = now
        now += 0.3  // the poll itself
        join.recordPoll(answered: false, at: now)
        now += join.delayBeforeNextPoll(pollStartedAt: pollStarted, now: now)
    }
    // Polls start at 0, 1.5, … 178.5 s: 120 of them. The last ends before 180 s, so the loop
    // stops on time rather than on an answer, and ending the card then gives up.
    #expect(join.polls == 120)
    #expect(join.phase == .waitingForJoin)
    #expect(!join.shouldPoll(at: now))
    join.end()
    #expect(join.phase == .gaveUp)
    #expect(join.delayBeforeNextPoll(pollStartedAt: 0, now: 0.3) == 1.2)
    #expect(join.delayBeforeNextPoll(pollStartedAt: 0, now: 2.0) == 0)
    #expect(HeyCyanManualJoin.probeTimeout < HeyCyanManualJoin.pollInterval)
}

@Test func anUnansweredPollAtThreeMinutesGivesUp() {
    var join = HeyCyanManualJoin(startedAt: 0)
    join.recordPoll(answered: false, at: 179.9)
    #expect(join.phase == .waitingForJoin)
    join.recordPoll(answered: false, at: 180)
    #expect(join.phase == .gaveUp)
    join.recordPoll(answered: true, at: 181)
    #expect(join.phase == .gaveUp)
    #expect(join.polls == 2)
}

@Test func anAnswerConnectsStopsPollingAndEndsFinished() {
    var join = HeyCyanManualJoin(startedAt: 0)
    join.recordPoll(answered: false, at: 1.5)
    join.recordPoll(answered: true, at: 3)
    #expect(join.phase == .connected)
    #expect(!join.shouldPoll(at: 4))
    join.recordPoll(answered: false, at: 4.5)
    #expect(join.polls == 2)
    join.end()
    #expect(join.phase == .finished)
    join.end()
    #expect(join.phase == .finished)
}

@Test func endingWhileStillWaitingGivesUp() {
    var join = HeyCyanManualJoin(startedAt: 0)
    join.end()
    #expect(join.phase == .gaveUp)
    #expect(!join.shouldPoll(at: 1))
}
