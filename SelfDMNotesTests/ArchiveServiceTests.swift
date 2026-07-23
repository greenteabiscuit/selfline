import Foundation
import XCTest
@testable import SelfDMNotes

final class ArchiveServiceTests: XCTestCase {
    func testRestoreAdmissionRequiresEveryMutationSourceToBeQuiescent() {
        XCTAssertTrue(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: true,
            isArchiveOperationRunning: false,
            isSending: false,
            isDiscardingDraft: false,
            activeLibraryMutationCount: 0,
            attachmentWorkIsEmpty: true
        ))
        XCTAssertFalse(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: false,
            isArchiveOperationRunning: false,
            isSending: false,
            isDiscardingDraft: false,
            activeLibraryMutationCount: 0,
            attachmentWorkIsEmpty: true
        ))
        XCTAssertFalse(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: true,
            isArchiveOperationRunning: true,
            isSending: false,
            isDiscardingDraft: false,
            activeLibraryMutationCount: 0,
            attachmentWorkIsEmpty: true
        ))
        XCTAssertFalse(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: true,
            isArchiveOperationRunning: false,
            isSending: true,
            isDiscardingDraft: false,
            activeLibraryMutationCount: 0,
            attachmentWorkIsEmpty: true
        ))
        XCTAssertFalse(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: true,
            isArchiveOperationRunning: false,
            isSending: false,
            isDiscardingDraft: true,
            activeLibraryMutationCount: 0,
            attachmentWorkIsEmpty: true
        ))
        XCTAssertFalse(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: true,
            isArchiveOperationRunning: false,
            isSending: false,
            isDiscardingDraft: false,
            activeLibraryMutationCount: 1,
            attachmentWorkIsEmpty: true
        ))
        XCTAssertFalse(TimelineViewModel.isRestoreAdmissionQuiescent(
            canMutateLibrary: true,
            isArchiveOperationRunning: false,
            isSending: false,
            isDiscardingDraft: false,
            activeLibraryMutationCount: 0,
            attachmentWorkIsEmpty: false
        ))
    }

    func testVerifiedBackupAndPortableExportPreserveRelationshipsAndMetadata() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let seeded = try fixture.seedPortableContent()

        let backup = try fixture.service.createManualBackup(
            in: fixture.backupDirectory,
            now: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let validatedBackup = try fixture.service.validateBackup(at: backup.packageURL)
        XCTAssertEqual(validatedBackup.manifest.formatIdentifier, "com.selfdmnotes.backup")
        XCTAssertEqual(validatedBackup.manifest.formatVersion, 1)
        XCTAssertEqual(validatedBackup.manifest.databaseMigrations, DatabaseMigrations.identifiers)
        XCTAssertEqual(validatedBackup.contents.noteCount, 2)
        XCTAssertEqual(
            validatedBackup.manifest.files,
            validatedBackup.manifest.files.sorted { $0.path < $1.path }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: backup.packageURL.appendingPathComponent("library/notes.sqlite-wal").path
            )
        )

        let exportURL = try fixture.service.exportPortableArchive(
            in: fixture.exportDirectory,
            now: Date(timeIntervalSince1970: 1_700_002_000)
        )
        let portable = try fixture.service.validatePortableExport(at: exportURL)
        XCTAssertEqual(portable.formatIdentifier, "com.selfdmnotes.portable-export")
        XCTAssertEqual(portable.formatVersion, 1)
        XCTAssertEqual(portable.notes.map(\.id), [seeded.firstNoteID, seeded.secondNoteID])

        let first = try XCTUnwrap(portable.notes.first)
        XCTAssertEqual(first.updatedAtMilliseconds, seeded.editedAtMilliseconds)
        XCTAssertNil(first.deletedAtMilliseconds)
        XCTAssertEqual(first.linkPreviewRevision, 1)
        let preview = try XCTUnwrap(first.linkPreviews.first)
        XCTAssertEqual(preview.originalURL, "https://example.com/phase-five")
        XCTAssertEqual(preview.canonicalURL, "https://example.com/phase-five")
        XCTAssertEqual(preview.title, "Phase Five Preview")
        XCTAssertEqual(preview.summary, "Portable preview summary")
        XCTAssertEqual(preview.siteName, "Example")
        XCTAssertEqual(preview.status, LinkPreviewStatus.ready.rawValue)
        XCTAssertEqual(preview.reconciledRevision, first.linkPreviewRevision)

        let second = try XCTUnwrap(portable.notes.last)
        XCTAssertEqual(second.deletedAtMilliseconds, seeded.deletedAtMilliseconds)
        XCTAssertTrue(second.body.contains("🚀"))
        XCTAssertEqual(second.linkPreviews.first?.status, LinkPreviewStatus.failed.rawValue)
        XCTAssertEqual(second.linkPreviews.first?.failureReason, "Offline fixture")
        let exportedAttachments = portable.notes.flatMap(\.attachments)
        XCTAssertEqual(exportedAttachments.map(\.originalFilename), ["report.txt", "report.txt"])
        XCTAssertEqual(Set(exportedAttachments.map(\.exportedPath)).count, 2)
        XCTAssertEqual(
            Set(try exportedAttachments.map { attachment in
                try Data(contentsOf: exportURL.appendingPathComponent(attachment.exportedPath))
            }),
            Set([seeded.firstAttachmentBytes, seeded.secondAttachmentBytes])
        )

        let markdown = try String(
            contentsOf: exportURL.appendingPathComponent("notes.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("— Active"))
        XCTAssertTrue(markdown.contains("— Trash"))
        XCTAssertTrue(markdown.contains("Phase Five Preview"))
        XCTAssertTrue(markdown.contains(seeded.firstNoteID.uuidString.lowercased()))
        XCTAssertTrue(markdown.contains(seeded.secondNoteID.uuidString.lowercased()))

        let exportedOriginal = try XCTUnwrap(exportedAttachments.first)
        try Data("corrupt export bytes".utf8).write(
            to: exportURL.appendingPathComponent(exportedOriginal.exportedPath)
        )
        XCTAssertThrowsError(try fixture.service.validatePortableExport(at: exportURL)) {
            XCTAssertEqual(
                $0 as? ArchiveServiceError,
                .checksumMismatch(exportedOriginal.exportedPath)
            )
        }
    }

    func testPortableExportPreservesThreadsAndAcceptsCompleteLegacyV1Package() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Thread root")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Thread reply")

        let exportURL = try fixture.service.exportPortableArchive(in: fixture.exportDirectory)
        let portable = try fixture.service.validatePortableExport(at: exportURL)
        XCTAssertEqual(portable.formatVersion, 1)
        XCTAssertEqual(portable.notes.map(\.id), [root.id, reply.id])
        XCTAssertNil(portable.notes[0].threadRootID)
        XCTAssertEqual(portable.notes[1].threadRootID, root.id)

        let markdown = try String(
            contentsOf: exportURL.appendingPathComponent("notes.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("Thread: Root note"))
        XCTAssertTrue(markdown.contains("Thread root ID: `\(root.id.uuidString.lowercased())`"))

        let exportData = try Data(contentsOf: exportURL.appendingPathComponent("export.json"))
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exportData) as? [String: Any]
        )
        var legacyNotes = try XCTUnwrap(legacyObject["notes"] as? [[String: Any]])
        for index in legacyNotes.indices {
            legacyNotes[index].removeValue(forKey: "threadRootID")
            legacyNotes[index].removeValue(forKey: "reminderAtMilliseconds")
            legacyNotes[index].removeValue(forKey: "reminderCompletedAtMilliseconds")
        }
        legacyObject["notes"] = legacyNotes
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        let decodedLegacy = try JSONDecoder().decode(PortableArchive.self, from: legacyData)
        XCTAssertEqual(decodedLegacy.notes.map(\.id), [root.id, reply.id])
        XCTAssertTrue(decodedLegacy.notes.allSatisfy { $0.threadRootID == nil })

        try legacyData.write(to: exportURL.appendingPathComponent("export.json"))
        let legacyMarkdown = markdown
            .components(separatedBy: "\n")
            .filter {
                !$0.hasPrefix("- Thread: Root note")
                    && !$0.hasPrefix("- Thread root ID:")
            }
            .joined(separator: "\n")
        try Data(legacyMarkdown.utf8).write(
            to: exportURL.appendingPathComponent("notes.md")
        )
        try refreshPortableManifestChecksums(in: exportURL)

        let validatedLegacy = try fixture.service.validatePortableExport(at: exportURL)
        XCTAssertEqual(validatedLegacy.notes.map(\.id), [root.id, reply.id])
        XCTAssertTrue(validatedLegacy.notes.allSatisfy { $0.threadRootID == nil })
        XCTAssertTrue(validatedLegacy.notes.allSatisfy { $0.reminderAtMilliseconds == nil })
        XCTAssertTrue(validatedLegacy.notes.allSatisfy { $0.reminderCompletedAtMilliseconds == nil })
    }

    func testPortableExportPreservesPendingAndCompletedReminderMetadata() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Pending reminder")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Completed reminder")
        let rootReminder = Date(timeIntervalSince1970: 1_800_000_000)
        let replyReminder = Date(timeIntervalSince1970: 1_800_000_100)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_200)
        _ = try fixture.database.setReminder(id: root.id, at: rootReminder)
        _ = try fixture.database.setReminder(id: reply.id, at: replyReminder)
        _ = try fixture.database.markReminderDone(id: reply.id, completedAt: completedAt)

        let exportURL = try fixture.service.exportPortableArchive(in: fixture.exportDirectory)
        let portable = try fixture.service.validatePortableExport(at: exportURL)
        let exportedRoot = try XCTUnwrap(portable.notes.first { $0.id == root.id })
        let exportedReply = try XCTUnwrap(portable.notes.first { $0.id == reply.id })
        XCTAssertEqual(exportedRoot.reminderAtMilliseconds, 1_800_000_000_000)
        XCTAssertNil(exportedRoot.reminderCompletedAtMilliseconds)
        XCTAssertEqual(exportedReply.reminderAtMilliseconds, 1_800_000_100_000)
        XCTAssertEqual(exportedReply.reminderCompletedAtMilliseconds, 1_800_000_200_000)

        let markdown = try String(
            contentsOf: exportURL.appendingPathComponent("notes.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("- Reminder:"))
        XCTAssertTrue(markdown.contains("- Reminder completed:"))
    }

    func testV5BackupValidatesStagesAndMigratesOnTrialOpen() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let noteID = UUID()
        let packageURL = try makeLegacyBackupPackage(
            in: fixture.backupDirectory,
            noteID: noteID,
            schemaVersion: 5
        )

        let validated = try fixture.service.validateBackup(at: packageURL)
        XCTAssertEqual(
            validated.manifest.databaseSchemaVersion,
            ArchiveService.minimumSupportedBackupSchemaVersion
        )
        XCTAssertEqual(
            validated.manifest.databaseMigrations,
            Array(DatabaseMigrations.identifiers.prefix(5))
        )

        _ = try fixture.service.stageRestore(from: packageURL)
        try fixture.database.close()
        let trial = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try trial.resolveBeforeOpeningLibrary(), .trial)
        let migrated = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        XCTAssertEqual(try migrated.fetchNote(id: noteID).body, "Real v5 backup")
        let contents = try migrated.inspectArchiveContents(includePortableNotes: false)
        XCTAssertEqual(contents.migrations, DatabaseMigrations.identifiers)
        try trial.confirmSuccessfulStartup()
        try migrated.close()
    }

    func testV6BackupValidatesStagesAndMigratesReminderSchemaOnTrialOpen() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let noteID = UUID()
        let packageURL = try makeLegacyBackupPackage(
            in: fixture.backupDirectory,
            noteID: noteID,
            schemaVersion: 6
        )

        let validated = try fixture.service.validateBackup(at: packageURL)
        XCTAssertEqual(validated.manifest.databaseSchemaVersion, 6)
        XCTAssertEqual(
            validated.manifest.databaseMigrations,
            Array(DatabaseMigrations.identifiers.prefix(6))
        )

        _ = try fixture.service.stageRestore(from: packageURL)
        try fixture.database.close()
        let trial = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try trial.resolveBeforeOpeningLibrary(), .trial)
        let migrated = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        let restored = try migrated.fetchNote(id: noteID)
        XCTAssertEqual(restored.body, "Real v6 backup")
        XCTAssertNil(restored.reminderAt)
        XCTAssertNil(restored.reminderCompletedAt)
        XCTAssertEqual(
            try migrated.inspectArchiveContents(includePortableNotes: false).migrations,
            DatabaseMigrations.identifiers
        )
        try trial.confirmSuccessfulStartup()
        try migrated.close()
    }

    func testRestoreRejectsChecksumValidCorruptSQLiteBeforeActiveMutation() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        _ = try fixture.seedPortableContent()
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let postBackup = try fixture.database.createNote(body: "Must survive rejected restore")
        let corruptPackage = fixture.backupDirectory.appendingPathComponent(
            "corrupt.selfdmbackup",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: backup.packageURL, to: corruptPackage)
        try tamperDatabaseAndRefreshManifest(in: corruptPackage)

        XCTAssertThrowsError(try fixture.service.stageRestore(from: corruptPackage))
        XCTAssertEqual(try fixture.database.fetchNote(id: postBackup.id).body, postBackup.body)
        XCTAssertFalse(fixture.coordinator.hasPendingRestore)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.provider.rootURL.appendingPathComponent(
                    ".selfdm-restore-identity.json"
                ).path
            )
        )
    }

    func testValidationRejectsTraversalAndSymlinkWithoutTouchingOutsideFile() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        _ = try fixture.seedPortableContent()
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let sentinel = fixture.parentURL.appendingPathComponent("outside-sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)

        let traversalPackage = fixture.backupDirectory.appendingPathComponent(
            "traversal.selfdmbackup",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: backup.packageURL, to: traversalPackage)
        try rewriteFirstManifestPath(in: traversalPackage, as: "../outside-sentinel.txt")
        XCTAssertThrowsError(try fixture.service.validateBackup(at: traversalPackage)) {
            XCTAssertEqual($0 as? ArchiveServiceError, .invalidManifest)
        }

        let symlinkPackage = fixture.backupDirectory.appendingPathComponent(
            "symlink.selfdmbackup",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: backup.packageURL, to: symlinkPackage)
        let databaseURL = symlinkPackage.appendingPathComponent("library/notes.sqlite")
        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: sentinel)
        XCTAssertThrowsError(try fixture.service.validateBackup(at: symlinkPackage)) {
            guard let archiveError = $0 as? ArchiveServiceError else {
                return XCTFail("Expected a symbolic-link package entry rejection, got \($0)")
            }
            guard case .invalidPackageEntry = archiveError else {
                return XCTFail("Expected a symbolic-link package entry rejection, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
    }

    func testConfirmedTrialCommitsRestoredLibraryAndRemovesRollback() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let seeded = try fixture.seedPortableContent()
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let postBackup = try fixture.database.createNote(body: "Not present in restored snapshot")
        _ = try fixture.service.stageRestore(from: backup.packageURL)
        XCTAssertEqual(try fixture.database.fetchNote(id: postBackup.id).body, postBackup.body)
        try fixture.database.close()

        let trial = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try trial.resolveBeforeOpeningLibrary(), .trial)
        let restoredDatabase = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        XCTAssertEqual(try restoredDatabase.fetchNote(id: seeded.firstNoteID).id, seeded.firstNoteID)
        XCTAssertThrowsError(try restoredDatabase.fetchNote(id: postBackup.id))
        try trial.confirmSuccessfulStartup()
        XCTAssertFalse(trial.hasPendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trial.rollbackLibraryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trial.controlDirectoryURL.path))
        try restoredDatabase.close()
    }

    func testInterruptedTrialRecoversOriginalBeforeSQLiteReopens() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        _ = try fixture.seedPortableContent()
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let postBackup = try fixture.database.createNote(body: "Original-library recovery marker")
        _ = try fixture.service.stageRestore(from: backup.packageURL)
        try fixture.database.close()

        let interruptedTrial = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try interruptedTrial.resolveBeforeOpeningLibrary(), .trial)
        let restoredDatabase = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        XCTAssertThrowsError(try restoredDatabase.fetchNote(id: postBackup.id))
        try restoredDatabase.close()

        let recovery = RestoreRecoveryCoordinator(provider: fixture.provider)
        guard case .recoveredOriginal = try recovery.resolveBeforeOpeningLibrary() else {
            return XCTFail("An unconfirmed trial must recover the original library")
        }
        let recoveredDatabase = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        XCTAssertEqual(try recoveredDatabase.fetchNote(id: postBackup.id).body, postBackup.body)
        try recovery.confirmSuccessfulStartup()
        XCTAssertFalse(recovery.hasPendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.controlDirectoryURL.path))
        try recoveredDatabase.close()
    }

    func testInterruptedPendingCancellationResumesWithoutSwitchingLibrary() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        _ = try fixture.seedPortableContent()
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let postBackup = try fixture.database.createNote(body: "Still in active library")
        _ = try fixture.service.stageRestore(from: backup.packageURL)

        let journalURL = fixture.coordinator.controlDirectoryURL.appendingPathComponent(
            "restore-journal.json"
        )
        var journal = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        journal["state"] = "cancellationRequested"
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            .write(to: journalURL, options: .atomic)
        try FileManager.default.removeItem(
            at: fixture.provider.rootURL.appendingPathComponent(
                ".selfdm-restore-identity.json"
            )
        )

        let resumedCancellation = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(
            try resumedCancellation.resolveBeforeOpeningLibrary(),
            .cancellationCleanupPending
        )
        XCTAssertEqual(try fixture.database.fetchNote(id: postBackup.id).body, postBackup.body)
        XCTAssertTrue(resumedCancellation.hasPendingRestore)
        try resumedCancellation.confirmSuccessfulStartup()
        XCTAssertFalse(resumedCancellation.hasPendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumedCancellation.stagedLibraryURL.path))
    }

    func testInterruptedCommittedCleanupKeepsRestoredLibraryAndFinishesIdempotently() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let seeded = try fixture.seedPortableContent()
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let postBackup = try fixture.database.createNote(body: "Must not reappear after commit")
        _ = try fixture.service.stageRestore(from: backup.packageURL)
        try fixture.database.close()

        let trial = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try trial.resolveBeforeOpeningLibrary(), .trial)
        let journalURL = trial.controlDirectoryURL.appendingPathComponent("restore-journal.json")
        var journal = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        journal["state"] = "committed"
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            .write(to: journalURL, options: .atomic)
        try FileManager.default.removeItem(at: trial.rollbackLibraryURL)
        try FileManager.default.removeItem(
            at: fixture.provider.rootURL.appendingPathComponent(
                ".selfdm-restore-identity.json"
            )
        )

        let resumedCleanup = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(
            try resumedCleanup.resolveBeforeOpeningLibrary(),
            .committedCleanupPending
        )
        XCTAssertTrue(resumedCleanup.hasPendingRestore)
        let restoredDatabase = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        XCTAssertEqual(try restoredDatabase.fetchNote(id: seeded.firstNoteID).id, seeded.firstNoteID)
        XCTAssertThrowsError(try restoredDatabase.fetchNote(id: postBackup.id))
        try resumedCleanup.confirmSuccessfulStartup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumedCleanup.controlDirectoryURL.path))
        try restoredDatabase.close()
    }

    func testCommittedCleanupResumesAfterCounterpartDeletionBeforeIdentityRemoval() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let restoredNote = try fixture.database.createNote(body: "Committed restore winner")
        let backup = try fixture.service.createManualBackup(in: fixture.backupDirectory)
        let postBackup = try fixture.database.createNote(body: "Excluded after backup")
        _ = try fixture.service.stageRestore(from: backup.packageURL)
        try fixture.database.close()

        let trial = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try trial.resolveBeforeOpeningLibrary(), .trial)
        let journalURL = trial.controlDirectoryURL.appendingPathComponent("restore-journal.json")
        var journal = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        journal["state"] = "committed"
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            .write(to: journalURL, options: .atomic)
        try FileManager.default.removeItem(at: trial.rollbackLibraryURL)

        let activeIdentityURL = fixture.provider.rootURL.appendingPathComponent(
            ".selfdm-restore-identity.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeIdentityURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trial.rollbackLibraryURL.path))

        let resumedCleanup = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(
            try resumedCleanup.resolveBeforeOpeningLibrary(),
            .committedCleanupPending
        )
        let restoredDatabase = try AppDatabase(databaseURL: fixture.provider.databaseURL)
        XCTAssertEqual(try restoredDatabase.fetchNote(id: restoredNote.id).id, restoredNote.id)
        XCTAssertThrowsError(try restoredDatabase.fetchNote(id: postBackup.id))

        try resumedCleanup.confirmSuccessfulStartup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeIdentityURL.path))
        XCTAssertFalse(resumedCleanup.hasPendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumedCleanup.controlDirectoryURL.path))
        try restoredDatabase.close()
    }

    func testUnarmedStagingCleanupIsDeferredUntilExplicitConfirmation() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        let note = try fixture.database.createNote(body: "Active library remains selected")
        try fixture.coordinator.prepareForStaging()
        let quarantine = fixture.coordinator.controlDirectoryURL.appendingPathComponent(
            "quarantine-fixture",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        try Data("staged bytes".utf8).write(
            to: quarantine.appendingPathComponent("partial-file")
        )

        let recovery = RestoreRecoveryCoordinator(provider: fixture.provider)
        XCTAssertEqual(try recovery.resolveBeforeOpeningLibrary(), .unarmedCleanupPending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(try fixture.database.fetchNote(id: note.id).body, note.body)

        try recovery.confirmSuccessfulStartup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.controlDirectoryURL.path))
        XCTAssertEqual(try fixture.database.fetchNote(id: note.id).body, note.body)
    }

    func testRotationPinsNewVerifiedBackupWhenItsClockTimestampRegresses() throws {
        let fixture = try ArchiveFixture.make()
        defer { fixture.cleanUp() }
        _ = try fixture.database.createNote(body: "Retention fixture")
        var automaticPackages: [URL] = []
        for index in 0..<8 {
            let backup = try fixture.service.createManualBackup(
                in: fixture.backupDirectory,
                now: Date(timeIntervalSince1970: TimeInterval(1_700_010_000 + index))
            )
            let automaticURL = fixture.backupDirectory.appendingPathComponent(
                "Self DM Notes Automatic Backup fixture-\(index).selfdmbackup",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: backup.packageURL, to: automaticURL)
            try rewriteBackupKind(in: automaticURL, as: "automatic")
            automaticPackages.append(automaticURL)
        }
        let clockRegressedNewPackage = automaticPackages[0]

        XCTAssertNil(
            fixture.service.rotateAutomaticBackups(
                in: fixture.backupDirectory,
                preserving: clockRegressedNewPackage
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: clockRegressedNewPackage.path))
        let retained = try FileManager.default.contentsOfDirectory(
            at: fixture.backupDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("Self DM Notes Automatic Backup ")
                && $0.pathExtension == "selfdmbackup"
        }
        XCTAssertEqual(retained.count, ArchiveService.automaticBackupRetentionCount)
    }

    private func tamperDatabaseAndRefreshManifest(in packageURL: URL) throws {
        let databaseURL = packageURL.appendingPathComponent("library/notes.sqlite")
        var databaseData = try Data(contentsOf: databaseURL)
        databaseData.replaceSubrange(0..<min(databaseData.count, 32), with: Data(repeating: 0x58, count: min(databaseData.count, 32)))
        try databaseData.write(to: databaseURL)

        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            BackupPackageManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let files = manifest.files.map { record in
            record.path == "library/notes.sqlite"
                ? ArchiveFileRecord(
                    path: record.path,
                    byteSize: Int64(databaseData.count),
                    sha256: SHA256Digest.hex(databaseData),
                    role: record.role
                )
                : record
        }
        let rewritten = BackupPackageManifest(
            formatIdentifier: manifest.formatIdentifier,
            formatVersion: manifest.formatVersion,
            backupID: manifest.backupID,
            backupKind: manifest.backupKind,
            createdAtMilliseconds: manifest.createdAtMilliseconds,
            applicationVersion: manifest.applicationVersion,
            buildVersion: manifest.buildVersion,
            databaseSchemaVersion: manifest.databaseSchemaVersion,
            databaseMigrations: manifest.databaseMigrations,
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rewritten).write(to: manifestURL)
    }

    private func rewriteFirstManifestPath(in packageURL: URL, as path: String) throws {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        files[0]["path"] = path
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL)
    }

    private func rewriteBackupKind(in packageURL: URL, as backupKind: String) throws {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        object["backupKind"] = backupKind
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL)
    }

    private func refreshPortableManifestChecksums(in packageURL: URL) throws {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            PortableExportManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let files = try manifest.files.map { record in
            guard record.path == "export.json" || record.path == "notes.md" else {
                return record
            }
            let data = try Data(contentsOf: packageURL.appendingPathComponent(record.path))
            return ArchiveFileRecord(
                path: record.path,
                byteSize: Int64(data.count),
                sha256: SHA256Digest.hex(data),
                role: record.role
            )
        }
        let rewritten = PortableExportManifest(
            formatIdentifier: manifest.formatIdentifier,
            formatVersion: manifest.formatVersion,
            exportID: manifest.exportID,
            createdAtMilliseconds: manifest.createdAtMilliseconds,
            applicationVersion: manifest.applicationVersion,
            buildVersion: manifest.buildVersion,
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rewritten).write(to: manifestURL)
    }

    private func makeLegacyBackupPackage(
        in directory: URL,
        noteID: UUID,
        schemaVersion: Int
    ) throws -> URL {
        let packageURL = directory.appendingPathComponent(
            "real-v\(schemaVersion).selfdmbackup",
            isDirectory: true
        )
        let libraryURL = packageURL.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: true
        )
        let databaseURL = libraryURL.appendingPathComponent("notes.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(
            queue,
            upTo: DatabaseMigrations.identifiers[schemaVersion - 1]
        )
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO notes (id, body, createdAt) VALUES (?, ?, ?)",
                arguments: [noteID.uuidString, "Real v\(schemaVersion) backup", 1_700_000_000_000]
            )
        }
        try queue.close()

        let databaseData = try Data(contentsOf: databaseURL)
        let manifest = BackupPackageManifest(
            formatIdentifier: ArchiveService.backupFormatIdentifier,
            formatVersion: ArchiveService.backupFormatVersion,
            backupID: UUID(),
            backupKind: BackupKind.manual.rawValue,
            createdAtMilliseconds: 1_700_000_000_000,
            applicationVersion: "legacy-test",
            buildVersion: "legacy-test",
            databaseSchemaVersion: schemaVersion,
            databaseMigrations: Array(DatabaseMigrations.identifiers.prefix(schemaVersion)),
            files: [
                ArchiveFileRecord(
                    path: "library/notes.sqlite",
                    byteSize: Int64(databaseData.count),
                    sha256: SHA256Digest.hex(databaseData),
                    role: "database"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("manifest.json")
        )
        return packageURL
    }
}

