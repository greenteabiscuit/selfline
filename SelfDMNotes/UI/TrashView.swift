import SwiftUI

struct TrashView: View {
    @ObservedObject var model: TimelineViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var noteToDelete: Note?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash")
                        .font(.title2.weight(.semibold))
                    Text("Deleted notes remain here until you permanently delete them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if let errorMessage = model.errorMessage {
                StatusBanner(
                    title: "Trash action not completed",
                    message: errorMessage,
                    isError: true,
                    identifier: "trash-error",
                    dismiss: model.dismissError
                )
                .padding(16)
            }

            if model.isLoadingTrash && model.trashNotes.isEmpty {
                ProgressView("Loading Trash…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.trashNotes.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Notes moved to Trash can be restored here.")
                )
                .accessibilityIdentifier("empty-trash")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if model.hasOlderTrash {
                            Button("Load older Trash items", systemImage: "arrow.up") {
                                Task { await model.loadOlderTrash() }
                            }
                            .disabled(model.isLoadingTrash)
                            .accessibilityIdentifier("load-older-trash")
                        }

                        ForEach(model.trashNotes.reversed()) { note in
                            TrashNoteRow(
                                note: note,
                                canMutateLibrary: model.canMutateLibrary,
                                restore: { Task { await model.restoreNote(note) } },
                                delete: { noteToDelete = note }
                            )
                        }
                    }
                    .padding(16)
                }
                .accessibilityIdentifier("trash-list")
                .accessibilityLabel("Deleted notes")
            }
        }
        .frame(minWidth: 580, minHeight: 440)
        .task { await model.loadTrash() }
        .confirmationDialog(
            "Permanently delete this note?",
            isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: noteToDelete
        ) { note in
            Button("Permanently Delete", role: .destructive) {
                noteToDelete = nil
                Task { await model.permanentlyDeleteNote(note) }
            }
            .disabled(!model.canMutateLibrary)
            Button("Cancel", role: .cancel) {
                noteToDelete = nil
            }
        } message: { note in
            let description = note.body.isEmpty
                ? note.attachments.map(\.originalFilename).joined(separator: ", ")
                : String(note.body.prefix(80))
            Text("“\(description)” and its unreferenced managed files will be removed immediately and cannot be restored.")
        }
    }
}

private struct TrashNoteRow: View {
    let note: Note
    let canMutateLibrary: Bool
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !note.body.isEmpty {
                LinkedNoteBodyText(text: note.body, accessibilityLabel: "Deleted note text")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !note.attachments.isEmpty {
                Label(
                    note.attachments.map(\.originalFilename).joined(separator: ", "),
                    systemImage: "paperclip"
                )
                .font(.callout)
                .accessibilityLabel(
                    "Deleted note attachments: \(note.attachments.map(\.originalFilename).joined(separator: ", "))"
                )
            }
            if let deletedAt = note.deletedAt {
                Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Deleted \(deletedAt.formatted(date: .complete, time: .complete))"
                    )
            }
            HStack {
                Spacer()
                Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                    .accessibilityHint("Returns this note to its original timeline position.")
                    .disabled(!canMutateLibrary)
                Button("Delete Permanently", systemImage: "trash", role: .destructive, action: delete)
                    .accessibilityHint("Requires confirmation before deleting this note forever.")
                    .disabled(!canMutateLibrary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}
