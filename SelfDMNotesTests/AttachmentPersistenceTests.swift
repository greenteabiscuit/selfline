import Foundation
import GRDB
import XCTest
@testable import SelfDMNotes

final class AttachmentPersistenceTests: XCTestCase {
    func testManagedDirectoriesAndIndependentStreamedImport() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("outside-source.txt")
        let bytes = Data(String(repeating: "bounded-stream\n", count: 700_000).utf8)
        try bytes.write(to: sourceURL)
        let progressRecorder = AttachmentProgressRecorder()

        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0,
            progress: progressRecorder.append
        )
        try FileManager.default.removeItem(at: sourceURL)
        let result = try fixture.store.commitNote(
            body: "Imported independently",
            stagedAttachments: [staged]
        )

        let attachment = try XCTUnwrap(result.note.attachments.first)
        XCTAssertEqual(attachment.originalFilename, "outside-source.txt")
        XCTAssertEqual(attachment.byteSize, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: fixture.store.originalURL(for: attachment)), bytes)
        XCTAssertEqual(AttachmentStore.copyBufferSize, 1_048_576)
        let progressValues = progressRecorder.values
        XCTAssertTrue(progressValues.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(progressValues.last, 1)
        XCTAssertTrue(directoryExists(fixture.provider.originalsURL))
        XCTAssertTrue(directoryExists(fixture.provider.thumbnailsURL))
        XCTAssertTrue(directoryExists(fixture.provider.stagingURL))
    }

    func testDuplicateBytesKeepLogicalNamesAndDeleteOnlyFinalReference() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bytes = Data("same durable bytes".utf8)
        let firstSource = fixture.rootURL.appendingPathComponent("first.txt")
        let secondSource = fixture.rootURL.appendingPathComponent("second.md")
        try bytes.write(to: firstSource)
        try bytes.write(to: secondSource)

        let firstStage = try fixture.store.stageSelectedFile(
            at: firstSource,
            id: UUID(),
            sortIndex: 0
        )
        let secondStage = try fixture.store.stageSelectedFile(
            at: secondSource,
            id: UUID(),
            sortIndex: 1
        )
        let firstNote = try fixture.store.commitNote(
            body: "Two logical attachments",
            stagedAttachments: [firstStage, secondStage]
        ).note
        XCTAssertEqual(firstNote.attachments.map(\.originalFilename), ["first.txt", "second.md"])
        XCTAssertEqual(Set(firstNote.attachments.map(\.storedFilename)).count, 1)
        XCTAssertEqual(try immediateFiles(at: fixture.provider.originalsURL).count, 1)

        let thirdSource = fixture.rootURL.appendingPathComponent("third.data")
        try bytes.write(to: thirdSource)
        let thirdStage = try fixture.store.stageSelectedFile(
            at: thirdSource,
            id: UUID(),
            sortIndex: 0
        )
        let secondNote = try fixture.store.commitNote(
            body: "Shared reference",
            stagedAttachments: [thirdStage]
        ).note
        let managedURL = try XCTUnwrap(firstNote.attachments.first).storedFilename

        _ = try fixture.database.moveNoteToTrash(id: firstNote.id)
        let firstDeletion = try fixture.store.permanentlyDeleteNote(id: firstNote.id)
        XCTAssertFalse(firstDeletion.managedFileCleanupFailed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.provider.originalsURL.appendingPathComponent(managedURL).path
            )
        )

        _ = try fixture.database.moveNoteToTrash(id: secondNote.id)
        let secondDeletion = try fixture.store.permanentlyDeleteNote(id: secondNote.id)
        XCTAssertFalse(secondDeletion.managedFileCleanupFailed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.provider.originalsURL.appendingPathComponent(managedURL).path
            )
        )
    }

    func testExternalPresentationCannotMutateManagedOriginal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bytes = Data("immutable archive bytes".utf8)
        let sourceURL = fixture.rootURL.appendingPathComponent("immutable.txt")
        try bytes.write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let note = try fixture.store.commitNote(
            body: "Independent presentation",
            stagedAttachments: [staged]
        ).note
        let attachment = try XCTUnwrap(note.attachments.first)

        let presentationURL = try fixture.store.makeExternalPresentation(for: attachment)
        try Data("edited outside the app".utf8).write(to: presentationURL)

        XCTAssertEqual(try Data(contentsOf: fixture.store.originalURL(for: attachment)), bytes)
    }

    func testExportWritesOnlyToExactSelectedDestination() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bytes = Data("exact destination export".utf8)
        let sourceURL = fixture.rootURL.appendingPathComponent("source.txt")
        try bytes.write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let note = try fixture.store.commitNote(
            body: "Export",
            stagedAttachments: [staged]
        ).note
        let attachment = try XCTUnwrap(note.attachments.first)
        let exportDirectory = fixture.rootURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = exportDirectory.appendingPathComponent("selected.txt")
        try Data("replace me".utf8).write(to: destinationURL)

        try fixture.store.exportAttachment(attachment, to: destinationURL)

        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)
        XCTAssertEqual(
            try immediateFiles(at: exportDirectory).map(\.lastPathComponent),
            ["selected.txt"]
        )
        XCTAssertEqual(try Data(contentsOf: fixture.store.originalURL(for: attachment)), bytes)
    }

    func testSendFailsClosedWhenAttachmentManifestDoesNotMatchRequest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("still-pending.txt")
        try Data("still pending".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )

        XCTAssertThrowsError(try fixture.database.createNote(body: "Stale text-only send")) {
            XCTAssertEqual($0 as? AppDatabaseError, .draftAttachmentsChanged)
        }
        XCTAssertEqual(try fixture.database.fetchStagedAttachments(), [staged])
        XCTAssertTrue(try fixture.database.fetchNotesPage().notes.isEmpty)
    }

    func testAttachmentOnlyNoteFilenameSearchAndFilters() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let imageURL = fixture.rootURL.appendingPathComponent("Quarterly Diagram.png")
        try pngData.write(to: imageURL)
        let staged = try fixture.store.stageSelectedFile(
            at: imageURL,
            id: UUID(),
            sortIndex: 0
        )

        let note = try fixture.store.commitNote(body: "", stagedAttachments: [staged]).note
        XCTAssertEqual(note.body, "")
        XCTAssertEqual(note.attachments.count, 1)
        XCTAssertTrue(try XCTUnwrap(note.attachments.first).isImage)

        let filenameResponse = try fixture.database.searchNotes(
            NoteSearchRequest(
                text: "quarterly diagram",
                filters: NoteSearchFilters(),
                sort: .relevance
            )
        )
        XCTAssertEqual(filenameResponse.results.map(\.id), [note.id])
        _ = try fixture.database.moveNoteToTrash(id: note.id)
        XCTAssertTrue(
            try fixture.database.searchNotes(
                NoteSearchRequest(
                    text: "quarterly diagram",
                    filters: NoteSearchFilters(),
                    sort: .relevance
                )
            ).results.isEmpty
        )
        _ = try fixture.database.restoreNote(id: note.id)
        XCTAssertEqual(
            try fixture.database.searchNotes(
                NoteSearchRequest(
                    text: "quarterly diagram",
                    filters: NoteSearchFilters(),
                    sort: .relevance
                )
            ).results.map(\.id),
            [note.id]
        )

        var attachmentFilter = NoteSearchFilters()
        attachmentFilter.hasAttachment = true
        XCTAssertEqual(
            try fixture.database.searchNotes(
                NoteSearchRequest(text: "", filters: attachmentFilter, sort: .newest)
            ).results.map(\.id),
            [note.id]
        )
        var imageFilter = NoteSearchFilters()
        imageFilter.hasImage = true
        XCTAssertEqual(
            try fixture.database.searchNotes(
                NoteSearchRequest(text: "", filters: imageFilter, sort: .newest)
            ).results.map(\.id),
            [note.id]
        )
    }

    func testMalformedImageDegradesToFileAndDirectoryImportFailsRecoverably() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let malformedURL = fixture.rootURL.appendingPathComponent("malformed.png")
        try Data("not an image".utf8).write(to: malformedURL)
        let malformed = try fixture.store.stageSelectedFile(
            at: malformedURL,
            id: UUID(),
            sortIndex: 0
        )
        XCTAssertFalse(malformed.isImage)
        XCTAssertNil(malformed.thumbnailStagingFilename)
        let note = try fixture.store.commitNote(
            body: "Malformed remains accessible",
            stagedAttachments: [malformed]
        ).note
        XCTAssertFalse(try XCTUnwrap(note.attachments.first).isImage)

        let directoryURL = fixture.rootURL.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try fixture.store.stageSelectedFile(
                at: directoryURL,
                id: UUID(),
                sortIndex: 0
            )
        ) { error in
            guard case AttachmentStoreError.sourceIsNotRegularFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFailedTransactionalSendKeepsManifestAndStagingWithoutManagedOrphan() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("retry.txt")
        try Data("retryable staged bytes".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let queue = try DatabaseQueue(path: fixture.provider.databaseURL.path)
        try queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER force_phase3_send_failure
                BEFORE INSERT ON notes
                BEGIN
                    SELECT RAISE(FAIL, 'forced send failure');
                END
                """)
        }
        try queue.close()

        XCTAssertThrowsError(
            try fixture.store.commitNote(body: "Keep together", stagedAttachments: [staged])
        )
        XCTAssertEqual(try fixture.database.fetchStagedAttachments(), [staged])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.provider.stagingURL
                    .appendingPathComponent(staged.stagingFilename).path
            )
        )
        XCTAssertTrue(try immediateFiles(at: fixture.provider.originalsURL).isEmpty)
        XCTAssertTrue(try fixture.database.fetchNotesPage().notes.isEmpty)
    }

    func testStartupRetainsManifestedDraftAndCleansAbandonedAndOrphanedFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("recovered.txt")
        try Data("recovered attachment".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let abandonedURL = fixture.provider.stagingURL.appendingPathComponent("abandoned.part")
        let orphanURL = fixture.provider.originalsURL.appendingPathComponent("orphan.data")
        try Data("abandoned".utf8).write(to: abandonedURL)
        try Data("orphan".utf8).write(to: orphanURL)

        let state = try fixture.store.performStartupMaintenance()

        XCTAssertEqual(state.recoveredAttachments, [
            RecoveredStagedAttachment(attachment: staged, isAvailable: true)
        ])
        XCTAssertEqual(state.report.removedAbandonedStagingItems, 1)
        XCTAssertEqual(state.report.removedOrphanedManagedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.provider.stagingURL
                    .appendingPathComponent(staged.stagingFilename).path
            )
        )
    }

    @MainActor
    func testStartupCleanupFailureStillRestoresPersistedAttachmentDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("visible-after-cleanup-failure.txt")
        try Data("recoverable".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        try Data("abandoned".utf8).write(
            to: fixture.provider.stagingURL.appendingPathComponent("abandoned.part")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o300],
            ofItemAtPath: fixture.provider.stagingURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.provider.stagingURL.path
            )
        }

        let model = TimelineViewModel(
            database: fixture.database,
            attachmentStore: fixture.store
        )
        await model.loadInitialContent()

        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.pendingAttachments.map(\.id), [staged.id])
        XCTAssertEqual(model.pendingAttachments.first?.status, .ready)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.database.fetchStagedAttachments(), [staged])
    }

    @MainActor
    func testUnreadableAttachmentManifestKeepsComposerUnavailableForRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("invalid-manifest.txt")
        try Data("manifest".utf8).write(to: sourceURL)
        _ = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let queue = try DatabaseQueue(path: fixture.provider.databaseURL.path)
        try await queue.write { database in
            try database.execute(sql: "UPDATE draft_attachments SET id = 'not-a-uuid'")
        }
        try queue.close()

        let model = TimelineViewModel(
            database: fixture.database,
            attachmentStore: fixture.store
        )
        await model.loadInitialContent()

        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.canRetryInitialLoad)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testStartupReportsMissingManagedAndStagedBytesWithoutDeletingMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("managed-missing.txt")
        try Data("managed".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let note = try fixture.store.commitNote(
            body: "Missing bytes report",
            stagedAttachments: [staged]
        ).note
        let attachment = try XCTUnwrap(note.attachments.first)
        try FileManager.default.removeItem(at: fixture.store.originalURL(for: attachment))

        let otherURL = fixture.rootURL.appendingPathComponent("staged-missing.txt")
        try Data("staged".utf8).write(to: otherURL)
        let missingStage = try fixture.store.stageSelectedFile(
            at: otherURL,
            id: UUID(),
            sortIndex: 0
        )
        try FileManager.default.removeItem(
            at: fixture.provider.stagingURL.appendingPathComponent(missingStage.stagingFilename)
        )

        let state = try fixture.store.performStartupMaintenance()

        XCTAssertEqual(state.report.missingManagedOriginalFilenames, ["managed-missing.txt"])
        XCTAssertEqual(state.report.missingStagedAttachmentFilenames, ["staged-missing.txt"])
        XCTAssertEqual(try fixture.database.fetchNotesPage().notes.map(\.id), [note.id])
        XCTAssertEqual(try fixture.database.fetchStagedAttachments(), [missingStage])
    }

    func testDraftDiscardIsAtomicAndReturnsFilesForPostCommitCleanup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("discarded.txt")
        try Data("discard me".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        try fixture.database.saveDraft(body: "Discard all of this")

        let discardedAttachments = try fixture.database.discardDraft()

        XCTAssertEqual(discardedAttachments, [staged])
        XCTAssertNil(try fixture.database.loadDraft())
        XCTAssertTrue(try fixture.database.fetchStagedAttachments().isEmpty)
        let stagedURL = fixture.provider.stagingURL.appendingPathComponent(
            staged.stagingFilename
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertFalse(fixture.store.removeDiscardedDraftFiles(discardedAttachments))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testFailedDraftDiscardRollsBackTextAndAttachmentManifest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("rollback-discard.txt")
        try Data("keep me".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        try fixture.database.saveDraft(body: "Keep the complete draft")
        let queue = try DatabaseQueue(path: fixture.provider.databaseURL.path)
        try queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER force_draft_discard_failure
                BEFORE DELETE ON draft_attachments
                BEGIN
                    SELECT RAISE(FAIL, 'forced discard failure');
                END
                """)
        }
        try queue.close()

        XCTAssertThrowsError(try fixture.database.discardDraft())
        XCTAssertEqual(try fixture.database.loadDraft()?.body, "Keep the complete draft")
        XCTAssertEqual(try fixture.database.fetchStagedAttachments(), [staged])
    }

    @MainActor
    func testFailedDraftDiscardPersistsLatestVisibleTextAndKeepsManifest() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("model-rollback-discard.txt")
        try Data("keep model draft".utf8).write(to: sourceURL)
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let model = TimelineViewModel(
            database: fixture.database,
            attachmentStore: fixture.store
        )
        await model.loadInitialContent()
        let queue = try DatabaseQueue(path: fixture.provider.databaseURL.path)
        try await queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER force_model_draft_discard_failure
                BEFORE DELETE ON draft_attachments
                BEGIN
                    SELECT RAISE(FAIL, 'forced model discard failure');
                END
                """)
        }
        try queue.close()
        model.setDraft("Keep latest visible draft")

        await model.discardDraft()

        XCTAssertEqual(model.draftText, "Keep latest visible draft")
        XCTAssertEqual(model.pendingAttachments.map(\.id), [staged.id])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.database.loadDraft()?.body, "Keep latest visible draft")
        XCTAssertEqual(try fixture.database.fetchStagedAttachments(), [staged])
    }

    @MainActor
    func testDiscardSettlesActiveImportWithoutResurrectingManifest() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = TimelineViewModel(
            database: fixture.database,
            attachmentStore: fixture.store
        )
        await model.loadInitialContent()
        model.setDraft("Discard while importing")
        let sourceURL = fixture.rootURL.appendingPathComponent("active-import.data")
        try Data(repeating: 0x5a, count: AttachmentStore.copyBufferSize * 8).write(
            to: sourceURL
        )
        model.addFileAttachments([sourceURL])

        await model.discardDraft()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.draftText, "")
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertFalse(model.isDiscardingDraft)
        XCTAssertNil(try fixture.database.loadDraft())
        XCTAssertTrue(try fixture.database.fetchStagedAttachments().isEmpty)
    }

    @MainActor
    func testRemovingActiveImportKeepsItTrackedUntilDiscardSettles() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = TimelineViewModel(
            database: fixture.database,
            attachmentStore: fixture.store
        )
        await model.loadInitialContent()
        model.setDraft("Discard after removing active import")
        let sourceURL = fixture.rootURL.appendingPathComponent("removed-active-import.data")
        guard FileManager.default.createFile(atPath: sourceURL.path, contents: nil) else {
            return XCTFail("Could not create removal fixture")
        }
        let handle = try FileHandle(forWritingTo: sourceURL)
        let chunk = Data(repeating: 0x5a, count: AttachmentStore.copyBufferSize)
        for _ in 0..<64 {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
        model.addFileAttachments([sourceURL])
        let attachmentID = try XCTUnwrap(model.pendingAttachments.first?.id)

        model.removePendingAttachment(id: attachmentID)

        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertFalse(model.canSend)
        await model.discardDraft()

        XCTAssertEqual(model.draftText, "")
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertNil(try fixture.database.loadDraft())
        XCTAssertTrue(try fixture.database.fetchStagedAttachments().isEmpty)
        let stagingNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.provider.stagingURL.path
        )
        XCTAssertFalse(stagingNames.contains { $0.hasPrefix(attachmentID.uuidString.lowercased()) })
    }

    @MainActor
    func testPendingMutationIsIgnoredWhileAttachmentSendIsSuspended() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sourceURL = fixture.rootURL.appendingPathComponent("send-guard.data")
        guard FileManager.default.createFile(atPath: sourceURL.path, contents: nil) else {
            return XCTFail("Could not create send fixture")
        }
        let handle = try FileHandle(forWritingTo: sourceURL)
        let chunk = Data(repeating: 0x5a, count: AttachmentStore.copyBufferSize)
        for _ in 0..<32 {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
        let staged = try fixture.store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let model = TimelineViewModel(
            database: fixture.database,
            attachmentStore: fixture.store
        )
        await model.loadInitialContent()
        let pendingBeforeSend = model.pendingAttachments

        let sendTask = Task { await model.sendDraft() }
        var observedSending = false
        for _ in 0..<10_000 {
            await Task.yield()
            if model.isSending {
                observedSending = true
                break
            }
        }
        XCTAssertTrue(observedSending)
        model.removePendingAttachment(id: staged.id)
        model.cancelPendingAttachment(id: staged.id)
        model.retryPendingAttachment(id: staged.id)
        await model.discardDraft()

        XCTAssertEqual(model.pendingAttachments, pendingBeforeSend)
        let sentNote = await sendTask.value
        XCTAssertNotNil(sentNote)
        XCTAssertTrue(try fixture.database.fetchStagedAttachments().isEmpty)
    }

    func testMigrationPreservesDeletedAutoincrementHighWaterMark() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        let queue = try DatabaseQueue(path: provider.databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(queue, upTo: "v2_create_note_search")
        for index in 0..<3 {
            try queue.write { database in
                try database.execute(
                    sql: "INSERT INTO notes (id, body, createdAt) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, "Old \(index)", index]
                )
            }
        }
        try queue.write { database in
            try database.execute(sql: "DELETE FROM notes")
        }
        try queue.close()

        let database = try AppDatabase(databaseURL: provider.databaseURL)
        let note = try database.createNote(body: "After migration")
        XCTAssertEqual(note.sortKey, 4)
        try database.close()
    }

    private var pngData: Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mP8z8Dwn4GBgYGJAQoAHgQCAZ7ZqZQAAAAASUVORK5CYII="
        )!
    }

    private func makeFixture() throws -> AttachmentDatabaseFixture {
        let rootURL = temporaryRoot()
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        let database = try AppDatabase(databaseURL: provider.databaseURL)
        return AttachmentDatabaseFixture(
            rootURL: rootURL,
            provider: provider,
            database: database,
            store: AttachmentStore(provider: provider, database: database)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesAttachmentTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func immediateFiles(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private struct AttachmentDatabaseFixture {
    let rootURL: URL
    let provider: ApplicationSupportDirectoryProvider
    let database: AppDatabase
    let store: AttachmentStore

    func cleanUp() {
        try? database.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class AttachmentProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func append(_ value: Double) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}
