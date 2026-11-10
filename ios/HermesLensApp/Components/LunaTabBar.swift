import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home, library, tasks, you

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .tasks: "Tasks"
        case .you: "You"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .tasks: "checkmark.circle"
        case .you: "person"
        }
    }
}

/// The floating pill tab bar: Home · Library · [Talk] · Tasks · You. Talk is an
/// action, not a destination: it starts the call, or returns to the running one.
/// The centre Luna shows the live call's mood, so a call is never out of sight.
struct LunaTabBar: View {
    @Binding var selection: AppTab
    let mood: LunaMood
    let isOnCall: Bool
    var level: Double = 0
    let talk: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            item(.home)
            item(.library)
            talkButton
            item(.tasks)
            item(.you)
        }
        .padding(6)
        .background(LunaColor.surface, in: Capsule())
        .overlay { Capsule().stroke(LunaColor.separator.opacity(colorScheme == .dark ? 1 : 0.6), lineWidth: 1) }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.10), radius: 28, y: 8)
        .padding(.horizontal, 16)
    }

    private func item(_ tab: AppTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? "\(tab.systemImage).fill" : tab.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.caption2.weight(selected ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? LunaColor.text : LunaColor.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(selected ? LunaColor.raised : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(tab.title.lowercased())")
    }

    private var talkButton: some View {
        Button(action: talk) {
            ZStack {
                Circle().fill(LunaColor.lime)
                if isOnCall {
                    Circle().stroke(LunaColor.onLime.opacity(0.85), lineWidth: 2.5).padding(3)
                }
                LunaCharacter(mood: isOnCall ? mood : .ready, level: level, size: 48, animated: isOnCall)
                    .offset(y: 1)
            }
            .frame(width: 64, height: 64)
            .shadow(color: LunaColor.lime.opacity(colorScheme == .dark ? 0.25 : 0.45), radius: 12, y: 4)
            .frame(maxWidth: .infinity)
            .offset(y: -8)
            .contentShape(Circle())
        }
        .buttonStyle(LunaPressStyle())
        .accessibilityLabel(isOnCall ? "Return to your call. Luna: \(mood.line)" : "Talk to Luna")
        .accessibilityIdentifier("tab.talk")
    }
}

extension LunaMood {
    /// Luna's mood from what is really happening, never decoration: a failed or
    /// offline state replaces Ready immediately.
    @MainActor
    init(call: (any LunaCall)?, isReconnecting: Bool, isOffline: Bool) {
        guard let call else { self = isOffline ? .offline : .ready; return }
        if isReconnecting { self = .connecting; return }
        switch call.state.phase {
        case .failed: self = .didntWork; return
        case .ended: self = .ready; return
        default: break
        }
        if call.approval != nil || call.contactDraft != nil { self = .needsOK; return }
        if call.tools.contains(where: { $0.name == "look" || $0.name == "record_video" }) { self = .looking; return }
        switch call.state.phase {
        case .idle, .connecting: self = .connecting
        case .listening: self = call.tools.isEmpty ? .listening : .thinking
        case .responding: self = .thinking
        case .speaking: self = .speaking
        case .failed: self = .didntWork
        case .ended: self = .ready
        }
    }
}
