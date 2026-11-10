import HermesLensCore
import SwiftUI

/// Tasks: what is waiting for the user's OK, their reminders, and the actions they
/// approved or declined in calls. Every status here is real: handed-off work shows
/// the user's own choice; Hermes reports results on its own channels.
struct LunaTasksView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case waiting = "Waiting for you"
        case reminders = "Reminders"
        case handedOff = "Handed off"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    let calls: LunaCallController
    let showReminder: () -> Void
    let talk: () -> Void

    @State private var segment: Segment = .reminders

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tasks")
                        .font(.lunaDisplay)
                        .accessibilityAddTraits(.isHeader)
                    Text("A few things, moving forward.")
                        .font(.subheadline)
                        .foregroundStyle(LunaColor.secondaryText)
                }
                LunaFilterChips(items: Segment.allCases, selection: $segment, title: \.rawValue,
                                identifier: "tasks.segment")
                switch segment {
                case .waiting: waiting
                case .reminders: reminders
                case .handedOff: handedOff
                }
            }
            .padding(.horizontal, LunaMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(LunaBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if pendingInCall { segment = .waiting }
        }
    }

    // MARK: Waiting for you

    private var pendingInCall: Bool {
        calls.call?.approval != nil || calls.call?.contactDraft != nil
    }

    @ViewBuilder
    private var waiting: some View {
        if let call = calls.call, let approval = call.approval {
            pendingCard(label: "NEEDS YOUR OK", title: approval.summary, approval: approval,
                        detail: "Luna is waiting in your call. Nothing happens unless you approve.")
        } else if let draft = calls.call?.contactDraft {
            pendingCard(label: "NEW CONTACT", title: draft.title,
                        detail: "Luna read a contact in your call. Check it before saving.")
        } else {
            LunaEmptyState(title: "Nothing needs your OK.",
                           message: "When Luna wants to send, spend or act for you, it waits here and in your call.")
        }
    }

    private func pendingCard(label: String, title: String, approval: LunaNativeToolResult.Approval? = nil,
                             detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.lunaBadge)
                .tracking(0.8)
                .foregroundStyle(LunaColor.onLime)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(LunaColor.lime, in: Capsule())
            Text(title)
                .font(.system(.title3, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let approval { ApprovalDetail(approval: approval) }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(LunaColor.onEmphasisSecondary)
            Button("Open the call", action: talk)
                .buttonStyle(LunaLimeCapsuleStyle())
                .accessibilityIdentifier("tasks.openCall")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LunaMetrics.cardPadding)
        .lunaEmphasisCard(radius: 28)
    }

    // MARK: Reminders

    @ViewBuilder
    private var reminders: some View {
        let upcoming = model.reminders.filter { !$0.isCompleted }.sorted { $0.dueAt < $1.dueAt }
        let done = model.reminders.filter(\.isCompleted)
            .sorted { ($0.completedAt ?? $0.dueAt) > ($1.completedAt ?? $1.dueAt) }
            .prefix(10)
        LunaPrimaryButton(title: "New reminder", systemImage: "plus", style: .dark,
                          identifier: "tasks.newReminder", action: showReminder)
        if upcoming.isEmpty {
            LunaEmptyState(title: "A little room in your day.", message: "Add a reminder and it shows up here.")
        } else {
            VStack(spacing: 10) {
                ForEach(upcoming) { reminderRow($0) }
            }
        }
        if !done.isEmpty {
            LunaSectionHeader(title: "Done")
                .padding(.top, 6)
            VStack(spacing: 10) {
                ForEach(Array(done)) { reminderRow($0) }
            }
        }
    }

    private func reminderRow(_ reminder: ReminderRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.toggleReminder(reminder) }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(reminder.isCompleted ? LunaColor.accent : LunaColor.secondaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isCompleted ? "Mark not done" : "Mark done")
            .accessibilityIdentifier("tasks.reminder.toggle")

            NavigationLink(value: LibraryItemRef.reminder(reminder.id)) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reminder.title)
                            .font(.lunaLabel)
                            .strikethrough(reminder.isCompleted)
                            .foregroundStyle(reminder.isCompleted ? LunaColor.secondaryText : LunaColor.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(dueText(reminder))
                            .font(.caption)
                            .foregroundStyle(!reminder.isCompleted && reminder.dueAt < .now ? LunaColor.warning : LunaColor.secondaryText)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.bold())
                        .foregroundStyle(LunaColor.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tasks.reminder")
        }
        .padding(.leading, 6).padding(.trailing, 16).padding(.vertical, 8)
        .frame(minHeight: 64)
        .lunaRow()
    }

    private func dueText(_ reminder: ReminderRecord) -> String {
        let time = reminder.dueAt.formatted(date: Calendar.current.isDateInToday(reminder.dueAt) ? .omitted : .abbreviated,
                                            time: .shortened)
        if reminder.isCompleted { return "Done" }
        return reminder.dueAt < .now ? "Due · \(time)" : time
    }

    // MARK: Handed off

    @ViewBuilder
    private var handedOff: some View {
        let entries = model.callRecords.flatMap { call in
            call.actions.enumerated().map { HandoffEntry(call: call, index: $0.offset, action: $0.element) }
        }
        if entries.isEmpty {
            LunaEmptyState(title: "Nothing handed off yet.", message: "Ask Luna when you need a hand.",
                           actionTitle: "Talk to Luna", actionIdentifier: "tasks.talk", action: talk)
        } else {
            VStack(spacing: 10) {
                ForEach(entries) { entry in
                    NavigationLink(value: LibraryItemRef.call(entry.call.id)) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.action.summary)
                                    .font(.lunaLabel)
                                    .foregroundStyle(LunaColor.text)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                Text(entry.call.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(LunaColor.secondaryText)
                            }
                            Spacer(minLength: 4)
                            statusPill(approved: entry.action.approved)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lunaRow()
                    }
                    .buttonStyle(LunaPressStyle())
                    .accessibilityIdentifier("tasks.handoff")
                }
            }
            Label("Approved work runs in your Hermes agent, which reports back on your Hermes home channel.", systemImage: "paperplane")
                .font(.footnote)
                .foregroundStyle(LunaColor.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private func statusPill(approved: Bool) -> some View {
        Label(approved ? "Approved" : "Declined", systemImage: approved ? "checkmark" : "xmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(approved ? LunaColor.onLime : LunaColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(approved ? LunaColor.lime : LunaColor.raised, in: Capsule())
    }
}

private struct HandoffEntry: Identifiable {
    let call: CallRecord
    let index: Int
    let action: LunaCallAction
    var id: String { "\(call.id)-\(index)" }
}
