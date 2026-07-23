import AppKit
import SwiftUI

struct ReminderStatusLabel: View {
    let note: Note
    let now: Date

    var body: some View {
        if let reminderAt = note.reminderAt, note.reminderCompletedAt == nil {
            let isDue = note.isReminderDue(at: now)
            Label {
                Text(
                    isDue
                        ? "Reminder due"
                        : "Reminder \(reminderAt.formatted(date: .abbreviated, time: .shortened))"
                )
            } icon: {
                Image(systemName: isDue ? "bell.fill" : "bell")
            }
            .font(.caption.weight(isDue ? .semibold : .regular))
            .foregroundStyle(isDue ? Color.blue : Color.secondary)
            .accessibilityLabel(
                isDue
                    ? "Reminder due since \(reminderAt.formatted(date: .complete, time: .complete))"
                    : "Reminder scheduled for \(reminderAt.formatted(date: .complete, time: .complete))"
            )
        }
    }
}

struct ReminderEditorView: View {
    let note: Note
    @ObservedObject var model: TimelineViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var scheduledAt: Date
    @State private var isWorking = false
    @State private var operationFailed = false
    private let minimumDate: Date

    init(note: Note, model: TimelineViewModel) {
        self.note = note
        self.model = model
        let minimumDate = Date().addingTimeInterval(60)
        self.minimumDate = minimumDate
        _scheduledAt = State(
            initialValue: max(
                note.hasPendingReminder ? note.reminderAt ?? minimumDate : minimumDate,
                minimumDate
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.hasPendingReminder ? "Edit Reminder" : "Set Reminder")
                        .font(.title2.weight(.semibold))
                    Text(noteSummary)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
            }

            GroupBox("Quick timers") {
                HStack {
                    quickTimerButton("20 minutes", seconds: 20 * 60)
                    quickTimerButton("1 hour", seconds: 60 * 60)
                    quickTimerButton("3 hours", seconds: 3 * 60 * 60)
                    Button("Tomorrow at 9:00 AM") {
                        saveReminder(at: tomorrowMorning())
                    }
                    .disabled(isWorking || !model.canMutateLibrary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Custom time") {
                DatePicker(
                    "Remind me at",
                    selection: $scheduledAt,
                    in: minimumDate...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.field)
                .padding(.vertical, 4)
            }

            if operationFailed {
                Label(
                    "The reminder was not changed. Review the error in the main window and retry.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityIdentifier("reminder-operation-error")
            }

            HStack {
                if note.hasPendingReminder {
                    Button("Remove Reminder", systemImage: "bell.slash", role: .destructive) {
                        perform { await model.removeReminder(note) }
                    }
                    .disabled(isWorking || !model.canMutateLibrary)
                    Button("Mark as Done", systemImage: "checkmark") {
                        perform { await model.markReminderDone(note) }
                    }
                    .disabled(isWorking || !model.canMutateLibrary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .disabled(isWorking)
                Button("Save Reminder", systemImage: "bell") {
                    saveReminder(at: scheduledAt)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || !model.canMutateLibrary)
            }
        }
        .padding(22)
        .frame(minWidth: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminder-editor")
    }

    private var noteSummary: String {
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(180)) }
        let names = note.attachments.map(\.originalFilename).joined(separator: ", ")
        return names.isEmpty ? "Attachment note" : names
    }

    private func quickTimerButton(_ title: String, seconds: TimeInterval) -> some View {
        Button(title) {
            saveReminder(at: Date().addingTimeInterval(seconds))
        }
        .disabled(isWorking || !model.canMutateLibrary)
    }

    private func tomorrowMorning() -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())
            ?? Date().addingTimeInterval(24 * 60 * 60)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            ?? tomorrow
    }

    private func saveReminder(at date: Date) {
        perform { await model.setReminder(for: note, at: date) }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Bool) {
        guard !isWorking else { return }
        isWorking = true
        operationFailed = false
        Task {
            if await operation() {
                dismiss()
            } else {
                operationFailed = true
                isWorking = false
            }
        }
    }
}

struct RemindersView: View {
    @ObservedObject var model: TimelineViewModel
    let openNote: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingNote: Note?

    private var dueNotes: [Note] {
        model.reminderNotes.filter { $0.isReminderDue(at: model.reminderClock) }
    }

    private var upcomingNotes: [Note] {
        model.reminderNotes.filter { !$0.isReminderDue(at: model.reminderClock) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reminders")
                        .font(.title2.weight(.semibold))
                    Text("Due reminders stay highlighted until you mark them done.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close Reminders", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            if model.isLoadingReminders && model.reminderNotes.isEmpty {
                ProgressView("Loading reminders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.reminderNotes.isEmpty {
                ContentUnavailableView(
                    "No reminders",
                    systemImage: "bell",
                    description: Text("Use a note's action menu to set a timer.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        reminderSection("Due", notes: dueNotes)
                        reminderSection("Upcoming", notes: upcomingNotes)
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .task { await model.reloadReminders() }
        .sheet(item: $editingNote) { note in
            ReminderEditorView(note: note, model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders-view")
    }

    @ViewBuilder
    private func reminderSection(_ title: String, notes: [Note]) -> some View {
        if !notes.isEmpty {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ForEach(notes) { note in
                ReminderListRow(
                    note: note,
                    now: model.reminderClock,
                    canMutate: model.canMutateLibrary,
                    open: {
                        openNote(note)
                        dismiss()
                    },
                    editReminder: { editingNote = note },
                    markDone: { Task { await model.markReminderDone(note) } },
                    removeReminder: { Task { await model.removeReminder(note) } }
                )
            }
        }
    }
}

private struct ReminderListRow: View {
    let note: Note
    let now: Date
    let canMutate: Bool
    let open: () -> Void
    let editReminder: () -> Void
    let markDone: () -> Void
    let removeReminder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ReminderStatusLabel(note: note, now: now)
                if note.isReply {
                    Text("Thread reply")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Reminder actions", systemImage: "ellipsis") {
                    if note.hasPendingReminder {
                        Button("Edit Reminder…", systemImage: "clock", action: editReminder)
                            .disabled(!canMutate)
                        Button("Mark Reminder as Done", systemImage: "checkmark", action: markDone)
                            .disabled(!canMutate)
                        Button("Remove Reminder", systemImage: "bell.slash", action: removeReminder)
                            .disabled(!canMutate)
                    } else {
                        Button("Set Reminder…", systemImage: "bell", action: editReminder)
                            .disabled(!canMutate)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(noteSummary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Posted \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Note", systemImage: "arrow.right.circle", action: open)
                Button("Mark as Done", systemImage: "checkmark", action: markDone)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMutate)
            }
        }
        .padding(12)
        .background(
            note.isReminderDue(at: now) ? Color.blue.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(note.isReminderDue(at: now) ? Color.blue.opacity(0.45) : Color.clear)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminder-row")
    }

    private var noteSummary: String {
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(400)) }
        let names = note.attachments.map(\.originalFilename).joined(separator: ", ")
        return names.isEmpty ? "Attachment note" : names
    }
}
