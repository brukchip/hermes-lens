import HermesLensCore
import SwiftUI

struct AddReminderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var note = ""
    @State private var dueAt = Date.now.addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Luna will notify you at the selected time.", systemImage: "bell.badge")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Reminder") {
                    TextField("What should I remind you about?", text: $title)
                        .accessibilityIdentifier("reminder.add.title")
                    TextField("Optional context", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("reminder.add.note")
                }
                Section("When") {
                    DatePicker("Due", selection: $dueAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("reminder.add.due")
                }
            }
            .navigationTitle("New reminder")
            .navigationBarTitleDisplayMode(.inline)
            .lunaFormChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("reminder.add.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            if await model.addReminder(title: title, note: note, dueAt: dueAt) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("reminder.add.save")
                }
            }
        }
    }
}
