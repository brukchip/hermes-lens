import AVKit
import HermesLensCore
import SwiftUI
import UIKit

struct CaptureArtifactDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let artifact: CaptureArtifact

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var localURL: URL?
    @State private var duration: TimeInterval?
    @State private var fileSize: Int?
    @State private var confirmsDeletion = false

    private var currentArtifact: CaptureArtifact {
        model.artifacts.first(where: { $0.id == artifact.id }) ?? artifact
    }

    var body: some View {
        ZStack {
            LunaBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    media

                    Text("\(currentArtifact.kind.displayName) · \(currentArtifact.capturedAt.formatted(date: .complete, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(LunaColor.secondaryText)

                    VStack(spacing: 12) {
                        LabeledContent(
                            "Captured",
                            value: currentArtifact.capturedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        LabeledContent("Type", value: currentArtifact.kind.displayName)
                        if let duration {
                            LabeledContent("Duration", value: duration.formattedDuration)
                        }
                        if let fileSize {
                            LabeledContent(
                                "Size",
                                value: ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                            )
                        }
                        LabeledContent("Original", value: "On this iPhone")
                    }
                    .padding(LunaMetrics.cardPadding)
                    .lunaCard(radius: 24)

                    Label(
                        "The original stays on this iPhone until you delete it. It leaves the phone only if you share it, or as the frame Luna looks at during a call.",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(LunaColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, LunaMetrics.gutter)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(currentArtifact.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .lunaPageChrome()
        .toolbar {
            if let localURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: localURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share capture")
                    .accessibilityIdentifier("media.share")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmsDeletion = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
                .accessibilityIdentifier("media.delete")
            }
        }
        .confirmationDialog(
            "Delete this \(currentArtifact.kind == .photo ? "photo" : "video") from this iPhone?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteArtifact(currentArtifact)
                    dismiss()
                }
            }
            .accessibilityIdentifier("media.delete.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("media.delete.cancel")
        }
        .task(id: artifact.id) { await loadMedia() }
    }

    @ViewBuilder
    private var media: some View {
        if currentArtifact.kind == .photo, let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
                .accessibilityLabel("Photo")
        } else if currentArtifact.kind == .video, let player {
            VideoPlayer(player: player)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous)
                .fill(LunaColor.raised)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { ProgressView() }
        }
    }

    private func loadMedia() async {
        guard let url = await model.captureURL(for: currentArtifact) else { return }
        localURL = url
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize

        if currentArtifact.kind == .photo,
           let data = await model.captureData(for: currentArtifact) {
            image = UIImage(data: data)
        } else if currentArtifact.kind == .video {
            player = AVPlayer(url: url)
            let asset = AVURLAsset(url: url)
            if let mediaDuration = try? await asset.load(.duration), mediaDuration.seconds.isFinite {
                duration = mediaDuration.seconds
            }
        }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = max(0, Int(rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
