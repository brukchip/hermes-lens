import SwiftUI

/// You › Glasses when HeyCyan (beta) is chosen: scan, pick, connect or forget, battery, a test
/// photo that stays on the glasses, and a test photo brought to this iPhone over the glasses'
/// Wi-Fi (shown as a thumbnail only: nothing is saved or sent, so no server is needed).
struct HeyCyanSettingsRows: View {
    @Environment(AppModel.self) private var model
    @State private var testPhotoMessage: String?
    @State private var isTakingTestPhoto = false
    /// The fetched test photo, in memory only.
    @State private var testPhoto: UIImage?
    @State private var testPhotoDetail: String?
    @State private var pickedID: UUID?

    static let warning = "These glasses accept Bluetooth commands from anyone nearby. Use them for testing, not for anything private."

    var body: some View {
        @Bindable var settings = model.settings
        let glasses = model.heyCyan
        let connecting = glasses.state == .connecting

        Group {
            HStack(spacing: 12) {
                Image(systemName: "eyeglasses")
                    .foregroundStyle(glasses.isConnected ? LunaColor.success : LunaColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.glassesStatus.name).font(.body.weight(.medium))
                    Text(statusDetail).font(.caption).foregroundStyle(LunaColor.secondaryText)
                }
                Spacer()
                Image(systemName: glasses.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(glasses.isConnected ? LunaColor.success : LunaColor.warning)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.heycyan.status")

            if glasses.isConnected {
                LabeledContent("Battery", value: glasses.batteryPercent.map {
                    glasses.batteryCharging == true ? "\($0)% · Charging" : "\($0)%"
                } ?? "Waiting for the glasses")
                    .accessibilityIdentifier("settings.heycyan.battery")
                Button("Take a test photo") {
                    Task { await takeTestPhoto(fetch: false) }
                }
                .disabled(isTakingTestPhoto || model.heyCyanTransfer.isBusy)
                .accessibilityIdentifier("settings.heycyan.testPhoto")
                Button("Take and fetch a test photo") {
                    Task { await takeTestPhoto(fetch: true) }
                }
                .disabled(isTakingTestPhoto || model.heyCyanTransfer.isBusy)
                .accessibilityIdentifier("settings.heycyan.fetchPhoto")
            }
            if let stage = model.heyCyanTransfer.stage {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(stage.displayText)
                        .font(.footnote)
                        .foregroundStyle(LunaColor.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.heycyan.testPhoto.progress")
            }
            if let testPhotoMessage {
                Text(testPhotoMessage)
                    .font(.footnote)
                    .foregroundStyle(LunaColor.secondaryText)
                    .accessibilityIdentifier("settings.heycyan.testPhoto.result")
            }
            if let testPhoto {
                VStack(alignment: .leading, spacing: 6) {
                    Image(uiImage: testPhoto)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
                        .accessibilityLabel("Test photo from your glasses")
                    if let testPhotoDetail {
                        Text(testPhotoDetail)
                            .font(.caption)
                            .foregroundStyle(LunaColor.secondaryText)
                    }
                }
                .accessibilityIdentifier("settings.heycyan.testPhoto.thumbnail")
            }

            if settings.heyCyanPeripheralID != nil {
                if !glasses.isConnected {
                    Button(connecting ? "Connecting…" : "Connect") {
                        Task { await model.connectRememberedHeyCyan() }
                    }
                    .disabled(connecting)
                    .accessibilityIdentifier("settings.heycyan.connect")
                }
                Button("Forget these glasses", role: .destructive) {
                    testPhotoMessage = nil
                    testPhoto = nil
                    testPhotoDetail = nil
                    model.forgetHeyCyan()
                }
                .accessibilityIdentifier("settings.heycyan.forget")
            }

            Button(glasses.isScanning ? "Scanning…" : "Scan for glasses") {
                Task { await glasses.scan() }
            }
            .disabled(glasses.isScanning || connecting)
            .accessibilityIdentifier("settings.heycyan.scan")

            if glasses.isScanning, glasses.found.isEmpty {
                Text("Looking for nearby glasses. Keep them switched on and unfolded.")
                    .font(.footnote)
                    .foregroundStyle(LunaColor.secondaryText)
            }
            ForEach(glasses.found.filter { $0.id != glasses.connectedID }) { device in
                Button {
                    pickedID = device.id
                    Task {
                        await model.connectHeyCyan(device)
                        pickedID = nil
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).foregroundStyle(LunaColor.text)
                            Text(device.likely ? "Looks like HeyCyan glasses" : "Other Bluetooth device")
                                .font(.caption)
                                .foregroundStyle(LunaColor.secondaryText)
                        }
                        Spacer()
                        if pickedID == device.id, connecting {
                            ProgressView()
                        } else {
                            Text("Connect").font(.lunaLabel).foregroundStyle(LunaColor.accent)
                        }
                    }
                }
                .disabled(connecting)
                .accessibilityIdentifier("settings.heycyan.device")
            }

            if let problem = model.heyCyanProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(LunaColor.danger)
                    .accessibilityIdentifier("settings.heycyan.problem")
            }

            Toggle("Assistant button starts a Luna call", isOn: $settings.heyCyanButtonStartsCall)
                .accessibilityIdentifier("settings.heycyan.buttonStartsCall")
        }
    }

    private var statusDetail: String {
        let glasses = model.heyCyan
        if case .unavailable = glasses.state { return glasses.state.displayName }
        if glasses.isConnected { return "Connected · Photos come over the glasses' Wi-Fi (beta)" }
        if glasses.state == .connecting { return "Connecting" }
        return model.settings.heyCyanPeripheralID == nil ? "Scan and pick your glasses" : "Not connected"
    }

    private func takeTestPhoto(fetch: Bool) async {
        isTakingTestPhoto = true
        testPhotoMessage = nil
        testPhoto = nil
        testPhotoDetail = nil
        let outcome = await model.takeHeyCyanPhoto(fetch: fetch)
        switch outcome {
        case .fetched(let jpeg, _):
            if let image = UIImage(data: jpeg) {
                testPhoto = image
                let width = Int(image.size.width * image.scale), height = Int(image.size.height * image.scale)
                testPhotoDetail = "\(width) × \(height) · \(jpeg.count / 1024) KB · not saved"
                testPhotoMessage = "Photo taken and brought to this iPhone."
            } else {
                testPhotoMessage = "The glasses sent a file this iPhone can't show as a photo."
            }
        case .keptOnGlasses(let count, nil):
            testPhotoMessage = "Photo taken. The glasses now hold \(count) photo\(count == 1 ? "" : "s")."
        default:
            testPhotoMessage = outcome.message
        }
        isTakingTestPhoto = false
    }
}
