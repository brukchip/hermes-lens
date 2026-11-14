import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The manual Wi-Fi join card for HeyCyan glasses, for builds that can't join the glasses'
/// network by themselves (no Hotspot Configuration entitlement). It shows the glasses' own
/// temporary network and password, while `HeyCyanPhotoTransfer` polls for the glasses and
/// continues by itself as soon as they answer. Nothing here is logged.
struct HeyCyanJoinCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        if let card = model.heyCyanTransfer.manualJoin {
            VStack(alignment: .leading, spacing: 10) {
                switch card.state.phase {
                case .waitingForJoin:
                    waiting(card)
                case .connected:
                    progress("Connected to the glasses. Bringing the photo over…")
                case .finished:
                    done("Got it. You can go back to your normal Wi-Fi; the iPhone usually switches back by itself.")
                case .gaveUp:
                    done("The glasses didn't answer on Wi-Fi. You can go back to your normal Wi-Fi.")
                }
            }
            .accessibilityIdentifier("heycyan.joinCard")
        }
    }

    @ViewBuilder
    private func waiting(_ card: HeyCyanPhotoTransfer.ManualJoinCard) -> some View {
        let password = card.password ?? ""
        Text("Join the glasses' Wi-Fi")
            .font(.body.weight(.semibold))
        Text("Open Settings › Wi-Fi, choose this network and enter the password. Then come back to Luna: she continues by herself as soon as the glasses answer.")
            .font(.footnote)
            .foregroundStyle(LunaColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent("Network") {
            Text(card.ssid).font(.body.monospaced()).textSelection(.enabled)
        }
        .accessibilityIdentifier("heycyan.joinCard.network")
        LabeledContent("Password") {
            Text(password.isEmpty ? "None" : password).font(.body.monospaced()).textSelection(.enabled)
        }
        .accessibilityIdentifier("heycyan.joinCard.password")
        HStack(spacing: 16) {
            Button(copied ? "Copied" : "Copy password") { copy(password) }
                .disabled(password.isEmpty)
                .accessibilityIdentifier("heycyan.joinCard.copy")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("heycyan.joinCard.openSettings")
            Spacer(minLength: 0)
            Button("Stop", role: .destructive) { model.heyCyanTransfer.stopManualJoin() }
                .accessibilityIdentifier("heycyan.joinCard.stop")
        }
        .buttonStyle(.borderless)
        Text("Open Settings shows Luna's own page: tap Settings at the top left, then Wi-Fi.")
            .font(.caption)
            .foregroundStyle(LunaColor.secondaryText)
        progress("Waiting for the glasses on Wi-Fi (up to 3 minutes)…")
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.footnote)
                .foregroundStyle(LunaColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func done(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
        Button("Done") { model.heyCyanTransfer.dismissManualJoin() }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("heycyan.joinCard.done")
    }

    /// This device only, and gone after five minutes: the network closes long before.
    private func copy(_ password: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: password]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        copied = true
    }
}
