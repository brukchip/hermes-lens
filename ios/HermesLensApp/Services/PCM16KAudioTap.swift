import AVFAudio
import Foundation
import HermesLensCore

/// The input format could not be converted to 16 kHz mono PCM.
enum PCM16KAudioTapError: Error {
    case unsupportedInputFormat
}

extension HermesPCM16KAudioTap {
    /// The block to pass to `installTap`. AVFoundation calls it on its realtime
    /// messenger queue. A closure written inside a `@MainActor` method inherits main
    /// actor isolation, and Swift 6 traps when it runs anywhere else — every native
    /// call crashed on its first microphone buffer this way (2026-10-30). Built
    /// here, in a nonisolated method, the closure carries no actor.
    func tapBlock(onFirstBuffer: (@Sendable (Int) -> Void)? = nil) -> AVAudioNodeTapBlock {
        let once = FirstBufferFlag()
        return { [self] buffer, _ in
            if let onFirstBuffer, once.claim() { onFirstBuffer(Int(buffer.frameLength)) }
            consume(buffer)
        }
    }
}

/// True exactly once; safe on the audio thread.
final class FirstBufferFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return claimed }
}

final class HermesPCM16KAudioTap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let chunkHandler: @Sendable (Data) -> Void
    private let levelHandler: (@Sendable (Double) -> Void)?
    private var pending = Data()

    init(
        inputFormat: AVAudioFormat,
        chunkHandler: @escaping @Sendable (Data) -> Void,
        levelHandler: (@Sendable (Double) -> Void)? = nil
    ) throws {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw PCM16KAudioTapError.unsupportedInputFormat
        }
        self.outputFormat = outputFormat
        self.converter = converter
        self.chunkHandler = chunkHandler
        self.levelHandler = levelHandler
    }

    func consume(_ input: AVAudioPCMBuffer) {
        if let channel = input.floatChannelData?.pointee, input.frameLength > 0 {
            var sum = 0.0
            for index in 0..<Int(input.frameLength) {
                let sample = Double(channel[index])
                sum += sample * sample
            }
            levelHandler?(min(1, sqrt(sum / Double(input.frameLength)) * 8))
        }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else { return }
        let conversionInput = PCMConversionInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !conversionInput.supplied else {
                state.pointee = .noDataNow
                return nil
            }
            conversionInput.supplied = true
            state.pointee = .haveData
            return conversionInput.buffer
        }
        guard
            status != .error,
            conversionError == nil,
            output.frameLength > 0,
            let channel = output.int16ChannelData?.pointee
        else { return }
        pending.append(
            Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        )
        while pending.count >= LunaNativeWire.inputChunkBytes {
            let chunk = pending.prefix(LunaNativeWire.inputChunkBytes)
            pending.removeFirst(LunaNativeWire.inputChunkBytes)
            chunkHandler(Data(chunk))
        }
    }
}

private final class PCMConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
