import SwiftUI

/// You › Glasses when HeyCyan (beta) is chosen: scan, pick, connect or forget, battery and a
/// test photo. The photo stays on the glasses in this version.
struct HeyCyanSettingsRows: View {
    @Environment(AppModel.self) private var model
    @State private var testPhotoMessage: String?
    @State private var isTakingTestPhoto = false
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
                Button(isTakingTestPhoto ? "Taking a photo…" : "Take a test photo") {
                    Task { await takeTestPhoto() }
                }
                .disabled(isTakingTestPhoto || glasses.isTakingPhoto)
                .accessibilityIdentifier("settings.heycyan.testPhoto")
            }
            if let testPhotoMessage {
                Text(testPhotoMessage)
                    .font(.footnote)
                    .foregroundStyle(LunaColor.secondaryText)
                    .accessibilityIdentifier("settings.heycyan.testPhoto.result")
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
        if glasses.isConnected { return "Connected · Photos stay on the glasses for now" }
        if glasses.state == .connecting { return "Connecting" }
        return model.settings.heyCyanPeripheralID == nil ? "Scan and pick your glasses" : "Not connected"
    }

    private func takeTestPhoto() async {
        isTakingTestPhoto = true
        testPhotoMessage = nil
        let outcome = await model.takeHeyCyanPhoto()
        testPhotoMessage = switch outcome {
        case .keptOnGlasses(let count): "Photo taken. The glasses now hold \(count) photo\(count == 1 ? "" : "s")."
        default: outcome.message
        }
        isTakingTestPhoto = false
    }
}
