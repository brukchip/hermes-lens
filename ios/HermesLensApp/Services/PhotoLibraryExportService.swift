import Foundation
import HermesLensCore
import Photos

enum PhotoLibraryExportError: Error, LocalizedError {
    case permissionDenied
    case missingCapture

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Allow Luna to add captures to Photos in iPhone Settings."
        case .missingCapture:
            "The original capture is no longer available on this iPhone."
        }
    }
}

struct PhotoLibraryExportService {
    func save(_ data: Data, kind: CaptureArtifactKind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryExportError.permissionDenied
        }

        switch kind {
        case .photo:
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        case .video:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermes-lens-photos-\(UUID().uuidString)")
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url, options: .atomic)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }
        }
    }
}
