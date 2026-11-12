import HermesLensCore
import SwiftUI
import UIKit

/// Server address and access token for the Hermes Lens plugin. Used by
/// onboarding and Settings. The token is saved to iPhone Keychain only.
struct ServerConnectionFields: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?
    @State private var isConnecting = false

    var body: some View {
        @Bindable var settings = model.settings
        TextField("https://your-hermes-server.example", text: $settings.bridgeURL)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .accessibilityLabel("Server address")
            .accessibilityIdentifier("settings.server.address")
        SecureField("Access token", text: $settings.accessToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("settings.server.token")
            .onSubmit { Task { await model.commitServerFields() } }
        Button {
            Task { await pasteSetupCode() }
        } label: {
            Label("Paste setup code", systemImage: "doc.on.clipboard")
        }
        .disabled(isConnecting)
        .accessibilityHint("Uses the code that hermes lens setup printed on your server.")
        .accessibilityIdentifier("settings.server.pasteCode")
        Button {
            Task { await connect() }
        } label: {
            HStack {
                Text(isConnecting ? "Connecting…" : "Save and connect")
                if isConnecting { Spacer(); ProgressView() }
            }
        }
        .disabled(isConnecting || !settings.hasServerConfiguration)
        .accessibilityIdentifier("settings.server.connect")
        if let status {
            Text(status)
                .font(.footnote)
                .foregroundStyle(LunaColor.secondaryText)
                .accessibilityIdentifier("settings.server.status")
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        let settings = model.settings
        settings.bridgeURL = settings.bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.accessToken = settings.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try settings.saveAccessToken()
        } catch {
            status = "The token could not be saved to Keychain."
            return
        }
        model.rebuildServices()
        await model.refreshReadiness()
        showConnectionStatus()
    }

    /// Reads the clipboard only on this tap. A valid code is applied only after the user
    /// confirms the server it names. The code is never logged or shown.
    private func pasteSetupCode() async {
        guard let code = UIPasteboard.general.string.flatMap(LunaSetupCode.parse) else {
            VoiceDiagnosticLog.record("setup.code", "result=invalid source=paste")
            status = LunaSetupCode.invalidMessage
            return
        }
        VoiceDiagnosticLog.record("setup.code", "result=ok source=paste")
        status = nil
        model.offerSetupCode(code)
    }

    private func showConnectionStatus() {
        switch model.connectionState {
        case .connected:
            status = model.lensConfiguration.supportsNativeVoice
                ? "Connected. Luna's live voice is ready."
                : "Connected, but live voice is not enabled on the server."
        case .offline(let detail):
            status = detail
        case .checking, .unchecked:
            status = nil
        }
    }
}

extension View {
    /// Asks before a setup code (pasted, or from a `<scheme>://setup?code=…` link) changes
    /// Luna's server: it names the host and port, and only Connect saves the address and token. Applied to the app shell and to onboarding
    /// (which covers the shell on first run).
    func setupCodeConfirmation(_ model: AppModel) -> some View {
        let host: String? = if case .confirm(let code) = model.setupPrompt { code.displayHost } else { nil }
        return self
            .alert(
                "Connect Luna to \(host ?? "this server")?",
                isPresented: Binding(
                    get: { if case .confirm = model.setupPrompt { true } else { false } },
                    set: { if !$0, case .confirm = model.setupPrompt { model.setupPrompt = nil } }
                )
            ) {
                Button("Connect") { Task { await model.answerSetupCode(connect: true) } }
                Button("Cancel", role: .cancel) { Task { await model.answerSetupCode(connect: false) } }
            } message: {
                Text("This setup code replaces Luna's server address and access token. Connect only if you just ran hermes lens setup on your own server.")
            }
            .alert(
                "Setup link not valid",
                isPresented: Binding(
                    get: { model.setupPrompt == .invalid },
                    set: { if !$0, model.setupPrompt == .invalid { model.setupPrompt = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.setupPrompt = nil }
            } message: {
                Text(LunaSetupCode.invalidMessage)
            }
    }
}
