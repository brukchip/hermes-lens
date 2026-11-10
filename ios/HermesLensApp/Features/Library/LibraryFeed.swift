import AVKit
import HermesLensCore
import SwiftUI
import UIKit

/// A stable reference to anything in the Library (navigation value).
enum LibraryItemRef: Hashable {
    case call(UUID), capture(UUID), note(UUID), reminder(UUID)
}

/// One row of the unified Library feed.
struct LibraryItem: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", calls = "Calls", photos = "Photos", videos = "Videos"
        case notes = "Notes", reminders = "Reminders"
        var id: String { rawValue }
    }

    let ref: LibraryItemRef
    let kind: Kind
    let title: String
    let detail: String
    let date: Date
    let systemImage: String
    let tint: Color
    var id: LibraryItemRef { ref }
}

extension AppModel {
    /// Everything in the Library, newest first: calls, captures, notes, reminders.
    var libraryItems: [LibraryItem] {
        var items: [LibraryItem] = callRecords.map { call in
            LibraryItem(ref: .call(call.id), kind: .calls, title: call.title, detail: call.summary,
                        date: call.startedAt, systemImage: "waveform", tint: LunaColor.accent)
        }
        items += artifacts.map { artifact in
            LibraryItem(ref: .capture(artifact.id), kind: artifact.kind == .photo ? .photos : .videos,
                        title: artifact.kind == .photo ? "Photo" : "Video",
                        detail: artifact.request.hasSuffix("from a Luna call") ? "From a call with Luna" : "From your glasses",
                        date: artifact.capturedAt, systemImage: artifact.kind == .photo ? "photo" : "video",
                        tint: LunaColor.accent)
        }
        items += memories.map { memory in
            LibraryItem(ref: .note(memory.id), kind: .notes, title: memory.summary,
                        detail: "Note", date: memory.capturedAt,
                        systemImage: "note.text", tint: LunaColor.accent)
        }
        items += reminders.map { reminder in
            LibraryItem(ref: .reminder(reminder.id), kind: .reminders, title: reminder.title,
                        detail: reminder.isCompleted ? "Done" : reminder.dueAt.formatted(date: .abbreviated, time: .shortened),
                        date: reminder.isCompleted ? (reminder.completedAt ?? reminder.dueAt) : reminder.dueAt,
                        systemImage: reminder.isCompleted ? "checkmark.circle.fill" : "bell",
                        tint: reminder.isCompleted ? LunaColor.success : LunaColor.warning)
        }
        return items.sorted { $0.date > $1.date }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askLuna) private var askLuna
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let showReminder: () -> Void
    let showNote: () -> Void
    /// Opens an item (the Library's navigation path lives in the shell).
    let open: (LibraryItemRef) -> Void

    @State private var filter: LibraryItem.Kind = .all
    @State private var query = ""
    /// Deleted items stay hidden for a few seconds so Undo can bring them back.
    @State private var pendingDeletion: LibraryItemRef?
    @State private var undoMessage: String?
    @State private var undoAction: (() -> Void)?
    @State private var commitTask: Task<Void, Never>?

    /// Reminders live in Tasks; the Library keeps what was captured, said and sent.
    static let filters: [LibraryItem.Kind] = [.all, .photos, .videos, .calls, .notes]

