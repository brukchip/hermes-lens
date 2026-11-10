import HermesLensCore
import SwiftUI

/// Home: Luna first, then what matters today. The live call happens here too:
/// Luna moves up, and the call takes the bento's place until End.
struct V3HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let calls: LunaCallController
    let talk: () -> Void
    let look: () -> Void
    let openItem: (LibraryItemRef) -> Void
    let openTab: (AppTab) -> Void
    let showCapture: (CaptureDestination) -> Void
    let showReminder: () -> Void
    let showRemember: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                glassesPill
                if !calls.isActive, needsServerSetup {
                    LunaErrorBanner(
                        message: "Add your Hermes server so Luna can talk to your agent.",
                        systemImage: "server.rack",
                        actionTitle: "Set up",
                        identifier: "home.service.setup"
                    ) { openTab(.you) }
                } else if !calls.isActive, isServerOffline {
                    LunaErrorBanner(
                        message: "Luna's server can't be reached. Check your connection to your Hermes server, then try again.",
                        systemImage: "wifi.exclamationmark",
                        actionTitle: "Try again",
                        identifier: "home.service.retry"
                    ) { Task { await model.checkConnection() } }
                }
                presence
                if let call = calls.call {
                    LunaCallPanel(call: call, isReconnecting: calls.isReconnecting,
                                  look: look, talkAgain: talk, end: calls.end)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    bento
                    quickActions
                    if !todayEntries.isEmpty { todaySection }
                }
            }
            .animation(.snappy, value: calls.isActive)
            .padding(.horizontal, LunaMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LunaBackground())
        .refreshable { await model.refreshAll() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: calls.call?.state.phase) { _, phase in
            if let phase { calls.callPhaseChanged(phase) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(calls.isActive ? "Luna" : "Hi there")
                .font(.lunaDisplay)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.title")
            Spacer(minLength: 8)
            Button { openTab(.you) } label: {
                Image(systemName: "person.fill")
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(LunaColor.text)
                    .frame(width: 46, height: 46)
                    .background(LunaColor.raised, in: Circle())
            }
            .buttonStyle(LunaPressStyle())
            .accessibilityLabel("You and settings")
            .accessibilityIdentifier("home.settings")
        }
    }

    /// The glasses' real state, with its one fix when they are not ready.
    private var glassesPill: some View {
        Button {
            Task { await glassesAction() }
        } label: {
            LunaStatusPill(title: glassesPillTitle, systemImage: model.isGlassesCameraHeld ? "record.circle" : "eyeglasses",
                           tint: model.isGlassesCameraHeld ? LunaColor.danger
                               : (glassesReady && !glassesNeedAttention ? LunaColor.text : LunaColor.warning),
                           live: glassesReady && !model.isGlassesCameraHeld)
        }
        .buttonStyle(.plain)
        .disabled(glassesReady && !model.isGlassesCameraHeld || model.isAutoConnectingGlasses)
        .accessibilityHint(model.isGlassesCameraHeld ? "Turns off the glasses camera" : glassesReady ? "" : "Connects your glasses")
        .accessibilityIdentifier("home.glasses.connect")
    }

    private var glassesPillTitle: String {
        if model.isGlassesCameraHeld { return "Camera on · Tap to turn off" }
        if model.isAutoConnectingGlasses { return "Connecting to your glasses…" }
        if glassesReady {
            guard let info = model.glassesInfo else { return "Glasses ready · Private" }
            if info.heat == .hot { return "Glasses too hot · Camera paused" }
            if info.isFolded == true { return "Glasses folded" }
            if info.isWorn == false { return "Glasses ready · Not on your face" }
            if let battery = info.battery { return "Glasses ready · \(battery)%\(info.isCharging ? " ⚡︎" : "")" }
            return "Glasses ready · Private"
        }
        return model.glassesRegistrationState == .registered ? "Glasses not connected · Connect" : "Set up your glasses"
    }

    /// Low battery or heat turns the pill amber even when the glasses are ready.
    private var glassesNeedAttention: Bool {
        guard let info = model.glassesInfo else { return false }
        return info.heat == .hot || (info.battery.map { $0 <= 15 && !info.isCharging } ?? false)
    }

    private func glassesAction() async {
        if model.isGlassesCameraHeld {
            await model.releaseGlassesCameraForCall()
        } else if model.glassesRegistrationState == .registered {
            await model.connectGlasses()
        } else {
            await model.registerGlasses()
        }
    }

    // MARK: Luna

    private var presence: some View {
        VStack(spacing: 14) {
            LunaCharacter(mood: mood, level: calls.call?.inputLevel ?? 0, size: calls.isActive ? 126 : 210)
                .accessibilityIdentifier("home.orb")
            Text(statusLine)
                .font(.lunaLine)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .accessibilityIdentifier(calls.isActive ? "call.status" : "home.status")
                .accessibilityLabel("Luna: \(statusLine)")
            if !calls.isActive {
                LunaPrimaryButton(title: "Talk to Luna", systemImage: "mic.fill", identifier: "home.talk", action: talk)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: statusLine)
    }

    private var mood: LunaMood {
        LunaMood(call: calls.call, isReconnecting: calls.isReconnecting, isOffline: isServerOffline)
    }

    private var statusLine: String {
        guard let call = calls.call else { return mood.line }
        if calls.isReconnecting { return "Reconnecting…" }
        switch call.state.phase {
        case .ended: return "Call ended"
        case .failed: return LunaMood.didntWork.line
        default: break
        }
        if call.state.isMuted { return "Microphone muted" }
        if mood == .thinking, !call.tools.isEmpty { return "Working on it" }
        if mood == .needsOK, call.approval == nil { return "Please check this contact" }
        return mood.line
    }

    // MARK: Bento

    @ViewBuilder
    private var bento: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: LunaMetrics.cardGap) {
                photoCard.frame(height: 240)
                countCard
                nextCard
            }
        } else {
            VStack(spacing: LunaMetrics.cardGap) {
                HStack(alignment: .top, spacing: LunaMetrics.cardGap) {
                    photoCard
                        .frame(maxWidth: .infinity)
                        .frame(height: 248)
                    VStack(spacing: LunaMetrics.cardGap) {
                        countCard.frame(maxHeight: .infinity)
                        nextCard.frame(maxHeight: .infinity)
                    }
                    .frame(height: 248)
                    .containerRelativeFrame(.horizontal) { width, _ in (width - LunaMetrics.gutter * 2 - LunaMetrics.cardGap) * 0.43 }
                }
            }
        }
    }

    /// The latest glasses photo or clip, edge to edge.
    @ViewBuilder
    private var photoCard: some View {
        if let artifact = latestCapture {
            Button { openItem(.capture(artifact.id)) } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { CaptureImage(artifact: artifact) }
                    .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.kind == .photo ? "Latest photo" : "Latest video")
                            .font(.lunaLabel)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(artifact.capturedAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.caption)
                            .foregroundStyle(LunaColor.onEmphasisSecondary)
                    }
                    .foregroundStyle(LunaColor.onEmphasis)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LunaColor.emphasis.opacity(0.88), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(8)
                    }
                .overlay(alignment: .topLeading) {
                    Text(artifact.kind == .photo ? "PHOTO" : "VIDEO")
                        .font(.lunaBadge)
                        .foregroundStyle(LunaColor.onLime)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.92), in: Capsule())
                        .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: LunaMetrics.cardRadius, style: .continuous))
            }
            .buttonStyle(LunaPressStyle())
            .accessibilityLabel("\(artifact.kind == .photo ? "Photo" : "Video"), \(artifact.capturedAt.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityIdentifier("home.bento.photo")
        } else {
            Button { openGlassesFeature { showCapture(.photo) } } label: {
                VStack(alignment: .leading, spacing: 10) {
                    LunaPuck(systemImage: "camera", size: 52, fill: LunaColor.lime, tint: LunaColor.onLime)
                    Spacer(minLength: 0)
                    Text("Your first photo")
                        .font(.lunaHeading)
                    Text("Take one with your glasses. It stays on this iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(LunaColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(LunaColor.text)
                .multilineTextAlignment(.leading)
                .padding(LunaMetrics.cardPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .lunaCard()
            }
            .buttonStyle(LunaPressStyle())
            .accessibilityIdentifier("home.bento.photo")
        }
    }

    /// Reminders still due today (including overdue ones).
    private var countCard: some View {
        let count = dueToday.count
        return Button { openTab(.tasks) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)")
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                Text(count == 1 ? "thing today" : "things today")
                    .font(.subheadline)
                    .foregroundStyle(LunaColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(LunaColor.text)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .lunaCard(radius: 26)
        }
        .buttonStyle(LunaPressStyle())
        .accessibilityLabel(count == 1 ? "1 thing today" : "\(count) things today")
        .accessibilityHint("Opens Tasks")
        .accessibilityIdentifier("home.bento.count")
    }

    /// The next reminder, on the near-black card.
    @ViewBuilder
    private var nextCard: some View {
        if let next = nextReminder {
            Button { openItem(.reminder(next.id)) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(next.dueAt < .now ? "Due now" : "Next")
                        .font(.lunaBadge)
                        .foregroundStyle(LunaColor.onLime)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(LunaColor.lime, in: Capsule())
                    Spacer(minLength: 2)
                    Text(next.title)
                        .font(.lunaLabel)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(next.dueAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(LunaColor.onEmphasisSecondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .lunaEmphasisCard(radius: 26)
            }
            .buttonStyle(LunaPressStyle())
            .accessibilityIdentifier("home.bento.next")
        } else {
            Button(action: showReminder) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing next")
                        .font(.lunaLabel)
                    Spacer(minLength: 0)
                    Text("Remind me")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LunaColor.onLime)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(LunaColor.lime, in: Capsule())
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .lunaEmphasisCard(radius: 26)
            }
            .buttonStyle(LunaPressStyle())
            .accessibilityIdentifier("home.bento.next")
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                 count: dynamicTypeSize.isAccessibilitySize ? 3 : 5), spacing: 14) {
            LunaQuickActionButton(title: "Look", systemImage: "eye", identifier: "home.action.look", action: look)
            LunaQuickActionButton(title: "Photo", systemImage: "camera", identifier: "home.action.capture") {
                openGlassesFeature { showCapture(.photo) }
            }
            LunaQuickActionButton(title: "Video", systemImage: "video", identifier: "home.action.video") {
                openGlassesFeature { showCapture(.video) }
            }
            LunaQuickActionButton(title: "Note", systemImage: "square.and.pencil", identifier: "home.action.note",
                                  action: showRemember)
            LunaQuickActionButton(title: "Remind", systemImage: "bell", identifier: "home.action.remind",
                                  action: showReminder)
        }
    }

    // MARK: Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LunaSectionHeader(title: "Earlier today")
            ForEach(todayEntries) { entry in
                Button { openItem(entry.ref) } label: {
                    HStack(spacing: 14) {
                        LunaPuck(systemImage: entry.systemImage, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.lunaLabel)
                                .foregroundStyle(LunaColor.text)
                                .lineLimit(1)
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(LunaColor.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(entry.date, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LunaColor.secondaryText)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 64)
                    .lunaRow()
                }
                .buttonStyle(LunaPressStyle())
                .accessibilityIdentifier("home.today.row")
            }
        }
    }

    // MARK: Data

    /// Today's calls and the latest note. Photos and reminders have their own cards.
    private var todayEntries: [LunaTodayEntry] {
        let calendar = Calendar.current
        var entries: [LunaTodayEntry] = model.callRecords
            .filter { calendar.isDateInToday($0.startedAt) }
            .prefix(3)
            .map { LunaTodayEntry(ref: .call($0.id), title: $0.title, detail: "Call with Luna",
                                  date: $0.startedAt, systemImage: "waveform") }
        if let note = model.memories.max(by: { $0.capturedAt < $1.capturedAt }), calendar.isDateInToday(note.capturedAt) {
            entries.append(LunaTodayEntry(ref: .note(note.id), title: note.summary, detail: "Note",
                                          date: note.capturedAt, systemImage: "note.text"))
        }
        return entries.sorted { $0.date > $1.date }
    }

    private var latestCapture: CaptureArtifact? {
        model.artifacts.max(by: { $0.capturedAt < $1.capturedAt })
    }

    private var dueToday: [ReminderRecord] {
        let endOfDay = Calendar.current.startOfDay(for: .now).addingTimeInterval(24 * 60 * 60)
        return model.reminders.filter { !$0.isCompleted && $0.dueAt < endOfDay }
    }

    private var nextReminder: ReminderRecord? {
        model.reminders.filter { !$0.isCompleted }.min(by: { $0.dueAt < $1.dueAt })
    }

    private var glassesReady: Bool {
        model.settings.usesMockGlasses
            || model.glassesState == .connected
            || model.glassesState == .observing
            || model.glassesState == .paused
            || model.glassesState == .ready
    }

    private var needsServerSetup: Bool {
        !model.settings.usesMockHermes && !model.settings.hasServerConfiguration
    }

    private var isServerOffline: Bool {
        guard !model.settings.usesMockHermes else { return false }
        if case .offline = model.connectionState { return true }
        return false
    }

    private func openGlassesFeature(_ action: @escaping @MainActor () -> Void) {
        if glassesReady {
            action()
            return
        }
        Task { @MainActor in
            await model.connectGlasses()
            if glassesReady { action() }
        }
    }
}

private struct LunaTodayEntry: Identifiable {
    let ref: LibraryItemRef
    let title: String
    let detail: String
    let date: Date
    let systemImage: String
    var id: LibraryItemRef { ref }
}
