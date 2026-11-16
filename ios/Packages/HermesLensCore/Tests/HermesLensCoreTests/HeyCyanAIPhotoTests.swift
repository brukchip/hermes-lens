import Foundation
import Testing
@testable import HermesLensCore

// The AI photo over Bluetooth, checked against bytes seen on a real L802 on 2026-11-16.

private func bytes(_ string: String) -> [UInt8] {
    let digits = string.replacingOccurrences(of: " ", with: "")
    return stride(from: 0, to: digits.count, by: 2).map {
        let start = digits.index(digits.startIndex, offsetBy: $0)
        return UInt8(digits[start..<digits.index(start, offsetBy: 2)], radix: 16)!
    }
}

/// A chunk reply frame like the glasses send (the CRC is computed, the layout is real).
private func chunkFrame(total: Int, index: Int, image: [UInt8]) -> [UInt8] {
    HeyCyanFrame(command: 0xFD, payload: [0x01, UInt8(total & 0xFF), UInt8(total >> 8),
                                          UInt8(index & 0xFF), UInt8(index >> 8)] + image).encoded
}

/// A small fake JPEG split into `total` chunks.
private func fakeJPEG(chunks total: Int, per: Int = 40) -> (jpeg: [UInt8], chunks: [HeyCyanAIPhotoChunk]) {
    let body = (0..<(total * per - 4)).map { UInt8(truncatingIfNeeded: $0 % 200) }
    let jpeg = [0xFF, 0xD8, 0xFF, 0xE0] + body.dropFirst(4) + [0xFF, 0xD9]
    let chunks = stride(from: 0, to: jpeg.count, by: per).enumerated().map { index, start in
        HeyCyanAIPhotoChunk(total: total, index: index, bytes: Array(jpeg[start..<min(start + per, jpeg.count)]))
    }
    return (Array(jpeg), chunks)
}

// MARK: Frames out

@Test func theAIPhotoTriggerIsByteForByteTheOneThatWorkedOnTheGlasses() {
    // Size 2, as sent live.
    #expect(HeyCyanFrame(command: 0x41, payload: HeyCyanAIPhoto.triggerPayload(size: 2)).encoded
        == bytes("bc 41 06 00 1d d0 02 01 06 02 02 02"))
    let size = HeyCyanAIPhoto.size
    #expect((0...6).contains(size))
    #expect(HeyCyanCommand.takeAIPhoto.payload == [0x02, 0x01, 0x06, size, size, 0x02])
    #expect(HeyCyanCommand(command: 0x41, payload: [0x02, 0x01, 0x06, size, size, 0x02]) == .takeAIPhoto)
    // Only the configured size can be sent.
    let other: UInt8 = size == 2 ? 3 : 2
    #expect(HeyCyanCommand(command: 0x41, payload: HeyCyanAIPhoto.triggerPayload(size: other)) == nil)
    #expect(HeyCyanCommand.takeAIPhoto.label == "take_ai_photo")
}

@Test func thePullBudgetGrowsWithTheChunkCount() {
    #expect(HeyCyanAIPhoto.pullSeconds(chunkCount: 13) == 6.25)
    #expect(HeyCyanAIPhoto.pullSeconds(chunkCount: 62) == 18.5)
    #expect(HeyCyanAIPhoto.pullSeconds(chunkCount: 500) == 20)
    #expect(HeyCyanAIPhoto.pullSeconds(chunkCount: 0) == 3)
}

@Test func theChunkRequestIsByteForByteTheOneThatWorkedOnTheGlasses() {
    #expect(HeyCyanCommand.requestAIPhotoChunk(index: 0).bytes == bytes("bc fd 03 00 20 00 01 00 00"))
    // The index is little-endian.
    #expect(HeyCyanCommand.requestAIPhotoChunk(index: 0x0102).payload == [0x01, 0x02, 0x01])
    #expect(HeyCyanCommand(command: 0xFD, payload: [0x01, 0x0C, 0x00]) == .requestAIPhotoChunk(index: 12))
    // Nothing else on 0xFD.
    #expect(HeyCyanCommand(command: 0xFD, payload: [0x02, 0x00, 0x00]) == nil)
    #expect(HeyCyanCommand(command: 0xFD, payload: [0x01, 0x00]) == nil)
    #expect(HeyCyanCommand(command: 0xFD, payload: [0x01, 0x00, 0x00, 0x00]) == nil)
}

