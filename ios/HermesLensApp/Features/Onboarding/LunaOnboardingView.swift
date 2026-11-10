import AVFAudio
import SwiftUI

/// First run: who Luna is, pairing with a Hermes server, connecting the glasses,
/// and each permission explained before iOS asks for it.
struct LunaOnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var microphone = AVAudioApplication.shared.recordPermission

    var body: some View {
        ZStack {
            LunaBackground()
            TabView(selection: $page) {
                meet.tag(0)
                server.tag(1)
                glasses.tag(2)
                permissions.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .overlay(alignment: .topTrailing) {
            Button("Skip") { finish() }
                .font(.lunaLabel)
                .foregroundStyle(LunaColor.text)
                .padding(20)
                .accessibilityIdentifier("onboarding.skip")
        }
    }

    private var meet: some View {
        onboardingPage(title: "A little company.\nA clearer day.",
             message: "Hi, I'm Luna. Talk to me through your Ray-Ban Meta glasses. I can look at what you see, record a short clip, save a contact from a business card, and pass your requests to your own Hermes agent. Actions it gates wait for your tap.") {
            LunaCharacter(mood: .ready, size: 220)
        } action: {
            LunaPrimaryButton(title: "Continue", systemImage: "arrow.right", identifier: "onboarding.next") {
                withAnimation { page = 1 }
            }
        }
    }

    private var server: some View {
        ScrollView {
            VStack(spacing: 20) {
                LunaCharacter(mood: model.settings.hasServerConfiguration ? .ready : .listening, size: 150)
                    .padding(.top, 40)
                VStack(spacing: 10) {
                    Text("Pair with Hermes").font(.lunaDisplay).multilineTextAlignment(.center)
                    Text("Enter the address of your Hermes server and the access token from the Hermes Lens plugin.")
                        .font(.body).foregroundStyle(LunaColor.secondaryText).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ServerConnectionFields()
                        .textFieldStyle(.roundedBorder)
                }
                .padding(18)
                .lunaCard(radius: 24)
                Button(model.settings.hasServerConfiguration ? "Continue" : "Set up later") {
                    withAnimation { page = 2 }
                }
                .font(.lunaLabel)
                .foregroundStyle(LunaColor.text)
                .frame(minHeight: 44)
                .accessibilityIdentifier("onboarding.server.next")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 60)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var glasses: some View {
        onboardingPage(title: "Connect your glasses",
             message: model.glassesRegistrationState == .registered
                ? "Your glasses are set up. \(model.glassesState.displayName)."
                : "Luna connects to your glasses through the Meta AI app. You'll be asked to confirm there, then come straight back.") {
            LunaCharacter(mood: model.glassesRegistrationState == .registered ? .ready : .looking, size: 200)
        } action: {
            VStack(spacing: 12) {
                if model.glassesRegistrationState != .registered {
                    LunaPrimaryButton(title: "Set up with Meta AI", systemImage: "link", identifier: "onboarding.glasses") {
                        Task { await model.registerGlasses() }
                    }
                }
                Button(model.glassesRegistrationState == .registered ? "Continue" : "Set up later") {
                    withAnimation { page = 3 }
                }
                .font(.lunaLabel)
                .foregroundStyle(LunaColor.text)
                .frame(minHeight: 44)
                .accessibilityIdentifier("onboarding.glasses.next")
            }
        }
    }

    private var permissions: some View {
        onboardingPage(title: "Two quick permissions",
             message: "Luna asks only for what she needs. You can change these any time in iPhone Settings.") {
            VStack(alignment: .leading, spacing: 18) {
                permissionRow(symbol: "mic.fill", title: "Microphone",
                              detail: "So Luna can hear you — only while you're talking to her.",
                              granted: microphone == .granted, identifier: "onboarding.microphone") {
                    _ = await AVAudioApplication.requestRecordPermission()
                    microphone = AVAudioApplication.shared.recordPermission
                }
                permissionRow(symbol: "bell.fill", title: "Notifications",
                              detail: "For reminders you set.",
                              granted: model.notificationAuthorization == .authorized
                                  || model.notificationAuthorization == .provisional,
                              identifier: "onboarding.notifications") {
                    await model.requestNotificationAuthorization()
                }
            }
            .padding(18)
            .lunaCard(radius: 24)
        } action: {
            LunaPrimaryButton(title: "Start using Luna", systemImage: "waveform.and.mic", identifier: "onboarding.done") {
                finish()
            }
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String, granted: Bool,
                               identifier: String, request: @escaping @MainActor () async -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LunaPuck(systemImage: symbol, size: 40, fill: LunaColor.lime, tint: LunaColor.onLime)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.lunaLabel)
                Text(detail).font(.caption).foregroundStyle(LunaColor.secondaryText)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LunaColor.success)
                    .accessibilityLabel("Allowed")
            } else {
                Button("Allow") { Task { await request() } }
                    .buttonStyle(LunaSecondaryActionStyle())
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    private func onboardingPage<Art: View, Action: View>(title: String, message: String,
                                               @ViewBuilder art: () -> Art,
                                               @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            art()
            VStack(spacing: 10) {
                Text(title).font(.lunaDisplay).multilineTextAlignment(.center)
                Text(message).font(.body).foregroundStyle(LunaColor.secondaryText).multilineTextAlignment(.center)
            }
            Spacer(minLength: 12)
            action()
            Spacer(minLength: 50)
        }
        .padding(.horizontal, 28)
    }

    private func finish() {
        model.settings.hasCompletedOnboarding = true
    }
}
