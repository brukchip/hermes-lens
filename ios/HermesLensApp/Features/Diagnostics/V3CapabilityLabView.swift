import SwiftUI

struct V3CapabilityLabView: View {
    @Environment(AppModel.self) private var model
    @State private var audio = AudioDiagnosticService()
    @State private var cameraProbeResult = "Not run"
    @State private var isRunningCameraProbe = false
    @State private var labStartedCamera = false

    var body: some View {
        Form {
            Section {
                statusRow("Audio session", value: audio.state.displayName, ready: audio.state == .active)
                statusRow("Microphone permission", value: audio.permissionName, ready: audio.permissionName == "Allowed")
                statusRow("Ray-Ban input", value: audio.inputRoute, ready: audio.isUsingBluetoothInput)
                statusRow("Bluetooth output", value: audio.outputRoute, ready: audio.isUsingBluetoothOutput)

                if audio.state == .active {
                    Button("Stop audio test", role: .destructive) { audio.stop() }
                } else {
                    Button("Start audio test") {
                        Task { await audio.requestPermissionAndStart() }
                    }
                }
                Button("Speak route test") { audio.speakRouteTest() }
                    .disabled(audio.state != .active)
            } header: {
                Text("Ray-Ban audio route")
            } footer: {
                Text("This foreground diagnostic measures microphone level only. It does not save or upload audio.")
            }

            Section("Live microphone level") {
                ProgressView(value: audio.inputLevel)
                    .tint(audio.isUsingBluetoothInput ? .green : LunaColor.accent)
                    .accessibilityLabel("Microphone input level")
                LabeledContent("Sample rate", value: audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Hz" : "Unknown")
                LabeledContent("Channels", value: audio.channelCount > 0 ? "\(audio.channelCount)" : "Unknown")
                LabeledContent("I/O buffer", value: audio.ioBufferDuration > 0 ? audio.ioBufferDuration.formatted(.number.precision(.fractionLength(4))) + " s" : "Unknown")
                Text(audio.lastEvent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Glasses", value: model.glassesState.displayName)
                LabeledContent("Result", value: cameraProbeResult)

                Button(model.isObserverActive ? "Stop camera session" : "Start camera session for touchpad test") {
                    Task { await toggleCameraSession() }
                }
                .disabled(isRunningCameraProbe)

                Button("Run camera + audio photo probe") {
                    Task { await runCameraProbe() }
                }
                .disabled(audio.state != .active || isRunningCameraProbe)

                if isRunningCameraProbe {
                    ProgressView("Capturing one deliberate test photo…")
                }
            } header: {
                Text("Camera concurrency")
            } footer: {
                Text("Start the audio test first. The probe captures one JPEG. If no touchpad test session is running, it releases the camera. The photo is not saved by the lab.")
            }

            Section("Available inputs") {
                if audio.availableInputs.isEmpty {
                    Text("No audio inputs reported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(audio.availableInputs, id: \.self) { input in
                        Text(input).font(.footnote)
                    }
                }
            }

            Section("Physical checks") {
                Label("Tap the glasses touchpad during an active camera session and watch for Camera paused/resumed.", systemImage: "hand.tap")
                Label("Lock and unlock the phone while audio is active.", systemImage: "lock.iphone")
                Label("Fold the glasses and confirm the route/state changes truthfully.", systemImage: "eyeglasses")
                Label("Run the speech test and confirm sound stays in the glasses.", systemImage: "speaker.wave.2")
            }
        }
        .navigationTitle("Capability Lab")
        .navigationBarTitleDisplayMode(.inline)
        .lunaFormChrome()
        .onDisappear {
            audio.stop()
            if labStartedCamera && model.isObserverActive {
                Task { await model.toggleObserver() }
            }
        }
    }

    private func statusRow(_ title: String, value: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? .green : LunaColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func runCameraProbe() async {
        isRunningCameraProbe = true
        cameraProbeResult = "Running"
        defer { isRunningCameraProbe = false }
        if let byteCount = await model.runCameraAudioProbe() {
            cameraProbeResult = "Passed · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
        } else {
            cameraProbeResult = "Failed"
        }
    }

    private func toggleCameraSession() async {
        let wasActive = model.isObserverActive
        await model.toggleObserver()
        if !wasActive && model.isObserverActive {
            labStartedCamera = true
        } else if wasActive && !model.isObserverActive {
            labStartedCamera = false
        }
    }
}
