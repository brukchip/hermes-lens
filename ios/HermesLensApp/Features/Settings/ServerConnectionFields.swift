import SwiftUI

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
