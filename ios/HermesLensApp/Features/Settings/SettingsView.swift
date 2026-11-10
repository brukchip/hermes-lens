import SwiftUI
import UserNotifications

/// Settings: only controls that do something today. Demo mode and hardware
/// diagnostics live in a Developer section revealed by tapping the version 7 times.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var isPreparingExport = false
    @State private var showsDeleteConfirmation = false
    @State private var versionTaps = 0
    @State private var confirmsDisconnect = false
    @State private var cameraAllowed: Bool?

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                HStack(spacing: 16) {
                    LunaCharacter(mood: lunaReady ? .ready : .offline, size: 76, animated: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("You").font(.lunaCardTitle)
                        Text(lunaReady ? "Luna is with you" : "Luna is offline right now")
                            .font(.subheadline)
                            .foregroundStyle(LunaColor.secondaryText)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }

            Section {
                ServerConnectionFields()
            } header: {
                Text("Hermes server")
            } footer: {
                Text("The address of your Hermes server with the Hermes Lens plugin, and the access token you set for it (HERMES_LENS_TOKEN). The token is kept in iPhone Keychain.")
            }

            Section("Glasses") {
                statusRow(title: model.glassesInfo?.model ?? "Ray-Ban Meta", detail: glassesDetail,
                          ready: glassesReady, symbol: "eyeglasses")
                if let info = model.glassesInfo {
                    if let battery = info.battery {
                        LabeledContent("Battery", value: "\(battery)%\(info.isCharging ? " · Charging" : "")")
                            .accessibilityIdentifier("settings.glasses.battery")
                    }
                    if let worn = info.isWorn {
                        LabeledContent("On your face", value: worn ? "Yes" : "No")
                    }
                    if info.heat != .normal {
                        LabeledContent("Temperature", value: info.heat == .hot ? "Too hot for the camera" : "Warm")
                            .foregroundStyle(info.heat == .hot ? LunaColor.danger : LunaColor.warning)
                    }
                }
                if model.glassesRegistrationState == .registered, !settings.usesMockGlasses {
                    LabeledContent("Camera for Luna", value: cameraAllowed.map { $0 ? "Allowed" : "Not allowed" } ?? "Checking…")
                    if cameraAllowed == false {
                        Button("Allow camera in Meta AI") {
                            Task { cameraAllowed = await model.requestGlassesCameraPermission() }
                        }
                        .accessibilityIdentifier("settings.glasses.cameraPermission")
                    }
                }
                statusRow(title: "Luna", detail: lunaStatus, ready: lunaReady, symbol: "sparkles")
                if !settings.usesMockGlasses {
                    if model.glassesRegistrationState != .registered {
                        Button("Set up with Meta AI") { Task { await model.registerGlasses() } }
                            .accessibilityIdentifier("settings.glasses.register")
                    } else if !glassesReady {
                        Button("Connect glasses") { Task { await model.connectGlasses() } }
                            .accessibilityIdentifier("settings.glasses.connect")
                    }
                    if model.glassesRegistrationState == .registered {
                        Button("Disconnect Luna from glasses", role: .destructive) {
                            confirmsDisconnect = true
                        }
                        .accessibilityIdentifier("settings.glasses.unregister")
                    }
                }
                Button("Check connections") { Task { await model.refreshReadiness() } }
                    .accessibilityIdentifier("settings.checkConnections")
                if model.glassesRegistrationState == .registered, !settings.usesMockGlasses {
                    Button("Update glasses software") { Task { await model.openGlassesFirmwareUpdate() } }
                        .accessibilityIdentifier("settings.glasses.firmwareUpdate")
                    Button("Update Luna on the glasses") { Task { await model.openGlassesAppUpdate() } }
                        .accessibilityIdentifier("settings.glasses.appUpdate")
                }
            }

            Section {
                Toggle("Luna may use the glasses camera in calls", isOn: $settings.allowsCameraInCalls)
                    .accessibilityIdentifier("settings.privacy.camera")
                Toggle("Keep the camera ready during a call", isOn: $settings.keepsCameraReadyInCalls)
                    .disabled(!settings.allowsCameraInCalls)
                    .accessibilityIdentifier("settings.privacy.keepReady")
                Toggle("Glasses buttons control calls", isOn: $settings.usesGlassesGestures)
                    .accessibilityIdentifier("settings.privacy.gestures")
                LabeledContent("Face recognition", value: "Never")
                LabeledContent("Meta analytics", value: "Off")
            } header: {
                Text("Privacy & camera")
            } footer: {
                Text("Luna uses the camera only when you ask her to look or record, or tap Look. While the camera is on, Home shows “Camera on” — tap it to turn it off. Keeping it ready can make the next look faster, but the glasses may pause the camera feed while it waits. With glasses buttons on, during a call: press the capture button to have Luna look, hold it to record, double-tap the side to mute. While an approval card has been on screen for at least 1.5 seconds, a double tap approves it instead.")
            }

            Section {
                LabeledContent("Permission", value: notificationStatus)
                if model.notificationAuthorization == .notDetermined {
                    Button("Allow notifications") { Task { await model.requestNotificationAuthorization() } }
                        .accessibilityIdentifier("settings.notifications.allow")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Used only for reminders you set. They are scheduled on this iPhone.")
            }

            Section {
                LabeledContent("Calls", value: "30 days")
                LabeledContent("Photos and videos", value: "30 days")
                LabeledContent("Notes", value: "1 year")
                LabeledContent("Completed reminders", value: "90 days")
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share prepared export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("settings.export.share")
                } else {
                    Button {
                        isPreparingExport = true
                        Task { exportURL = await model.exportPersonalData(); isPreparingExport = false }
                    } label: {
                        Label(isPreparingExport ? "Preparing export…" : "Export my data",
                              systemImage: isPreparingExport ? "hourglass" : "archivebox")
                    }
                    .disabled(isPreparingExport)
                    .accessibilityIdentifier("settings.export.prepare")
                }
                Button("Delete everything on this iPhone", role: .destructive) { showsDeleteConfirmation = true }
                    .accessibilityIdentifier("settings.deleteAll")
            } header: {
                Text("Your data")
            } footer: {
                Text("Everything stays on this iPhone first. Call records never leave it. Expired items are removed automatically.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                    .contentShape(Rectangle())
                    .onTapGesture { revealDeveloperSettings() }
                    .accessibilityIdentifier("settings.version")
            }

            if settings.showsDeveloperSettings {
                developerSection
            }
        }
        .task(id: model.glassesRegistrationState) { cameraAllowed = await model.glassesCameraPermission() }
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.large)
        .lunaFormChrome()
        .confirmationDialog("Disconnect Luna from glasses?", isPresented: $confirmsDisconnect,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.unregisterGlasses() } }
                .accessibilityIdentifier("settings.glasses.unregister.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Luna stops using your glasses. You can reconnect any time with Meta AI.")
        }
        .confirmationDialog("Delete everything Luna keeps on this iPhone?",
                            isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                exportURL = nil
                Task { await model.deleteAllPersonalData() }
            }
            .accessibilityIdentifier("settings.deleteAll.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("settings.deleteAll.cancel")
        } message: {
            Text("Calls, photos, videos, notes and reminders are removed. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var developerSection: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("Demo Luna", isOn: $settings.usesMockHermes)
                .accessibilityIdentifier("settings.developer.demoLuna")
            Toggle("Demo glasses", isOn: $settings.usesMockGlasses)
                .accessibilityIdentifier("settings.developer.demoGlasses")
            Toggle("Compressed glasses stream (test)", isOn: $settings.usesCompressedGlassesStream)
                .accessibilityIdentifier("settings.developer.compressedStream")
            Button("Apply and reconnect") {
                model.rebuildServices()
                Task { await model.refreshReadiness() }
            }
            .accessibilityIdentifier("settings.developer.apply")
            NavigationLink("Hardware diagnostics") { V3CapabilityLabView() }
                .accessibilityIdentifier("settings.developer.lab")
            LabeledContent("Device ID", value: String(settings.deviceID.uuidString.prefix(8)))
            LabeledContent("Glasses SDK", value: "1.0.1")
            Button("Hide developer settings") { settings.showsDeveloperSettings = false }
                .accessibilityIdentifier("settings.developer.hide")
        } header: {
            Text("Developer")
        } footer: {
            Text("Demo modes run the app without a Hermes server or glasses.")
        }
    }

    private func revealDeveloperSettings() {
        versionTaps += 1
        if versionTaps >= 7 {
            model.settings.showsDeveloperSettings = true
            versionTaps = 0
        }
    }

    private func statusRow(title: String, detail: String, ready: Bool, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(ready ? LunaColor.success : LunaColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(LunaColor.secondaryText)
            }
            Spacer()
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? LunaColor.success : LunaColor.warning)
        }
        .accessibilityElement(children: .combine)
    }

    /// The glasses' own name and connection state, e.g. "Ray-Ban Meta · Ready".
    private var glassesDetail: String {
        guard let info = model.glassesInfo else { return model.glassesState.displayName }
        return "\(info.name) · \(model.glassesState.displayName)"
    }

    private var lunaReady: Bool {
        if case .connected = model.connectionState { return true }
        return model.settings.usesMockHermes
    }

    private var glassesReady: Bool {
        model.settings.usesMockGlasses
            || model.glassesState == .connected
            || model.glassesState == .observing
            || model.glassesState == .paused
            || model.glassesState == .ready
    }

    private var lunaStatus: String {
        switch model.connectionState {
        case .connected: "Online"
        case .offline: "Offline — check your connection"
        case .checking: "Checking…"
        case .unchecked: "Not checked yet"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [version, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    private var notificationStatus: String {
        switch model.notificationAuthorization {
        case .authorized: "Allowed"
        case .provisional: "Quiet delivery"
        case .denied: "Off — change in iPhone Settings"
        case .ephemeral: "Temporary"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}