// MARK: Frames in

@Test func theTriggerReplyAndTheShotEventDecode() {
    var parser = HeyCyanFrameParser()
    let reply = HeyCyanFrame(command: 0x41, payload: bytes("02 01 06 ff ff")).encoded
    let shot = HeyCyanFrame(command: 0x73, payload: bytes("02 00 0d 01 00")).encoded
    #expect(parser.push(reply + shot).map(HeyCyanEvent.init) == [.aiPhotoReply, .aiPhotoReady(chunkCount: 13)])
    // Size 6: 62 chunks.
    #expect(HeyCyanEvent(HeyCyanFrame(command: 0x73, payload: bytes("02 00 3e 01 00"))) == .aiPhotoReady(chunkCount: 62))
    // A short type 02 event is not a shot.
    #expect(HeyCyanEvent(HeyCyanFrame(command: 0x73, payload: [0x02, 0x00])) == .otherEvent(type: 0x02))
}

@Test func theRealChunkHeadersParse() throws {
    // Frame headers seen live: chunk 0 and 1 of 13 (1013 image bytes each), and the last (668).
    let first = bytes("bc fd fa 03 28 2c 01 0d 00 00 00")
    let second = bytes("bc fd fa 03 56 3f 01 0d 00 01 00")
    let last = bytes("bc fd a1 02 1d f7 01 0d 00 0c 00")
    for (header, index, imageBytes) in [(first, 0, 1013), (second, 1, 1013), (last, 12, 668)] {
        let length = Int(header[2]) | Int(header[3]) << 8
        #expect(length == HeyCyanAIPhotoChunk.headerLength + imageBytes)
        let payload = Array(header[6...]) + [UInt8](repeating: 0xAB, count: imageBytes)
        let chunk = try #require(HeyCyanAIPhotoChunk(payload: payload))
        #expect(chunk.total == 13)
        #expect(chunk.index == index)
        #expect(chunk.bytes.count == imageBytes)
    }
    #expect(HeyCyanAIPhotoChunk(payload: bytes("01 0d 00 00")) == nil)
    #expect(HeyCyanAIPhotoChunk(payload: bytes("01 00 00 00 00")) == nil)  // no chunks
    #expect(HeyCyanAIPhotoChunk(payload: bytes("01 0d 00 0d 00")) == nil)  // index past the total
}

@Test func aChunkFrameSplitAcrossNotificationsIsReassembled() throws {
    // A full-size chunk (1018-byte payload) in 20-byte notifications, then an event.
    let image = (0..<1013).map { UInt8(truncatingIfNeeded: $0) }
    let frame = chunkFrame(total: 13, index: 0, image: image)
    let event = HeyCyanFrame(command: 0x73, payload: [0x05, 0x62]).encoded
    let stream = frame + event
    var parser = HeyCyanFrameParser()
    var frames: [HeyCyanFrame] = []
    for start in stride(from: 0, to: stream.count, by: 20) {
        frames += parser.push(stream[start..<min(start + 20, stream.count)])
    }
    #expect(frames.count == 2)
    let chunk = try #require(HeyCyanAIPhotoChunk(frames[0]))
    #expect(chunk == HeyCyanAIPhotoChunk(total: 13, index: 0, bytes: image))
    #expect(HeyCyanEvent(frames[0]) == .aiPhotoChunk(index: 0, total: 13, byteCount: 1013))
    #expect(HeyCyanAIPhotoChunk(frames[1]) == nil)
    #expect(HeyCyanEvent(frames[1]) == .battery(percent: 98))
}

// MARK: Assembler