    var body: some View {
        ZStack(alignment: .bottom) {
            LunaBackground()
            List {
                Section {
                    LunaFilterChips(items: Self.filters, selection: $filter,
                                    title: \.rawValue, identifier: "library.filter")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: LunaMetrics.gutter, bottom: 4, trailing: LunaMetrics.gutter))
                }
                if visibleItems.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
                            let captures = group.items.filter { $0.kind == .photos || $0.kind == .videos }
                            if !captures.isEmpty {
                                captureGrid(captures)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(rowInsets)
                            }
                            ForEach(group.items.filter { $0.kind != .photos && $0.kind != .videos }) { item in
                                row(item)
                            }
                        } header: {
                            Text(dayTitle(group.day))
                                .font(.lunaHeading)
                                .foregroundStyle(LunaColor.text)
                                .textCase(nil)
                                .padding(.top, 8)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(4)
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Search your Library")

            if let undoMessage {
                undoToast(undoMessage)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New note", systemImage: "square.and.pencil", action: showNote)
                        .accessibilityIdentifier("library.new.note")
                    Button("New reminder", systemImage: "bell", action: showReminder)
                        .accessibilityIdentifier("library.new.reminder")
                } label: {
                    LunaPuck(systemImage: "plus", size: 36, fill: LunaColor.surface)
                }
                .accessibilityLabel("New")
                .accessibilityIdentifier("library.new")
            }
        }
        .lunaPageChrome()
        .animation(.snappy, value: undoMessage)
        .onDisappear { commitPendingDeletion() }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 5, leading: LunaMetrics.gutter, bottom: 5, trailing: LunaMetrics.gutter)
    }

    private var visibleItems: [LibraryItem] {
        let words = query.lowercased().split(separator: " ")
        return model.libraryItems.filter { item in
            item.ref != pendingDeletion
                && item.kind != .reminders
                && (filter == .all || item.kind == filter)
                && words.allSatisfy { word in
                    item.title.lowercased().contains(word) || item.detail.lowercased().contains(word)
                }
        }
    }

    private var dayGroups: [(day: Date, items: [LibraryItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleItems) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).month(.wide).day()
                                      : .dateTime.month(.wide).day().year())
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            LunaEmptyState(title: "Nothing found.", message: "Try another word.", mood: .thinking)
        } else if filter == .all {
            LunaEmptyState(title: "Your story starts here.",
                           message: "Take a photo or save a thought. I'll keep it here for you.",
                           actionTitle: "Save a note", actionIdentifier: "library.empty.note", action: showNote)
        } else {
            LunaEmptyState(title: "No \(filter.rawValue.lowercased()) yet.",
                           message: "They'll appear here as soon as you have some.")
        }
    }

    /// Photos and videos of one day, image first, two across.
    private func captureGrid(_ items: [LibraryItem]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { item in
                if case .capture(let id) = item.ref, let artifact = model.artifacts.first(where: { $0.id == id }) {
                    Button { open(item.ref) } label: {
                        ZStack(alignment: .bottomLeading) {
                            Color.clear
                                .aspectRatio(0.86, contentMode: .fit)
                                .overlay { CaptureImage(artifact: artifact) }
                            Text(item.date, style: .time)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(LunaColor.onEmphasis)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(LunaColor.emphasis.opacity(0.8), in: Capsule())
                                .padding(10)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .buttonStyle(LunaPressStyle())
                    .accessibilityLabel("\(artifact.kind == .photo ? "Photo" : "Video"), \(item.title), \(item.date.formatted(date: .omitted, time: .shortened))")
                    .accessibilityIdentifier("library.row")
                    .contextMenu { menu(item) }
                }
            }
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        Button { open(item.ref) } label: {
            HStack(spacing: 14) {
                LunaPuck(systemImage: item.systemImage, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.lunaLabel)
                        .foregroundStyle(LunaColor.text)
                        .lineLimit(2)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(LunaColor.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.date, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LunaColor.secondaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 68)
            .lunaRow()
        }
        .buttonStyle(LunaPressStyle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
        .accessibilityIdentifier("library.row")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
                .accessibilityIdentifier("library.row.delete")
        }
        .contextMenu { menu(item) }
    }

    @ViewBuilder
    private func menu(_ item: LibraryItem) -> some View {
        Button("Ask Luna about this", systemImage: "waveform.and.mic") {
            askLuna("The user is asking about this item in their Library: \(item.kind.rawValue.lowercased()) — \(item.title). You were given only its kind and title, not its contents; say so if they ask what is in it.")
        }
        .accessibilityIdentifier("library.row.ask")
        Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
    }

    private func delete(_ item: LibraryItem) {
        commitPendingDeletion()
        pendingDeletion = item.ref
        showUndo("\(item.kind.singular) deleted") { pendingDeletion = nil }
        commitTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            commitPendingDeletion()
        }
    }

    private func showUndo(_ message: String, undo: @escaping () -> Void) {
        undoMessage = message
        undoAction = undo
        Task {
            try? await Task.sleep(for: .seconds(8))
            if undoMessage == message { undoMessage = nil; undoAction = nil }
        }
    }

    /// Makes a pending deletion permanent (after 8 s, or when leaving the Library).
    private func commitPendingDeletion() {
        commitTask?.cancel(); commitTask = nil
        guard let ref = pendingDeletion else { return }
        pendingDeletion = nil
        Task { await model.deleteLibraryItem(ref) }
    }

    private func undoToast(_ message: String) -> some View {
        HStack(spacing: 14) {
            Text(message).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button("Undo") {
                commitTask?.cancel(); commitTask = nil
                undoAction?()
                undoMessage = nil; undoAction = nil
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(LunaColor.onLime)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .background(LunaColor.lime, in: Capsule())
            .accessibilityIdentifier("library.undo")
        }
        .padding(.leading, 20).padding(.trailing, 6)
        .frame(minHeight: 48)
        .lunaEmphasisCard(radius: 24)
        .padding(.horizontal, LunaMetrics.gutter)
    }
}

extension LibraryItem.Kind {
    /// "Photo", "Call": for messages about one item.
    var singular: String {
        switch self {
        case .all: "Item"
        case .calls: "Call"
        case .photos: "Photo"
        case .videos: "Video"
        case .notes: "Note"
        case .reminders: "Reminder"
        }
    }
}

extension AppModel {
    func deleteLibraryItem(_ ref: LibraryItemRef) async {
        switch ref {
        case .call(let id): if let call = callRecords.first(where: { $0.id == id }) { await deleteCall(call) }
        case .capture(let id): if let artifact = artifacts.first(where: { $0.id == id }) { await deleteArtifact(artifact) }
        case .note(let id): if let memory = memories.first(where: { $0.id == id }) { await deleteMemory(memory) }
        case .reminder(let id): if let reminder = reminders.first(where: { $0.id == id }) { await deleteReminder(reminder) }
        }
    }
}

/// Opens any Library item; used by the Library and by Today rows on Home.
struct LibraryItemDetail: View {
    @Environment(AppModel.self) private var model
    let ref: LibraryItemRef

    var body: some View {
        switch ref {
        case .call(let id):
            if let call = model.callRecords.first(where: { $0.id == id }) { CallDetailView(call: call) } else { gone }
        case .capture(let id):
            if let artifact = model.artifacts.first(where: { $0.id == id }) { CaptureArtifactDetailView(artifact: artifact) } else { gone }
        case .note(let id):
            if let memory = model.memories.first(where: { $0.id == id }) { NoteDetailView(memory: memory) } else { gone }
        case .reminder(let id):
            if let reminder = model.reminders.first(where: { $0.id == id }) { ReminderDetailView(reminder: reminder) } else { gone }
        }
    }

    private var gone: some View {
        LunaEmptyState(title: "No longer here", message: "This item was deleted or has expired.",
                       systemImage: "tray")
            .padding(20)
    }
}

/// What a call left behind: the conversation, actions, and photos and clips.
struct CallDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askLuna) private var askLuna
    @Environment(\.dismiss) private var dismiss
    let call: CallRecord
    @State private var confirmsDelete = false

    var body: some View {
        ZStack {
            LunaBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(call.title)
                            .font(.lunaTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(call.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(call.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
                            .font(.subheadline)
                            .foregroundStyle(LunaColor.secondaryText)
                    }
                    if !captures.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(captures) { artifact in
                                    NavigationLink(value: LibraryItemRef.capture(artifact.id)) {
                                        CaptureThumbnail(artifact: artifact, size: 104)
                                    }
                                    .accessibilityIdentifier("call.detail.capture")
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }
                    if !call.actions.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(Array(call.actions.enumerated()), id: \.offset) { _, action in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(action.summary)
                                        .font(.lunaLabel)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Label(action.approved ? "Approved" : "Declined",
                                          systemImage: action.approved ? "checkmark" : "xmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(action.approved ? LunaColor.onLime : LunaColor.secondaryText)
                                        .padding(.horizontal, 10)
                                        .frame(minHeight: 28)
                                        .background(action.approved ? LunaColor.lime : LunaColor.raised, in: Capsule())
                                }
                                .padding(16)
                                .lunaRow()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(call.turns.enumerated()), id: \.offset) { _, turn in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(turn.speaker == .you ? "YOU" : "LUNA")
                                    .font(.lunaBadge)
                                    .tracking(0.8)
                                    .foregroundStyle(LunaColor.secondaryText)
                                Text(turn.text)
                                    .font(turn.speaker == .you ? .body : .system(.body, weight: .semibold))
                                    .foregroundStyle(turn.speaker == .you ? LunaColor.secondaryText : LunaColor.text)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(LunaMetrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lunaCard(radius: 26)
                    LunaPrimaryButton(title: "Continue with Luna", systemImage: "mic.fill",
                                      identifier: "call.detail.continue") {
                        askLuna("Continue our earlier conversation about: \(call.title). Last thing you said: \(call.summary)")
                    }
                }
                .padding(.horizontal, LunaMetrics.gutter)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Call")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                .accessibilityIdentifier("call.detail.delete")
        }
        .confirmationDialog("Delete this call?", isPresented: $confirmsDelete) {
            Button("Delete call", role: .destructive) {
                Task { await model.deleteCall(call); dismiss() }
            }
        } message: {
            Text("Photos and videos taken during the call stay in your Library.")
        }
        .lunaPageChrome()
    }

    private var captures: [CaptureArtifact] {
        call.captureIDs.compactMap { id in model.artifacts.first { $0.id == id } }
    }
}

/// A note: read, edit, delete.
struct NoteDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let memory: MemoryRecord
    @State private var text = ""
    @State private var isEditing = false
    @State private var confirmsDelete = false

    var body: some View {
        Form {
            Section {
                if isEditing {
                    TextField("Note", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                        .accessibilityIdentifier("note.detail.text")
                } else {
                    Text(memory.note.isEmpty ? memory.summary : memory.note)
                        .textSelection(.enabled)
                }
            } footer: {
                Text(memory.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Button("Delete note", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("note.detail.delete")
            }
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(isEditing ? "Save" : "Edit") {
                if isEditing {
                    Task { await model.updateMemory(memory, note: text) }
                } else {
                    text = memory.note.isEmpty ? memory.summary : memory.note
                }
                isEditing.toggle()
            }
            .disabled(isEditing && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("note.detail.edit")
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmsDelete) {
            Button("Delete note", role: .destructive) {
                Task { await model.deleteMemory(memory); dismiss() }
            }
        }
        .lunaFormChrome()
    }
}

/// A reminder: complete, edit, delete.
struct ReminderDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderRecord
    @State private var title = ""
    @State private var note = ""
    @State private var dueAt = Date.now
    @State private var isEditing = false
    @State private var confirmsDelete = false

    var body: some View {
        Form {
            Section {
                if isEditing {
                    TextField("Title", text: $title).accessibilityIdentifier("reminder.detail.title")
                    TextField("Details", text: $note, axis: .vertical).accessibilityIdentifier("reminder.detail.note")
                    DatePicker("Due", selection: $dueAt).accessibilityIdentifier("reminder.detail.due")
                } else {
                    Text(reminder.title).font(.headline)
                    if !reminder.note.isEmpty { Text(reminder.note) }
                    LabeledContent("Due", value: reminder.dueAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                Button(reminder.isCompleted ? "Mark not done" : "Mark done",
                       systemImage: reminder.isCompleted ? "arrow.uturn.backward" : "checkmark.circle") {
                    Task { await model.toggleReminder(reminder) }
                }
                .accessibilityIdentifier("reminder.detail.complete")
                Button("Delete reminder", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("reminder.detail.delete")
            }
        }
        .navigationTitle("Reminder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(isEditing ? "Save" : "Edit") {
                if isEditing {
                    Task { await model.updateReminder(reminder, title: title, note: note, dueAt: dueAt) }
                } else {
                    title = reminder.title; note = reminder.note; dueAt = reminder.dueAt
                }
                isEditing.toggle()
            }
            .disabled(isEditing && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("reminder.detail.edit")
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmsDelete) {
            Button("Delete reminder", role: .destructive) {
                Task { await model.deleteReminder(reminder); dismiss() }
            }
        }
        .lunaFormChrome()
    }
}

/// A square preview of a photo or the first frame of a video.
struct CaptureThumbnail: View {
    let artifact: CaptureArtifact
    var size: CGFloat = 48

    var body: some View {
        CaptureImage(artifact: artifact)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: min(16, size * 0.28), style: .continuous))
    }
}

/// A photo, or the first frame of a video, filling whatever frame it is given.
struct CaptureImage: View {
    @Environment(AppModel.self) private var model
    let artifact: CaptureArtifact
    @State private var image: UIImage?

    var body: some View {
        LunaColor.raised
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: artifact.kind == .photo ? "photo" : "video")
                        .foregroundStyle(LunaColor.secondaryText)
                }
            }
            .clipped()
            .overlay {
                if artifact.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(LunaColor.onLime)
                        .padding(7)
                        .background(LunaColor.lime, in: Circle())
                }
            }
            .task(id: artifact.localFilename) { await load() }
        .accessibilityLabel(artifact.kind == .photo ? "Photo" : "Video")
    }

    private func load() async {
        if artifact.kind == .photo {
            if let data = await model.captureData(for: artifact) { image = UIImage(data: data) }
            return
        }
        guard let url = await model.captureURL(for: artifact) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        if let result = try? await generator.image(at: .zero) { image = UIImage(cgImage: result.image) }
    }
}
