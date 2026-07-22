import SwiftUI

struct EditNoteView: View {
    let note: Note
    @ObservedObject var model: TimelineViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var bodyText: String
    @State private var isSaving = false
    @FocusState private var editorFocused: Bool

    init(note: Note, model: TimelineViewModel) {
        self.note = note
        self.model = model
        _bodyText = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Note")
                .font(.title2.weight(.semibold))
            Text("Created \(note.createdAt.formatted(date: .complete, time: .complete))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage = model.errorMessage {
                StatusBanner(
                    title: "Edit not saved",
                    message: errorMessage,
                    isError: true,
                    identifier: "edit-error",
                    dismiss: model.dismissError
                )
            }

            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 180)
                .disabled(!model.canMutateLibrary)
                .focused($editorFocused)
                .accessibilityIdentifier("edit-note-field")
                .accessibilityLabel("Edit note text")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || !model.canMutateLibrary
                        || (!hasVisibleText && note.attachments.isEmpty)
                )
                .accessibilityIdentifier("save-edit-button")
                .accessibilityHint("Saves the edit without changing the note's original order.")
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 340)
        .onAppear {
            editorFocused = true
        }
    }

    private var hasVisibleText: Bool {
        bodyText.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private func save() {
        guard !isSaving, model.canMutateLibrary else { return }
        isSaving = true
        Task {
            let didSave = await model.editNote(note, body: bodyText)
            isSaving = false
            if didSave {
                dismiss()
            }
        }
    }
}
