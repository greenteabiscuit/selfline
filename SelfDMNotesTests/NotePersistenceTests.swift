import Foundation
import GRDB
import XCTest
@testable import SelfDMNotes

final class NotePersistenceTests: XCTestCase {
    func testV6ToV7MigrationAddsDurableReminderMetadata() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        let noteID = UUID()

        let v6Queue = try DatabaseQueue(path: provider.databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(
            v6Queue,
            upTo: "v6_create_note_threads"
        )
        try v6Queue.write { database in
            try database.execute(
                sql: "INSERT INTO notes (id, body, createdAt) VALUES (?, ?, ?)",
                arguments: [noteID.uuidString, "Existing note", 1_700_000_000_000]
            )
        }
        try v6Queue.close()

        let migrated = try AppDatabase(databaseURL: provider.databaseURL)
        let existing = try migrated.fetchNote(id: noteID)
        XCTAssertNil(existing.reminderAt)
        XCTAssertNil(existing.reminderCompletedAt)

        let reminderAt = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = try migrated.setReminder(id: noteID, at: reminderAt)
        XCTAssertEqual(scheduled.reminderAt, reminderAt)
        XCTAssertNil(scheduled.reminderCompletedAt)
        try migrated.close()

        let inspectionQueue = try DatabaseQueue(path: provider.databaseURL.path)
        defer { try? inspectionQueue.close() }
        let columns = try inspectionQueue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('notes')")
        }
        XCTAssertTrue(columns.contains("reminderAt"))
        XCTAssertTrue(columns.contains("reminderCompletedAt"))
        let indexes = try inspectionQueue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM pragma_index_list('notes')")
        }
        XCTAssertTrue(indexes.contains("notes_active_reminderAt_sortKey"))
    }

    func testV5ToV6MigrationPreservesNotesAsThreadRoots() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        let noteID = UUID()

        let v5Queue = try DatabaseQueue(path: provider.databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(
            v5Queue,
            upTo: "v5_create_link_previews_and_index_metadata"
        )
        try v5Queue.write { database in
            try database.execute(
                sql: "INSERT INTO notes (id, body, createdAt) VALUES (?, ?, ?)",
                arguments: [noteID.uuidString, "Preserved root", 1_700_000_000_000]
            )
        }
        try v5Queue.close()

        let migrated = try AppDatabase(databaseURL: provider.databaseURL)
        let note = try migrated.fetchNote(id: noteID)
        XCTAssertEqual(note.body, "Preserved root")
        XCTAssertNil(note.threadRootID)
        XCTAssertEqual(note.replyCount, 0)
        try migrated.verifyIntegrityAndForeignKeys()
        try migrated.close()

        let inspectionQueue = try DatabaseQueue(path: provider.databaseURL.path)
        let columns = try inspectionQueue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('notes')")
        }
        XCTAssertTrue(columns.contains("threadRootID"))
        XCTAssertTrue(columns.contains("deletedWithRoot"))
        let indexes = try inspectionQueue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM pragma_index_list('notes')")
        }
        XCTAssertTrue(indexes.contains("notes_threadRootID_sortKey"))
        try inspectionQueue.close()
    }

    func testReminderSchedulingOrderingCompletionAndRemovalForRootsAndReplies() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root reminder")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Reply reminder")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rootReminder = now.addingTimeInterval(300)
        let replyReminder = now.addingTimeInterval(120)

        let scheduledRoot = try fixture.database.setReminder(id: root.id, at: rootReminder)
        let scheduledReply = try fixture.database.setReminder(id: reply.id, at: replyReminder)
        XCTAssertTrue(scheduledRoot.hasPendingReminder)
        XCTAssertTrue(scheduledReply.hasPendingReminder)
        XCTAssertFalse(scheduledRoot.isReminderDue(at: now))
        XCTAssertTrue(scheduledReply.isReminderDue(at: replyReminder))
        XCTAssertEqual(
            try fixture.database.fetchReminderNotes().map(\.id),
            [reply.id, root.id]
        )

        let editedRootReminder = now.addingTimeInterval(60)
        let editedRoot = try fixture.database.setReminder(id: root.id, at: editedRootReminder)
        XCTAssertEqual(editedRoot.reminderAt, editedRootReminder)
        XCTAssertEqual(
            try fixture.database.fetchReminderNotes().map(\.id),
            [root.id, reply.id]
        )

        let completedAt = now.addingTimeInterval(180)
        let completedReply = try fixture.database.markReminderDone(
            id: reply.id,
            completedAt: completedAt
        )
        XCTAssertEqual(completedReply.reminderAt, replyReminder)
        XCTAssertEqual(completedReply.reminderCompletedAt, completedAt)
        XCTAssertFalse(completedReply.hasPendingReminder)
        XCTAssertFalse(completedReply.isReminderDue(at: now.addingTimeInterval(1_000)))
        XCTAssertEqual(try fixture.database.fetchReminderNotes().map(\.id), [root.id])
        XCTAssertThrowsError(try fixture.database.markReminderDone(id: reply.id)) {
            XCTAssertEqual($0 as? AppDatabaseError, .reminderUnavailable)
        }

        let removedRoot = try fixture.database.removeReminder(id: root.id)
        XCTAssertNil(removedRoot.reminderAt)
        XCTAssertNil(removedRoot.reminderCompletedAt)
        XCTAssertTrue(try fixture.database.fetchReminderNotes().isEmpty)
    }

    func testTrashTemporarilyHidesPendingRemindersAndRestoreRevealsThem() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Reply")
        let rootReminder = Date(timeIntervalSince1970: 1_800_000_000)
        let replyReminder = rootReminder.addingTimeInterval(60)
        _ = try fixture.database.setReminder(id: root.id, at: rootReminder)
        _ = try fixture.database.setReminder(id: reply.id, at: replyReminder)

        _ = try fixture.database.moveNoteToTrash(id: reply.id)
        XCTAssertEqual(try fixture.database.fetchReminderNotes().map(\.id), [root.id])
        let trashedReply = try fixture.database.fetchNote(id: reply.id)
        XCTAssertEqual(trashedReply.reminderAt, replyReminder)
        XCTAssertNil(trashedReply.reminderCompletedAt)

        _ = try fixture.database.restoreNote(id: reply.id)
        XCTAssertEqual(
            try fixture.database.fetchReminderNotes().map(\.id),
            [root.id, reply.id]
        )

        _ = try fixture.database.moveNoteToTrash(id: root.id)
        XCTAssertTrue(try fixture.database.fetchReminderNotes().isEmpty)
        XCTAssertEqual(try fixture.database.fetchNote(id: root.id).reminderAt, rootReminder)
        XCTAssertEqual(try fixture.database.fetchNote(id: reply.id).reminderAt, replyReminder)

        _ = try fixture.database.restoreNote(id: root.id)
        XCTAssertEqual(
            try fixture.database.fetchReminderNotes().map(\.id),
            [root.id, reply.id]
        )

        _ = try fixture.database.moveNoteToTrash(id: root.id)
        _ = try fixture.database.permanentlyDeleteNote(id: root.id)
        XCTAssertTrue(try fixture.database.fetchReminderNotes().isEmpty)
        XCTAssertThrowsError(try fixture.database.fetchNote(id: root.id))
        XCTAssertThrowsError(try fixture.database.fetchNote(id: reply.id))
    }

    func testReplyCreationThreadFetchCountsAndPagingExclusion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root")
        let otherRoot = try fixture.database.createNote(body: "Other root")
        let firstReply = try fixture.database.createReply(
            rootID: root.id,
            body: "First reply",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let secondReply = try fixture.database.createReply(
            rootID: root.id,
            body: "Second reply",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(firstReply.threadRootID, root.id)
        XCTAssertEqual(secondReply.threadRootID, root.id)
        XCTAssertThrowsError(
            try fixture.database.createReply(rootID: firstReply.id, body: "Nested")
        ) {
            XCTAssertEqual($0 as? AppDatabaseError, .invalidThreadRoot)
        }

        let page = try fixture.database.fetchNotesPage()
        XCTAssertEqual(Set(page.notes.map(\.id)), Set([root.id, otherRoot.id]))
        XCTAssertFalse(page.notes.contains(where: \.isReply))
        XCTAssertEqual(page.notes.first(where: { $0.id == root.id })?.replyCount, 2)

        let thread = try fixture.database.fetchThread(rootID: root.id)
        XCTAssertEqual(thread.root.id, root.id)
        XCTAssertEqual(thread.root.replyCount, 2)
        XCTAssertEqual(thread.replies.map(\.id), [firstReply.id, secondReply.id])
        XCTAssertEqual(thread.replies.map(\.threadRootID), [root.id, root.id])

        let counts = try fixture.database.fetchReplyCounts(
            rootIDs: [root.id, otherRoot.id, root.id]
        )
        XCTAssertEqual(counts, [root.id: 2, otherRoot.id: 0])

        _ = try fixture.database.moveNoteToTrash(id: firstReply.id)
        XCTAssertEqual(try fixture.database.fetchTrashPage().notes.map(\.id), [firstReply.id])
        XCTAssertEqual(try fixture.database.fetchThread(rootID: root.id).replies.map(\.id), [secondReply.id])
        XCTAssertEqual(try fixture.database.fetchNote(id: root.id).replyCount, 1)
    }

    func testRootTrashRestoreAndPermanentDeletePreserveThreadInvariants() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root with reply assets")
        let blobID = UUID()
        let replyAttachment = NewAttachment(
            id: UUID(),
            originalFilename: "reply.txt",
            createdAt: Date(timeIntervalSince1970: 300),
            sortIndex: 0,
            blob: AttachmentBlob(
                id: blobID,
                contentHash: String(repeating: "a", count: 64),
                storedFilename: "\(blobID.uuidString.lowercased()).txt",
                thumbnailFilename: nil,
                mediaType: "text/plain",
                byteSize: 12,
                width: nil,
                height: nil,
                createdAt: Date(timeIntervalSince1970: 300)
            )
        )
        let reply = try fixture.database.createReply(
            rootID: root.id,
            body: "Reply https://reply.example/thread",
            attachments: [replyAttachment]
        )
        let snapshot = try XCTUnwrap(
            fixture.database.fetchLinkReconciliationSnapshot(noteID: reply.id)
        )
        _ = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        try fixture.database.setAutomaticLinkPreviewsEnabled(true)
        let pendingPreview = try XCTUnwrap(
            fixture.database.fetchNote(id: reply.id).linkPreviews.first
        )
        let previewFilename = "\(UUID().uuidString.lowercased()).png"
        _ = try fixture.database.commitLinkPreviewMetadata(
            requestKey: pendingPreview.requestKey,
            metadata: LinkPreviewMetadata(
                canonicalURL: pendingPreview.originalURL,
                title: "Reply preview",
                summary: nil,
                imageURL: nil,
                siteName: "Reply",
                imagePNGData: nil
            ),
            localImageFilename: previewFilename,
            fetchedAt: Date(timeIntervalSince1970: 400)
        )

        let deletedAt = Date(timeIntervalSince1970: 500)
        _ = try fixture.database.moveNoteToTrash(id: root.id, deletedAt: deletedAt)
        XCTAssertEqual(try fixture.database.fetchTrashPage().notes.map(\.id), [root.id])
        XCTAssertEqual(try fixture.database.fetchNote(id: root.id).deletedAt, deletedAt)
        XCTAssertEqual(try fixture.database.fetchNote(id: reply.id).deletedAt, deletedAt)
        XCTAssertThrowsError(try fixture.database.createReply(rootID: root.id, body: "Unavailable")) {
            XCTAssertEqual($0 as? AppDatabaseError, .invalidThreadRoot)
        }

        _ = try fixture.database.restoreNote(id: root.id)
        XCTAssertNil(try fixture.database.fetchNote(id: root.id).deletedAt)
        XCTAssertNil(try fixture.database.fetchNote(id: reply.id).deletedAt)

        _ = try fixture.database.moveNoteToTrash(id: root.id, deletedAt: deletedAt)
        let deletedFiles = try fixture.database.permanentlyDeleteNote(id: root.id)
        XCTAssertEqual(deletedFiles.blobs.map(\.id), [blobID])
        XCTAssertEqual(deletedFiles.previewImageFilenames, [previewFilename])
        XCTAssertThrowsError(try fixture.database.fetchNote(id: root.id))
        XCTAssertThrowsError(try fixture.database.fetchNote(id: reply.id))
        XCTAssertNil(try fixture.database.fetchAttachmentBlob(contentHash: replyAttachment.blob.contentHash))
        try fixture.database.verifyIntegrityAndForeignKeys()
    }

    func testRootRestoreDoesNotRestoreReplyTrashedIndependently() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Reply")
        _ = try fixture.database.moveNoteToTrash(
            id: reply.id,
            deletedAt: Date(timeIntervalSince1970: 600)
        )
        _ = try fixture.database.moveNoteToTrash(
            id: root.id,
            deletedAt: Date(timeIntervalSince1970: 700)
        )

        _ = try fixture.database.restoreNote(id: root.id)

        XCTAssertNil(try fixture.database.fetchNote(id: root.id).deletedAt)
        XCTAssertNotNil(try fixture.database.fetchNote(id: reply.id).deletedAt)
        XCTAssertEqual(try fixture.database.fetchTrashPage().notes.map(\.id), [reply.id])
    }

    func testRootRestoreUsesCascadeProvenanceWhenDeletionTimestampsAreEqual() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Reply")
        let sharedDeletedAt = Date(timeIntervalSince1970: 800)

        _ = try fixture.database.moveNoteToTrash(id: reply.id, deletedAt: sharedDeletedAt)
        _ = try fixture.database.moveNoteToTrash(id: root.id, deletedAt: sharedDeletedAt)
        XCTAssertFalse(try deletedWithRoot(noteID: reply.id, rootURL: fixture.rootURL))

        _ = try fixture.database.restoreNote(id: root.id)
        XCTAssertNil(try fixture.database.fetchNote(id: root.id).deletedAt)
        XCTAssertEqual(try fixture.database.fetchNote(id: reply.id).deletedAt, sharedDeletedAt)

        _ = try fixture.database.restoreNote(id: reply.id)
        XCTAssertFalse(try deletedWithRoot(noteID: reply.id, rootURL: fixture.rootURL))
        _ = try fixture.database.moveNoteToTrash(id: root.id, deletedAt: sharedDeletedAt)
        XCTAssertTrue(try deletedWithRoot(noteID: reply.id, rootURL: fixture.rootURL))
        _ = try fixture.database.restoreNote(id: root.id)
        XCTAssertNil(try fixture.database.fetchNote(id: reply.id).deletedAt)
        XCTAssertFalse(try deletedWithRoot(noteID: reply.id, rootURL: fixture.rootURL))
    }

    @MainActor
    func testFailedThreadSwitchClearsDisplayedThreadAndRetainsRequestedTarget() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Loaded root")
        let reply = try fixture.database.createReply(rootID: root.id, body: "Loaded reply")
        let model = TimelineViewModel(database: fixture.database)

        let didOpenRoot = await model.openThread(rootID: root.id)
        XCTAssertTrue(didOpenRoot)
        XCTAssertEqual(model.threadRoot?.id, root.id)
        XCTAssertEqual(model.threadReplies.map(\.id), [reply.id])

        let missingRootID = UUID()
        let didOpenMissingRoot = await model.openThread(rootID: missingRootID)
        XCTAssertFalse(didOpenMissingRoot)
        XCTAssertEqual(model.requestedThreadRootID, missingRootID)
        XCTAssertNil(model.threadRoot)
        XCTAssertTrue(model.threadReplies.isEmpty)
        XCTAssertFalse(model.isLoadingThread)
        XCTAssertFalse(model.isReplyComposerReady)
    }

    func testReplyComposerReadinessAndSessionTokensAreRootScoped() {
        let firstRootID = UUID()
        let secondRootID = UUID()
        let token = UUID()
        let firstSession = ReplyDraftSession(rootID: firstRootID, token: token)
        let replacementSession = ReplyDraftSession(rootID: secondRootID)

        XCTAssertTrue(firstSession.matches(rootID: firstRootID, token: token))
        XCTAssertFalse(replacementSession.matches(firstSession.identity))
        XCTAssertTrue(
            TimelineViewModel.isReplyComposerReady(
                displayedRootID: firstRootID,
                requestedRootID: firstRootID,
                isLoading: false
            )
        )
        XCTAssertFalse(
            TimelineViewModel.isReplyComposerReady(
                displayedRootID: firstRootID,
                requestedRootID: secondRootID,
                isLoading: false
            )
        )
        XCTAssertFalse(
            TimelineViewModel.isReplyComposerReady(
                displayedRootID: firstRootID,
                requestedRootID: firstRootID,
                isLoading: true
            )
        )
    }

    func testSearchNavigationClosesOnlyAnUnrelatedRequestedThread() {
        let requestedRootID = UUID()

        XCTAssertFalse(
            ContentView.requiresThreadClosure(
                requestedRootID: requestedRootID,
                destinationRootID: requestedRootID,
                destinationOpensThread: false
            )
        )
        XCTAssertTrue(
            ContentView.requiresThreadClosure(
                requestedRootID: requestedRootID,
                destinationRootID: UUID(),
                destinationOpensThread: false
            )
        )
        XCTAssertFalse(
            ContentView.requiresThreadClosure(
                requestedRootID: nil,
                destinationRootID: UUID(),
                destinationOpensThread: false
            )
        )
        XCTAssertFalse(
            ContentView.requiresThreadClosure(
                requestedRootID: requestedRootID,
                destinationRootID: requestedRootID,
                destinationOpensThread: true
            )
        )
        XCTAssertFalse(
            ContentView.requiresThreadClosure(
                requestedRootID: requestedRootID,
                destinationRootID: UUID(),
                destinationOpensThread: true
            )
        )
        XCTAssertFalse(
            ContentView.requiresThreadClosure(
                requestedRootID: nil,
                destinationRootID: UUID(),
                destinationOpensThread: true
            )
        )
    }

    func testOrderingUsesMonotonicSortKeysAndBoundedKeysetPages() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let timestamp = Date(timeIntervalSince1970: 1_720_000_000.123)

        let first = try fixture.database.createNote(body: "First", createdAt: timestamp)
        let second = try fixture.database.createNote(body: "Second", createdAt: timestamp)
        let third = try fixture.database.createNote(body: "Third", createdAt: timestamp)

        XCTAssertLessThan(first.sortKey, second.sortKey)
        XCTAssertLessThan(second.sortKey, third.sortKey)

        let newestPage = try fixture.database.fetchNotesPage(limit: 2)
        XCTAssertEqual(newestPage.notes.map(\.body), ["Second", "Third"])
        XCTAssertTrue(newestPage.hasOlder)

        let olderPage = try fixture.database.fetchNotesPage(
            beforeSortKey: second.sortKey,
            limit: 2
        )
        XCTAssertEqual(olderPage.notes.map(\.body), ["First"])
        XCTAssertFalse(olderPage.hasOlder)

        let cappedPage = try fixture.database.fetchNotesPage(limit: 10_000)
        XCTAssertLessThanOrEqual(cappedPage.notes.count, AppDatabase.maximumPageSize)
        XCTAssertThrowsError(try fixture.database.fetchNotesPage(limit: 0))
    }

    func testEditPreservesCreationAndOrderWhileSettingUpdatedTimestamp() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.456)
        let updatedAt = Date(timeIntervalSince1970: 1_710_000_000.789)
        let note = try fixture.database.createNote(body: "Original", createdAt: createdAt)

        let edited = try fixture.database.editNote(
            id: note.id,
            body: "Edited\ntext",
            updatedAt: updatedAt
        )

        XCTAssertEqual(edited.body, "Edited\ntext")
        XCTAssertEqual(edited.createdAt, createdAt)
        XCTAssertEqual(edited.updatedAt, updatedAt)
        XCTAssertEqual(edited.sortKey, note.sortKey)
        XCTAssertThrowsError(try fixture.database.editNote(id: note.id, body: " \n\t "))
    }

    func testTrashRestoreAndConfirmedDeleteStorageSemantics() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let note = try fixture.database.createNote(body: "Recoverable")

        let trashed = try fixture.database.moveNoteToTrash(id: note.id)
        XCTAssertNotNil(trashed.deletedAt)
        XCTAssertTrue(try fixture.database.fetchNotesPage().notes.isEmpty)
        XCTAssertEqual(try fixture.database.fetchTrashPage().notes.map(\.id), [note.id])
        XCTAssertThrowsError(try fixture.database.editNote(id: note.id, body: "No"))

        let restored = try fixture.database.restoreNote(id: note.id)
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.sortKey, note.sortKey)
        XCTAssertEqual(try fixture.database.fetchNotesPage().notes.map(\.id), [note.id])
        XCTAssertThrowsError(try fixture.database.permanentlyDeleteNote(id: note.id))

        try fixture.database.moveNoteToTrash(id: note.id)
        try fixture.database.permanentlyDeleteNote(id: note.id)
        XCTAssertTrue(try fixture.database.fetchTrashPage().notes.isEmpty)

        let laterNote = try fixture.database.createNote(body: "Later")
        XCTAssertGreaterThan(laterNote.sortKey, note.sortKey)
    }

    func testDraftSurvivesReopenAndSuccessfulCreateClearsIt() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        let savedAt = Date(timeIntervalSince1970: 1_730_000_000.111)

        var database: AppDatabase? = try AppDatabase(databaseURL: provider.databaseURL)
        try database?.saveDraft(body: "Unsent\nmultiline draft", updatedAt: savedAt)
        try database?.close()
        database = nil

        let reopened = try AppDatabase(databaseURL: provider.databaseURL)
        XCTAssertEqual(
            try reopened.loadDraft(),
            Draft(body: "Unsent\nmultiline draft", updatedAt: savedAt)
        )
        _ = try reopened.createNote(body: "Unsent\nmultiline draft")
        XCTAssertNil(try reopened.loadDraft())
        try reopened.close()
    }

    func testFailedInsertionLeavesLatestDraftRecoverable() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()

        let setupQueue = try DatabaseQueue(path: provider.databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(setupQueue)
        try setupQueue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER force_note_insert_failure
                BEFORE INSERT ON notes
                BEGIN
                    SELECT RAISE(FAIL, 'forced persistence failure');
                END
                """)
        }
        try setupQueue.close()

        let database = try AppDatabase(databaseURL: provider.databaseURL)
        try database.saveDraft(body: "Keep this exact draft")
        XCTAssertThrowsError(try database.createNote(body: "Keep this exact draft"))
        XCTAssertEqual(try database.loadDraft()?.body, "Keep this exact draft")
        XCTAssertTrue(try database.fetchNotesPage().notes.isEmpty)
        try database.close()
    }

    func testWhitespaceOnlyNoteIsRejectedWithoutChangingDraft() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.database.saveDraft(body: "Existing draft")

        XCTAssertThrowsError(try fixture.database.createNote(body: " \n\t "))
        XCTAssertEqual(try fixture.database.loadDraft()?.body, "Existing draft")
        XCTAssertTrue(try fixture.database.fetchNotesPage().notes.isEmpty)
    }

    @MainActor
    func testTimelineRefillsWhenMutationsEmptyLoadedWindow() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        for index in 0...TimelineViewModel.pageSize {
            _ = try fixture.database.createNote(body: "Note \(index)")
        }
        let model = TimelineViewModel(database: fixture.database)
        await model.loadInitialContent()

        XCTAssertEqual(model.notes.count, TimelineViewModel.pageSize)
        XCTAssertTrue(model.hasOlderNotes)
        let initiallyLoadedNotes = model.notes
        for note in initiallyLoadedNotes {
            await model.moveNoteToTrash(note)
        }

        XCTAssertEqual(model.notes.map(\.body), ["Note 0"])
        XCTAssertFalse(model.hasOlderNotes)
    }

    @MainActor
    func testTrashRefillsWhenPermanentDeletesEmptyLoadedWindow() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        for index in 0...TimelineViewModel.pageSize {
            let note = try fixture.database.createNote(body: "Trash \(index)")
            _ = try fixture.database.moveNoteToTrash(id: note.id)
        }
        let model = TimelineViewModel(database: fixture.database)
        await model.loadInitialContent()
        await model.loadTrash()

        XCTAssertEqual(model.trashNotes.count, TimelineViewModel.pageSize)
        XCTAssertTrue(model.hasOlderTrash)
        let initiallyLoadedNotes = model.trashNotes
        for note in initiallyLoadedNotes {
            await model.permanentlyDeleteNote(note)
        }

        XCTAssertEqual(model.trashNotes.map(\.body), ["Trash 0"])
        XCTAssertFalse(model.hasOlderTrash)
    }

    @MainActor
    func testRestoreDoesNotInjectNoteOlderThanLoadedTimelineWindow() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let oldNote = try fixture.database.createNote(body: "Out of window")
        _ = try fixture.database.moveNoteToTrash(id: oldNote.id)
        for index in 0...TimelineViewModel.pageSize {
            _ = try fixture.database.createNote(body: "Active \(index)")
        }
        let model = TimelineViewModel(database: fixture.database)
        await model.loadInitialContent()
        await model.loadTrash()

        let trashedNote = try XCTUnwrap(model.trashNotes.first)
        await model.restoreNote(trashedNote)

        XCTAssertEqual(model.notes.count, TimelineViewModel.pageSize)
        XCTAssertFalse(model.notes.contains { $0.id == oldNote.id })
        XCTAssertTrue(model.hasOlderNotes)
        XCTAssertTrue(model.trashNotes.isEmpty)
    }

    private func makeFixture() throws -> DatabaseFixture {
        let rootURL = temporaryRoot()
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        return DatabaseFixture(
            rootURL: rootURL,
            database: try AppDatabase(databaseURL: provider.databaseURL)
        )
    }

    private func deletedWithRoot(noteID: UUID, rootURL: URL) throws -> Bool {
        let queue = try DatabaseQueue(
            path: rootURL.appendingPathComponent("notes.sqlite").path
        )
        defer { try? queue.close() }
        return try queue.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT deletedWithRoot FROM notes WHERE id = ?",
                arguments: [noteID.uuidString]
            ) ?? false
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct DatabaseFixture {
    let rootURL: URL
    let database: AppDatabase

    func cleanUp() {
        try? database.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
