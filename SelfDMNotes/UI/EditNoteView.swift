import SwiftUI

struct EditNoteView: View {
    let note: Note
    @ObservedObject var model: TimelineViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var bodyText: String
    @State private var isSaving = false
    @State private var editorFocusGeneration = 0

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

            ComposerTextView(
                text: $bodyText,
                focusGeneration: editorFocusGeneration,
                isEditable: model.canMutateLibrary && !isSaving,
                onSend: save,
                accessibilityIdentifier: "edit-note-field",
                accessibilityLabel: "Edit note text",
                accessibilityHelp: "Command Return saves the edit. Return inserts a new line and continues a quote, list, or code block. Return again on an empty line exits that block. Tab and Shift Tab change list nesting."
            )
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .accessibilityIdentifier("save-edit-button")
                .accessibilityHint("Saves the edit without changing the note's original order.")
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 340)
        .onAppear {
            editorFocusGeneration += 1
        }
    }

    private var canSave: Bool {
        !isSaving && model.canMutateLibrary
            && (hasVisibleText || !note.attachments.isEmpty)
    }

    private var hasVisibleText: Bool {
        bodyText.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private func save() {
        guard canSave else { return }
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
