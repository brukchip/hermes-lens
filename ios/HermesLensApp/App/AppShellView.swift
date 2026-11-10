import HermesLensCore
import SwiftUI

enum LunaDestination: Hashable {
    /// A Library item opened from Today on Home.
    case item(LibraryItemRef)
}

enum SheetDestination: Identifiable {
    case remember(prefill: String)
    case reminder

    var id: String {
        switch self {
        case .remember: "remember"
        case .reminder: "reminder"
        }
    }
}

enum CaptureDestination: Identifiable {
    case photo
    case video

    var id: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        }
    }

    var kind: VisualCaptureKind {
        switch self {
        case .photo: .photo
        case .video: .video
        }
    }
}

@MainActor
struct AppShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let intentRouter: AppIntentRouter

    @State private var selectedTab: AppTab = .home
    @State private var lunaPath: [LunaDestination] = []
    @State private var libraryPath: [LibraryItemRef] = []
    @State private var sheet: SheetDestination?
    @State private var capture: CaptureDestination?
    /// Once onboarding is on screen it stays until finished, even if the
    /// glasses register mid-way (Meta AI returns before the permissions page).
    @State private var onboardingInProgress = false
    /// The one live call. Lives here, above the tabs, so leaving Home, opening a
    /// notification or running a shortcut never ends it; only End does.
    @State private var calls = LunaCallController()
    @State private var audioCoordinator: AudioSessionCoordinator
    /// Glasses buttons are listening for the running call.
    @State private var gesturesOn = false

    init(intentRouter: AppIntentRouter) {
        self.intentRouter = intentRouter
        let coordinator = AudioSessionCoordinator()
        _audioCoordinator = State(initialValue: coordinator)
    }

    var body: some View {
        @Bindable var bindableModel = model

        TabView(selection: $selectedTab) {
            NavigationStack(path: $lunaPath) {
                V3HomeView(
                    calls: calls,
                    talk: talkToLuna,
                    look: lookWithLuna,
                    openItem: { lunaPath = [.item($0)] },
                    openTab: { selectedTab = $0 },
                    showCapture: showCapture,
                    showReminder: { sheet = .reminder },
                    showRemember: { sheet = .remember(prefill: "") }
                )
                .navigationDestination(for: LibraryItemRef.self) { LibraryItemDetail(ref: $0) }
                .navigationDestination(for: LunaDestination.self) { destination in
                    switch destination {
                    case .item(let ref):
                        LibraryItemDetail(ref: ref)
                    }
                }
            }
            .lunaTabContent()
            .tag(AppTab.home)

            NavigationStack(path: $libraryPath) {
                LibraryView(
                    showReminder: { sheet = .reminder },
                    showNote: { sheet = .remember(prefill: "") },
                    open: { libraryPath.append($0) }
                )
                .navigationDestination(for: LibraryItemRef.self) { LibraryItemDetail(ref: $0) }
            }
            .lunaTabContent()
            .tag(AppTab.library)

            NavigationStack {
                LunaTasksView(calls: calls, showReminder: { sheet = .reminder }, talk: talkToLuna)
                    .navigationDestination(for: LibraryItemRef.self) { LibraryItemDetail(ref: $0) }
            }
            .lunaTabContent()
            .tag(AppTab.tasks)

            NavigationStack {
                SettingsView()
            }
            .lunaTabContent()
            .tag(AppTab.you)
        }
        .tint(LunaColor.accent)
        .overlay(alignment: .bottom) {
            LunaTabBar(
                selection: $selectedTab,
                mood: LunaMood(call: calls.call, isReconnecting: calls.isReconnecting, isOffline: false),
                isOnCall: calls.isActive,
                level: calls.call?.inputLevel ?? 0,
                talk: talkToLuna
            )
            .padding(.bottom, 4)
            .ignoresSafeArea(.keyboard)
        }
        .environment(\.askLuna) { text in askLuna(text) }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .remember(let prefill):
                RememberSheet(prefill: prefill)
            case .reminder:
                AddReminderSheet()
            }
        }
        .fullScreenCover(isPresented: Binding(get: { showsOnboarding }, set: { _ in })) {
            LunaOnboardingView()
                .onAppear { onboardingInProgress = true }
        }
        .fullScreenCover(item: $capture, onDismiss: {
            audioCoordinator.release(.visualCapture)
        }) { destination in
            VisualCaptureView(kind: destination.kind)
        }
        .alert(
            "Luna needs attention",
            isPresented: Binding(
                get: { bindableModel.errorMessage != nil },
                set: { if !$0 { bindableModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { bindableModel.errorMessage = nil }
        } message: {
            Text(bindableModel.errorMessage ?? "Unknown error")
        }
        .onChange(of: intentRouter.handledIntent?.id) {
            handleIntent()
        }
        .onChange(of: model.voiceLaunchRequest) { _, request in
            // "Hey Meta, start Luna": the same as tapping Talk.
            if request != nil { talkToLuna() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lunaReminderOpened)) { event in
            guard let id = event.object as? UUID else { return }
            selectedTab = .home
            lunaPath = [.item(.reminder(id))]
        }
        .task {
            calls.onFinished = { [model] started, ended, turns, actions in
                Task { await model.saveCall(startedAt: started, endedAt: ended, turns: turns, actions: actions) }
            }
        }
        #if DEBUG
        .task { await debugAutoTalk() }
        #endif
        .onChange(of: calls.call?.state.phase) { _, phase in
            // Once the call is connected and the glasses audio has settled (Meta: let
            // HFP settle before other glasses work), the glasses buttons control it.
            guard phase == .listening, !gesturesOn else { return }
            gesturesOn = true
            Task { [model, calls] in
                try? await Task.sleep(for: .seconds(2))
                guard calls.isActive else { return }
                await model.startGlassesGestures { gesture in
                    guard let call = calls.call, [.listening, .responding, .speaking].contains(call.state.phase) else { return }
                    switch gesture {
                    case .look: call.ask(Self.lookRequest)
                    case .record: call.ask("The user held the capture button on their glasses. Record a short video now.")
                    case .toggleMute:
                        // While Luna waits for an OK, a double tap approves it instead of muting:
                        // the user's own deliberate press, once, after the card has shown for 1.5 s.
                        if call.approval != nil, !call.approvalBusy,
                           let shown = call.approvalShownAt, Date.now.timeIntervalSince(shown) >= 1.5 {
                            VoiceDiagnosticLog.record("approval.gesture", "approved")
                            call.decideApproval(true)
                        } else {
                            call.toggleMute()
                        }
                    }
                }
            }
        }
        .onChange(of: calls.isActive) { _, active in
            guard !active, gesturesOn else { return }
            gesturesOn = false
            Task { await model.finishGlassesForCall() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.handleBecameActive() }
            } else if phase == .background, !hasLiveCall, capture == nil {
                // iOS may suspend or end the app in the background, and then nothing
                // would close the glasses session: close it now unless a call needs it.
                Task { await model.disconnectGlassesIfIdle() }
            }
        }
    }

    /// A call that is still connecting or talking (a failed or ended one keeps its panel).
    private var hasLiveCall: Bool {
        guard let call = calls.call else { return false }
        return ![.failed, .ended].contains(call.state.phase)
    }

    private func handleIntent() {
        guard let destination = intentRouter.handledIntent?.destination else { return }
        switch destination {
        case .talk: talkToLuna()
        case .look: lookWithLuna()
        case .remember(let prefill): sheet = .remember(prefill: prefill)
        case .endCall: calls.end()
        }
        intentRouter.handledIntent = nil
    }

    /// First run only: until finished or skipped, and never once glasses are
    /// registered (existing installs skip it). `-LunaShowOnboarding` forces it for tests.
    private var showsOnboarding: Bool {
        if ProcessInfo.processInfo.arguments.contains("-LunaShowOnboarding") {
            return !model.settings.hasCompletedOnboarding
        }
        guard !model.settings.hasCompletedOnboarding else { return false }
        return onboardingInProgress
            || (model.glassesRegistrationState != .registered && !model.settings.usesMockGlasses)
    }

    /// Talk to Luna: start the live call on Home, or return to the running one.
    private func talkToLuna() {
        startCall(ask: nil)
    }

    /// Ask Luna from anywhere (Library, a past call): the call runs on Home.
    private func askLuna(_ text: String) {
        startCall(ask: text)
    }

    /// Look: start the call if needed and ask Luna to look. One frame, on request.
    private func lookWithLuna() {
        startCall(ask: Self.lookRequest)
    }

    static let lookRequest = "The user tapped Look. Look through my glasses now and tell me briefly what you see."

    /// Fetches the server configuration first when it never arrived (it decides whether
    /// live voice is on), then starts or joins the call on Home.
    private func startCall(ask text: String?) {
        selectedTab = .home
        lunaPath.removeAll()
        guard !model.hasServerConfiguration, !model.settings.usesMockHermes,
              model.settings.hasServerConfiguration else {
            calls.start(makeCall, ask: text); return
        }
        Task {
            await model.refreshLensConfiguration()
            calls.start(makeCall, ask: text)
        }
    }

    /// The real Gemini call, the demo call in demo mode, or a call that explains
    /// why live voice is unavailable. There is no other voice engine.
    private func makeCall() -> any LunaCall {
        let voice = model.lensConfiguration.voice
        let path: String
        let call: any LunaCall
        if model.settings.usesMockHermes {
            path = "demo"; call = LunaDemoCall()
        } else if model.lensConfiguration.supportsNativeVoice,
                  let url = URL(string: model.settings.bridgeURL),
                  let configuration = try? HermesEndpointConfiguration(
                      baseURL: url, token: model.settings.accessToken,
                      sessionKey: model.settings.sessionKey, deviceID: model.settings.deviceID) {
            path = "native"
            call = LunaNativeSession(coordinator: audioCoordinator, configuration: configuration,
                                     localTools: nativeLocalTools)
        } else {
            path = "unavailable"
            call = LunaUnavailableCall(reason: !model.settings.hasServerConfiguration
                ? "Add your Hermes server address and access token in Settings."
                : voice.nativeAudioEnabled
                    ? "Luna can't reach her server. Check the server address and access token in Settings."
                    : "Luna's live voice is not available from your Hermes server right now.")
        }
        // Which path a call took, and the inputs that decided it. No identifiers.
        VoiceDiagnosticLog.record("talk.route", "path=\(path) native_enabled=\(voice.nativeAudioEnabled) "
            + "protocol_ok=\(voice.nativeAudioProtocol == LunaNativeVoice.protocolName) mock=\(model.settings.usesMockHermes)")
        return call
    }

    /// The glasses camera for native calls. Captures go to the Library like the
    /// Photo and Record flows.
    private var nativeLocalTools: LunaNativeLocalTools {
        LunaNativeLocalTools(
            capturePhoto: { [model] in
                guard model.settings.allowsCameraInCalls else { throw LunaCameraError(code: "camera_off_in_settings") }
                if let blocker = model.glassesCameraBlocker { throw LunaCameraError(code: blocker) }
                do { return try await model.captureCallFrame() }
                catch { throw LunaCameraError(code: "photo_glasses_\(model.glassesState)") }
            },
            recordVideo: { [model] in
                guard model.settings.allowsCameraInCalls else { throw LunaCameraError(code: "camera_off_in_settings") }
                if let blocker = model.glassesCameraBlocker { throw LunaCameraError(code: blocker) }
                await model.holdGlassesCameraForCall()
                guard await model.captureArtifact(kind: .video, request: "Video from a Luna call") != nil else {
                    throw LunaCameraError(code: "video_glasses_\(model.glassesState)")
                }
            },
            endCall: { [model] in await model.finishGlassesForCall() }
        )
    }

    private func showCapture(_ destination: CaptureDestination) {
        do {
            try audioCoordinator.claim(.visualCapture)
            capture = destination
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// Self-test hook: `devicectl device process launch … -LunaAutoTalk 60` starts a
    /// native call at launch and ends it after N seconds, so the glasses path can be
    /// exercised from the Mac (prompts spoken with `say`) without anyone tapping.
    /// Debug builds only.
    private func debugAutoTalk() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-LunaAutoTalk") else { return }
        let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 60 : 60
        try? await Task.sleep(for: .seconds(2))
        VoiceDiagnosticLog.record("selftest.start", "seconds=\(Int(seconds))")
        LunaSelfTest.isRunning = true
        talkToLuna()
        try? await Task.sleep(for: .seconds(seconds))
        calls.end()
        LunaSelfTest.isRunning = false
        VoiceDiagnosticLog.record("selftest.end")
    }
    #endif

}

private extension View {
    /// A tab's content: the system tab bar is replaced by the floating one, and
    /// every screen keeps its last rows clear of it.
    func lunaTabContent() -> some View {
        toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 72) }
    }
}
