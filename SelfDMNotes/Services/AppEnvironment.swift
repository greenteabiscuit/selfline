import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let database: AppDatabase?
    let attachmentStore: AttachmentStore?
    let linkPreviewCoordinator: LinkPreviewCoordinator?
    let archiveService: ArchiveService?
    let supportService: SupportService?
    let launchStatus: AppLaunchStatus
    let startupRecoveryMessage: String?

    init(
        directoryProvider: ApplicationSupportDirectoryProvider? = nil,
        fileManager: FileManager = .default,
        diagnostics: RedactedDiagnosticLog = .shared
    ) {
        do {
            let provider = try directoryProvider
                ?? ApplicationSupportDirectoryProvider.runtime(fileManager: fileManager)
            let recoveryCoordinator = RestoreRecoveryCoordinator(
                provider: provider,
                fileManager: fileManager
            )
            let startupMode = try recoveryCoordinator.resolveBeforeOpeningLibrary()
            try provider.prepare(fileManager: fileManager)

            let database: AppDatabase
            do {
                database = try AppDatabase(databaseURL: provider.databaseURL)
                try database.verifyConnection()
                try database.verifyFTS5Availability()
            } catch {
                if startupMode == .trial {
                    try? recoveryCoordinator.requestRollback(
                        "The restored database failed pre-open health checks. Quit and reopen Self DM Notes to recover the original library. Details: \(error.localizedDescription)"
                    )
                }
                throw error
            }

            self.database = database
            attachmentStore = AttachmentStore(
                provider: provider,
                database: database,
                fileManager: fileManager
            )
            linkPreviewCoordinator = LinkPreviewCoordinator(
                provider: provider,
                database: database
            )
            let archiveService = ArchiveService(
                provider: provider,
                database: database,
                recoveryCoordinator: recoveryCoordinator,
                fileManager: fileManager
            )
            self.archiveService = archiveService
            supportService = SupportService(
                provider: provider,
                database: database,
                archiveService: archiveService,
                diagnostics: diagnostics
            )
            launchStatus = .ready
            diagnostics.record(.applicationStartup, outcome: .succeeded)
            if case let .recoveredOriginal(message) = startupMode {
                startupRecoveryMessage = message
            } else {
                startupRecoveryMessage = nil
            }
        } catch {
            database = nil
            attachmentStore = nil
            linkPreviewCoordinator = nil
            archiveService = nil
            supportService = nil
            startupRecoveryMessage = nil
            diagnostics.record(.applicationStartup, outcome: .failed)
            launchStatus = .unavailable(
                "The local archive could not be opened. Quit and reopen Self DM Notes. "
                    + "If a restore was in progress, reopening performs any requested rollback before SQLite opens. "
                    + "If the problem continues, preserve the Application Support folder before troubleshooting. "
                    + "Details: \(error.localizedDescription)"
            )
        }
    }
}
