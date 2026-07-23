import SwiftUI

@main
struct SelfDMNotesApp: App {
    @StateObject private var environment: AppEnvironment

    init() {
        _environment = StateObject(wrappedValue: AppEnvironment())
    }

    var body: some Scene {
        Window("Self DM Notes", id: "main") {
            ContentView(
                launchStatus: environment.launchStatus,
                database: environment.database,
                attachmentStore: environment.attachmentStore,
                linkPreviewCoordinator: environment.linkPreviewCoordinator,
                archiveService: environment.archiveService,
                supportService: environment.supportService,
                startupRecoveryMessage: environment.startupRecoveryMessage
            )
        }
        .defaultSize(width: 1_200, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Self DM Notes…") {
                    NotificationCenter.default.post(name: .showAboutAndSupport, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Focus Note Composer") {
                    NotificationCenter.default.post(name: .focusNoteComposer, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Find Notes") {
                    NotificationCenter.default.post(name: .focusNoteSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Attachments") {
                Button("Choose Attachment…") {
                    NotificationCenter.default.post(name: .chooseNoteAttachment, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("Archive") {
                Button("Back Up Now…") {
                    NotificationCenter.default.post(name: .createLibraryBackup, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Export JSON and Markdown…") {
                    NotificationCenter.default.post(name: .exportPortableArchive, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
                Button("About, Privacy, and Support") {
                    NotificationCenter.default.post(name: .showAboutAndSupport, object: nil)
                }
            }
        }
    }
}
