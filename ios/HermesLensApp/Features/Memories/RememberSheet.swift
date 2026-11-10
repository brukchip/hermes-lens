import HermesLensCore
import SwiftUI

/// Saves a note to the local Library. Notes stay on this iPhone.
struct RememberSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var note: String

    init(prefill: String = "") {
        _note = State(initialValue: prefill)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Save one useful thought to your private Library.", systemImage: "note.text.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField(
                        "What should Luna remember?",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .accessibilityIdentifier("memory-note-field")
                } header: {
                    Text("Your note")
                } footer: {
                    Text("Notes are kept on this iPhone.")
                }
            }
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .lunaFormChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("remember.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.remember(note: note) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("remember.save")
                }
            }
        }
    }
}