private final class ArchiveFixture {
    let parentURL: URL
    let provider: ApplicationSupportDirectoryProvider
    let database: AppDatabase
    let store: AttachmentStore
    let coordinator: RestoreRecoveryCoordinator
    let service: ArchiveService
    let backupDirectory: URL
    let exportDirectory: URL
    let defaultsSuiteName: String

    private init(
        parentURL: URL,
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        store: AttachmentStore,
        coordinator: RestoreRecoveryCoordinator,
        service: ArchiveService,
        backupDirectory: URL,
        exportDirectory: URL,
        defaultsSuiteName: String
    ) {
        self.parentURL = parentURL
        self.provider = provider
        self.database = database
        self.store = store
        self.coordinator = coordinator
        self.service = service
        self.backupDirectory = backupDirectory
        self.exportDirectory = exportDirectory
        self.defaultsSuiteName = defaultsSuiteName
    }

    static func make() throws -> ArchiveFixture {
        let identifier = UUID().uuidString
        let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesArchiveTests-\(identifier)",
            isDirectory: true
        )
        let provider = ApplicationSupportDirectoryProvider(
            rootURL: parentURL.appendingPathComponent("FixtureLibrary", isDirectory: true)
        )
        try provider.prepare()
        let backupDirectory = parentURL.appendingPathComponent("Backups", isDirectory: true)
        let exportDirectory = parentURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
        let database = try AppDatabase(databaseURL: provider.databaseURL)
        let store = AttachmentStore(provider: provider, database: database)
        let coordinator = RestoreRecoveryCoordinator(provider: provider)
        let defaultsSuiteName = "SelfDMNotesArchiveTests.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let service = ArchiveService(
            provider: provider,
            database: database,
            recoveryCoordinator: coordinator,
            defaults: defaults,
            applicationVersion: "test",
            buildVersion: "test"
        )
        return ArchiveFixture(
            parentURL: parentURL,
            provider: provider,
            database: database,
            store: store,
            coordinator: coordinator,
            service: service,
            backupDirectory: backupDirectory,
            exportDirectory: exportDirectory,
            defaultsSuiteName: defaultsSuiteName
        )
    }

    func seedPortableContent() throws -> SeededArchiveContent {
        let firstBytes = Data("first report contents".utf8)
        let secondBytes = Data("second report contents".utf8)
        let first = try commitAttachmentNote(
            filename: "report.txt",
            bytes: firstBytes,
            body: "Initial body"
        )
        let editedAt = Date(timeIntervalSince1970: 1_700_000_100)
        _ = try database.editNote(
            id: first.id,
            body: "Edited body https://example.com/phase-five",
            updatedAt: editedAt
        )
        let snapshot = try XCTUnwrap(database.fetchLinkReconciliationSnapshot(noteID: first.id))
        _ = try database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body),
            now: Date(timeIntervalSince1970: 1_700_000_110)
        )
        try database.setAutomaticLinkPreviewsEnabled(true)
        let pending = try XCTUnwrap(database.fetchNote(id: first.id).linkPreviews.first)
        _ = try database.commitLinkPreviewMetadata(
            requestKey: pending.requestKey,
            metadata: LinkPreviewMetadata(
                canonicalURL: "https://example.com/phase-five",
                title: "Phase Five Preview",
                summary: "Portable preview summary",
                imageURL: "https://example.com/preview.png",
                siteName: "Example",
                imagePNGData: nil
            ),
            localImageFilename: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )

        let second = try commitAttachmentNote(
            filename: "report.txt",
            bytes: secondBytes,
            body: "Second body 🚀 https://failure.example/preview"
        )
        let secondSnapshot = try XCTUnwrap(
            database.fetchLinkReconciliationSnapshot(noteID: second.id)
        )
        _ = try database.reconcileLinkPreviews(
            snapshot: secondSnapshot,
            detectedLinks: LinkDetector().links(in: secondSnapshot.body),
            now: Date(timeIntervalSince1970: 1_700_000_190)
        )
        let failedPreview = try XCTUnwrap(database.fetchNote(id: second.id).linkPreviews.first)
        _ = try database.markLinkPreviewFailure(
            requestKey: failedPreview.requestKey,
            reason: "Offline fixture",
            now: Date(timeIntervalSince1970: 1_700_000_195)
        )
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_200)
        _ = try database.moveNoteToTrash(id: second.id, deletedAt: deletedAt)
        return SeededArchiveContent(
            firstNoteID: first.id,
            secondNoteID: second.id,
            editedAtMilliseconds: Int64(editedAt.timeIntervalSince1970 * 1_000),
            deletedAtMilliseconds: Int64(deletedAt.timeIntervalSince1970 * 1_000),
            firstAttachmentBytes: firstBytes,
            secondAttachmentBytes: secondBytes
        )
    }

    func cleanUp() {
        try? database.close()
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: parentURL)
    }

    private func commitAttachmentNote(filename: String, bytes: Data, body: String) throws -> Note {
        let sourceDirectory = parentURL.appendingPathComponent(
            "Input-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let sourceURL = sourceDirectory.appendingPathComponent(filename)
        try bytes.write(to: sourceURL)
        let staged = try store.stageSelectedFile(at: sourceURL, id: UUID(), sortIndex: 0)
        return try store.commitNote(body: body, stagedAttachments: [staged]).note
    }
}

private struct SeededArchiveContent {
    let firstNoteID: UUID
    let secondNoteID: UUID
    let editedAtMilliseconds: Int64
    let deletedAtMilliseconds: Int64
    let firstAttachmentBytes: Data
    let secondAttachmentBytes: Data
}
