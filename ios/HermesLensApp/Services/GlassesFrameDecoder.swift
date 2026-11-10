import CoreImage
import CoreMedia
import Foundation
import UIKit
import VideoToolbox

/// Where the camera-stream choice lives, shared by Settings and the glasses service.
enum GlassesStreamPreferences {
    static let compressedKey = "settings.compressedGlassesStream"

    /// True when the developer test asks for a compressed (HEVC) stream.
    static var usesCompressedStream: Bool {
        UserDefaults.standard.bool(forKey: compressedKey)
    }
}

/// Turns compressed glasses frames into ordinary image frames. DAT delivers compressed
/// samples for the `.hvc1` codec, and for `.raw` too once the app is
/// in the background; a compressed sample has no image, so without this a look or a video
/// would get nothing. Frames that already hold an image pass through untouched.
///
/// Called on the SDK's frame queue, one frame at a time; the lock keeps it safe anyway.
final class GlassesFrameDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let context = CIContext()

    /// True when the frame carries compressed data rather than an image.
    static func isCompressed(_ sample: CMSampleBuffer) -> Bool {
        CMSampleBufferGetImageBuffer(sample) == nil
    }

    /// The frame as an image frame, with its original timing; nil if it cannot be decoded.
    func imageFrame(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard Self.isCompressed(sample) else { return sample }
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let session = decompressionSession(for: description) else { return nil }

        final class Output: @unchecked Sendable { var image: CVImageBuffer? }
        let output = Output()
        // No asynchronous flag: the handler runs before DecodeFrame returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { output.image = image }
        }
        guard status == noErr, let image = output.image else { return nil }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        var imageFormat: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                     formatDescriptionOut: &imageFormat)
        guard let imageFormat else { return nil }
        var decoded: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: imageFormat,
                                                 sampleTiming: &timing, sampleBufferOut: &decoded)
        return decoded
    }

    /// A JPEG of an image frame (as `imageFrame` returns).
    func jpeg(_ imageFrame: CMSampleBuffer, quality: CGFloat = 0.9) -> Data? {
        guard let pixels = CMSampleBufferGetImageBuffer(imageFrame) else { return nil }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private func decompressionSession(for description: CMFormatDescription) -> VTDecompressionSession? {
        if let session, let format, CMFormatDescriptionEqual(format, otherFormatDescription: description) {
            return session
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        var created: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &created) == noErr, let created else { return nil }
        session = created
        format = description
        return created
    }
}