@Test func chunksInOrderGiveTheJPEG() throws {
    let (jpeg, chunks) = fakeJPEG(chunks: 13)
    var assembler = HeyCyanAIPhotoAssembler()
    #expect(assembler.nextIndex == 0)
    #expect(!assembler.isComplete)
    for chunk in chunks {
        #expect(assembler.jpeg == nil)
        #expect(assembler.accept(chunk) == .accepted)
    }
    #expect(assembler.isComplete)
    #expect(assembler.nextIndex == nil)
    #expect(assembler.total == 13)
    #expect(try #require(assembler.jpeg) == Data(jpeg))
}

@Test func repeatsSkipsAndAnotherTotalAreIgnored() {
    let (_, chunks) = fakeJPEG(chunks: 3)
    var assembler = HeyCyanAIPhotoAssembler()
    #expect(assembler.accept(chunks[1]) == .unexpected)  // skipped chunk 0
    #expect(assembler.accept(chunks[0]) == .accepted)
    #expect(assembler.accept(chunks[0]) == .duplicate)   // answer to a repeated request
    #expect(assembler.nextIndex == 1)
    #expect(assembler.accept(HeyCyanAIPhotoChunk(total: 4, index: 1, bytes: chunks[1].bytes)) == .unexpected)
    #expect(assembler.accept(chunks[2]) == .unexpected)
    #expect(assembler.accept(chunks[1]) == .accepted)
    #expect(assembler.byteCount == chunks[0].bytes.count + chunks[1].bytes.count)
    #expect(assembler.nextIndex == 2)
}

@Test func theJPEGIsCutFromItsStartToItsLastEndMarker() throws {
    // Junk before the start and padding after the end are dropped; an embedded thumbnail's
    // end marker does not cut it short.
    let body: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x01, 0xFF, 0xD8, 0xFF, 0x02, 0xFF, 0xD9, 0x03, 0x04, 0xFF, 0xD9]
    var assembler = HeyCyanAIPhotoAssembler()
    _ = assembler.accept(HeyCyanAIPhotoChunk(total: 2, index: 0, bytes: [0x00, 0x11] + body.prefix(8)))
    _ = assembler.accept(HeyCyanAIPhotoChunk(total: 2, index: 1, bytes: Array(body.dropFirst(8)) + [0x00, 0x00]))
    #expect(try #require(assembler.jpeg) == Data(body))
}

@Test func somethingThatIsNotAJPEGIsRejected() {
    var assembler = HeyCyanAIPhotoAssembler()
    _ = assembler.accept(HeyCyanAIPhotoChunk(total: 1, index: 0, bytes: Array("not a photo at all".utf8)))
    #expect(assembler.isComplete)
    #expect(assembler.jpeg == nil)
    // A start without an end is not a photo either.
    var open = HeyCyanAIPhotoAssembler()
    _ = open.accept(HeyCyanAIPhotoChunk(total: 1, index: 0, bytes: [0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]))
    #expect(!open.hasJPEGEnd)
    #expect(open.jpeg == nil)
}

@Test func aRawTailAfterTheLastChunkFinishesTheJPEG() throws {
    let (jpeg, chunks) = fakeJPEG(chunks: 2)
    var assembler = HeyCyanAIPhotoAssembler()
    // A tail before the last chunk is ignored.
    assembler.appendTail([0x55])
    #expect(assembler.byteCount == 0)
    _ = assembler.accept(chunks[0])
    // The last chunk without its final 10 bytes: those come as raw notifications.
    let cut = chunks[1].bytes.count - 10
    _ = assembler.accept(HeyCyanAIPhotoChunk(total: 2, index: 1, bytes: Array(chunks[1].bytes.prefix(cut))))
    #expect(assembler.isComplete)
    #expect(!assembler.hasJPEGEnd)
    assembler.appendTail(chunks[1].bytes[cut...].prefix(6))
    assembler.appendTail(chunks[1].bytes[(cut + 6)...])
    #expect(assembler.hasJPEGEnd)
    // Anything after the end is ignored.
    assembler.appendTail([0x99, 0x98])
    #expect(try #require(assembler.jpeg) == Data(jpeg))
}
