import AVKit
import HermesLensCore
import SwiftUI
import UIKit

enum VisualCaptureKind: String, Identifiable, Sendable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }

    var actionTitle: String {
        switch self {
        case .photo: "Take photo"
        case .video: "Record 6 seconds"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: "camera.viewfinder"
        case .video: "record.circle"
        }
    }

    var request: String {
        switch self {
        case .photo:
            "Check this deliberate glasses photo. Tell me what matters, including useful text, risks, or a practical next step."
        case .video:
            "Check this deliberate six-second glasses recording. Explain the important movement or change and one practical next step."
        }
    }
}

private enum VisualCapturePhase: Equatable {
    case ready
    case capturing
    case complete
    case captureFailed

    var isBusy: Bool {
        self == .capturing
    }
}

private enum PhotoSavePhase: Equatable {
    case idle
    case saving
    case saved
    case failed
}

struct VisualCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let kind: VisualCaptureKind

    @State private var phase: VisualCapturePhase = .ready
    @State private var artifactID: UUID?
    @State private var photo: UIImage?
    @State private var videoURL: URL?
    @State private var player: AVPlayer?
    @State private var failureReason: String?
    @State private var photoSavePhase: PhotoSavePhase = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    status
                    feedback
                    privacyNote
                }
                .padding(.horizontal, LunaMetrics.gutter)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(LunaBackground())
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LunaColor.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(LunaColor.text)
                        .disabled(phase.isBusy)
                        .accessibilityIdentifier("capture.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .interactiveDismissDisabled(phase.isBusy)
        }
        // The camera is a dark place in both appearances: images read best on black.
        .environment(\.colorScheme, .dark)
        .tint(LunaColor.lime)
        .onDisappear { player?.pause() }
    }

    // MARK: Image

    @ViewBuilder
    private var preview: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
                .overlay(alignment: .topLeading) { localBadge }
                .overlay { busyOverlay }
                .accessibilityLabel("Captured glasses photo")
        } else if let player {
            VideoPlayer(player: player)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
                .overlay(alignment: .topLeading) { localBadge }
                .overlay { busyOverlay }
                .accessibilityLabel("Captured six-second glasses recording")
        } else {
            // Before a frame exists: a neutral camera surface with framing guides, never an old image.
            RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous)
                .fill(LunaColor.surface)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { FramingGuides().padding(28) }
                .overlay {
                    VStack(spacing: 14) {
                        Image(systemName: kind == .photo ? "camera.viewfinder" : "video")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(LunaColor.lime)
                        Text(kind == .photo ? "Look at what you want to keep" : "Look toward what's moving")
                            .font(.lunaHeading)
                            .multilineTextAlignment(.center)
                        Text(kind == .photo ? "One photo from your glasses" : "Six seconds from your glasses")
                            .font(.subheadline)
                            .foregroundStyle(LunaColor.secondaryText)
                    }
                    .padding(32)
                }
                .overlay { busyOverlay }
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if phase.isBusy {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 10) {
                    if phase == .capturing, kind == .video {
                        Circle().fill(LunaColor.danger).frame(width: 14, height: 14)
                    } else {
                        ProgressView().tint(LunaColor.lime)
                    }
                    Text(kind == .photo ? "Taking photo…" : "Recording…")
                        .font(.lunaLabel)
                        .foregroundStyle(LunaColor.onEmphasis)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
        }
    }

    private var localBadge: some View {
        Label("On this iPhone", systemImage: "lock.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(LunaColor.onLime)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(LunaColor.lime, in: Capsule())
            .padding(12)
    }

    // MARK: Status

    private var status: some View {
        HStack(spacing: 14) {
            LunaCharacter(mood: phaseMood, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(phaseTitle)
                    .font(.lunaHeading)
                Text(phaseSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(LunaColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("capture.status")
    }

    private var phaseMood: LunaMood {
        switch phase {
        case .ready: .ready
        case .capturing: .looking
        case .complete: .ready
        case .captureFailed: .didntWork
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let artifact = currentArtifact, phase == .complete {
            VStack(alignment: .leading, spacing: 12) {
                Text("SAVED")
                    .font(.lunaBadge)
                    .tracking(0.8)
                    .foregroundStyle(LunaColor.secondaryText)
                Text("Your \(artifact.kind == .photo ? "photo" : "video") is in your Library. To have Luna describe what's in front of you, tap Look during a call.")
                    .font(.lunaLine)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(LunaMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lunaCard()
        } else if phase == .captureFailed {
            LunaErrorBanner(
                message: failureReason ?? (kind == .photo
                    ? "I couldn't take that photo. Check your glasses and try again."
                    : "I couldn't record that video. Check your glasses and try again."),
                actionTitle: "Try again", identifier: "capture.retryRecording"
            ) { Task { await captureAndSave() } }
        }
    }

    private var privacyNote: some View {
        Label("The original stays in Luna on this iPhone. Save to Photos keeps a separate copy in your gallery.",
              systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(LunaColor.secondaryText)
            .padding(.horizontal, 4)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if phase == .ready {
                LunaPrimaryButton(title: kind.actionTitle, systemImage: kind == .photo ? "camera.fill" : "record.circle",
                                  identifier: "capture.take") {
                    Task { await captureAndSave() }
                }
            } else if phase == .complete || phase == .captureFailed {
                if currentArtifact != nil {
                    LunaPrimaryButton(title: photoSaveTitle, systemImage: photoSaveImage,
                                      isDisabled: photoSavePhase == .saving || photoSavePhase == .saved,
                                      identifier: "capture.saveToPhotos") {
                        Task { await saveToPhotos() }
                    }
                }
                HStack(spacing: 8) {
                    Button("Take another") { resetForAnotherCapture() }
                        .buttonStyle(LunaSecondaryActionStyle())
                        .accessibilityIdentifier("capture.another")
                    if let videoURL {
                        ShareLink(item: videoURL) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(LunaSecondaryActionStyle())
                            .accessibilityIdentifier("capture.share")
                    } else if let artifact = currentArtifact {
                        AsyncShareCaptureButton(artifact: artifact)
                    }
                    Spacer(minLength: 0)
                    Button("Done") { dismiss() }
                        .buttonStyle(LunaSecondaryActionStyle(tint: LunaColor.onLime, fill: LunaColor.lime))
                        .accessibilityIdentifier("capture.done")
                }
            } else {
                Text("Keep looking toward it")
                    .font(.lunaLabel)
                    .foregroundStyle(LunaColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: LunaMetrics.pillHeight)
            }
        }
        .padding(.horizontal, LunaMetrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(LunaColor.background)
    }

    private var currentArtifact: CaptureArtifact? {
        guard let artifactID else { return nil }
        return model.artifacts.first { $0.id == artifactID }
    }

    private var phaseTitle: String {
        switch phase {
        case .ready: [.connected, .observing, .ready].contains(model.glassesState) ? "Glasses ready" : "I'll connect your glasses first"
        case .capturing: kind == .photo ? "Taking the photo" : "Recording six seconds"
        case .complete: "Saved"
        case .captureFailed: "That didn't work"
        }
    }

    private var phaseSubtitle: String {
        switch phase {
        case .ready:
            kind == .video
                ? "A short clip straight from your glasses."
                : "One photo, saved on this iPhone first."
        case .capturing: "Keep the glasses on and pointed at it."
        case .complete: "It's in your Library on this iPhone."
        case .captureFailed: "Nothing was saved or sent."
        }
    }

    private func captureAndSave() async {
        phase = .capturing
        artifactID = nil
        photo = nil
        videoURL = nil
        player = nil
        failureReason = nil
        photoSavePhase = .idle

        guard let artifact = await model.captureArtifact(kind: kind, request: kind.request) else {
            failureReason = model.lastCaptureError
            phase = .captureFailed
            return
        }
        artifactID = artifact.id
        await loadPreview(for: artifact)
        phase = .complete
    }

    private func loadPreview(for artifact: CaptureArtifact) async {
        guard let url = await model.captureURL(for: artifact) else { return }
        switch artifact.kind {
        case .photo:
            if let data = await model.captureData(for: artifact) {
                photo = UIImage(data: data)
            }
        case .video:
            videoURL = url
            player = AVPlayer(url: url)
        }
    }

    private func resetForAnotherCapture() {
        player?.pause()
        phase = .ready
        artifactID = nil
        photo = nil
        videoURL = nil
        player = nil
        failureReason = nil
        photoSavePhase = .idle
    }

    private var photoSaveTitle: String {
        switch photoSavePhase {
        case .idle: "Save to Photos"
        case .saving: "Saving…"
        case .saved: "Saved to Photos"
        case .failed: "Try saving again"
        }
    }

    private var photoSaveImage: String {
        switch photoSavePhase {
        case .idle, .failed: "photo.badge.arrow.down"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle.fill"
        }
    }

    private func saveToPhotos() async {
        guard let artifact = currentArtifact else { return }
        photoSavePhase = .saving
        photoSavePhase = await model.saveCaptureToPhotos(artifact) ? .saved : .failed
        if photoSavePhase == .failed {
            failureReason = model.lastCaptureError
        }
    }
}

private struct AsyncShareCaptureButton: View {
    @Environment(AppModel.self) private var model
    let artifact: CaptureArtifact

    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("capture.share")
            } else {
                Button {
                    Task { url = await model.captureURL(for: artifact) }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("capture.share")
            }
        }
        .buttonStyle(LunaSecondaryActionStyle())
        .task { url = await model.captureURL(for: artifact) }
    }
}

/// Four corner marks: where the glasses are pointing, not a live preview.
private struct FramingGuides: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height, l: CGFloat = 26
            Path { p in
                for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] {
                    p.move(to: CGPoint(x: x, y: y + dy * l)); p.addLine(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x + dx * l, y: y))
                }
            }
            .stroke(LunaColor.secondaryText.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
