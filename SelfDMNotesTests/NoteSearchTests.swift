import Foundation
import GRDB
import XCTest
@testable import SelfDMNotes

final class NoteSearchTests: XCTestCase {
    func testMigrationIndexesExistingActiveNotes() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()

        let queue = try DatabaseQueue(path: provider.databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(
            queue,
            upTo: "v1_create_notes_and_drafts"
        )
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO notes (id, body, createdAt) VALUES (?, ?, ?)",
                arguments: [UUID().uuidString, "Existing searchable archive", 1_700_000_000_000]
            )
            try database.execute(
                sql: "INSERT INTO notes (id, body, createdAt, deletedAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Existing trashed archive", 1_700_000_000_001, 1_700_000_000_002]
            )
        }
        try queue.close()

        let appDatabase = try AppDatabase(databaseURL: provider.databaseURL)
        XCTAssertEqual(try search(appDatabase, text: "searchable").results.count, 1)
        XCTAssertTrue(try search(appDatabase, text: "trashed").results.isEmpty)
        try appDatabase.close()
    }

    func testIndexTracksCreateEditTrashRestoreAndPermanentDelete() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let note = try fixture.database.createNote(body: "alpha lifecycle")
        XCTAssertEqual(try search(fixture.database, text: "alpha").results.map(\.id), [note.id])

        _ = try fixture.database.editNote(id: note.id, body: "beta lifecycle")
        XCTAssertTrue(try search(fixture.database, text: "alpha").results.isEmpty)
        XCTAssertEqual(try search(fixture.database, text: "beta").results.map(\.id), [note.id])

        _ = try fixture.database.moveNoteToTrash(id: note.id)
        XCTAssertTrue(try search(fixture.database, text: "beta").results.isEmpty)

        _ = try fixture.database.restoreNote(id: note.id)
        XCTAssertEqual(try search(fixture.database, text: "beta").results.map(\.id), [note.id])

        _ = try fixture.database.moveNoteToTrash(id: note.id)
        try fixture.database.permanentlyDeleteNote(id: note.id)
        XCTAssertTrue(try search(fixture.database, text: "beta").results.isEmpty)
    }

    func testOrdinaryQueryParsingAndUnicodeEmojiPunctuationAreSafe() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let note = try fixture.database.createNote(body: "Café 東京 launch 🚀 wow!!! C++")

        XCTAssertEqual(try search(fixture.database, text: "cafe").results.map(\.id), [note.id])
        XCTAssertEqual(try search(fixture.database, text: "東京").results.map(\.id), [note.id])
        XCTAssertEqual(try search(fixture.database, text: "🚀").results.map(\.id), [note.id])
        XCTAssertEqual(try search(fixture.database, text: "!!!").results.map(\.id), [note.id])
        XCTAssertEqual(try search(fixture.database, text: "東京 🚀").results.map(\.id), [note.id])
        XCTAssertNoThrow(try search(fixture.database, text: "\" OR * NEAR( ) - !!!"))

        let parsed = ParsedNoteSearchQuery.parse("hello OR \"quoted\" * NEAR(東京) 🚀")
        XCTAssertEqual(
            parsed.matchExpression,
            "\"hello\" AND \"OR\" AND \"quoted\" AND \"NEAR\" AND \"東京\""
        )
        XCTAssertEqual(parsed.literalTerms, ["🚀"])
    }

    func testDateFiltersAndChronologicalSorts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = try fixture.database.createNote(body: "shared newest", createdAt: base.addingTimeInterval(day * 2))
        let old = try fixture.database.createNote(body: "shared old", createdAt: base)
        let middle = try fixture.database.createNote(body: "shared middle", createdAt: base.addingTimeInterval(day))
        let filters = NoteSearchFilters(
            startDate: base.addingTimeInterval(day),
            endDateExclusive: base.addingTimeInterval(day * 3)
        )

        XCTAssertEqual(
            try search(fixture.database, text: "", filters: filters, sort: .oldest).results.map(\.id),
            [middle.id, newest.id]
        )
        XCTAssertEqual(
            try search(fixture.database, text: "shared", sort: .newest).results.map(\.id),
            [newest.id, middle.id, old.id]
        )
        XCTAssertEqual(
            try search(fixture.database, text: "shared", sort: .oldest).results.map(\.id),
            [old.id, middle.id, newest.id]
        )
    }

    func testLinkFilterFindsReconciledURLWithoutFetching() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let note = try fixture.database.createNote(body: "See https://example.net/search")
        let snapshot = try XCTUnwrap(
            fixture.database.fetchLinkReconciliationSnapshot(noteID: note.id)
        )
        _ = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        var filters = NoteSearchFilters()
        filters.hasLink = true

        XCTAssertEqual(
            try search(fixture.database, text: "", filters: filters).results.map(\.id),
            [note.id]
        )
    }

    func testTimelineContextIncludesExactOldIdentifier() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let oldest = try fixture.database.createNote(body: "old navigation target")
        for index in 0..<80 {
            _ = try fixture.database.createNote(body: "newer \(index)")
        }

        let context = try fixture.database.fetchTimelineContext(around: oldest.id)
        XCTAssertEqual(context.selectedNoteID, oldest.id)
        XCTAssertTrue(context.notes.contains { $0.id == oldest.id })
        XCTAssertTrue(context.hasNewer)
        XCTAssertEqual(context.notes, context.notes.sorted { $0.sortKey < $1.sortKey })
        XCTAssertLessThanOrEqual(context.notes.count, 51)
    }

    func testReplySearchResultMapsToRootAndTimelineContextExcludesReplies() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let root = try fixture.database.createNote(body: "Root navigation")
        let reply = try fixture.database.createReply(
            rootID: root.id,
            body: "Unique reply needle"
        )
        _ = try fixture.database.createNote(body: "Neighbor root")

        let result = try XCTUnwrap(
            search(fixture.database, text: "needle").results.first
        )
        XCTAssertEqual(result.note.id, reply.id)
        XCTAssertEqual(result.threadRootID, root.id)
        XCTAssertEqual(result.navigationNoteID, root.id)
        XCTAssertTrue(result.opensThread)

        let context = try fixture.database.fetchTimelineContext(around: result.navigationNoteID)
        XCTAssertEqual(context.selectedNoteID, root.id)
        XCTAssertTrue(context.notes.contains { $0.id == root.id })
        XCTAssertFalse(context.notes.contains { $0.id == reply.id })
        XCTAssertFalse(context.notes.contains(where: \.isReply))
    }

    @MainActor
    func testDebounceReplacementAndUnloadedResultNavigation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let oldest = try fixture.database.createNote(body: "old unique navigation needle")
        for index in 0...TimelineViewModel.pageSize {
            _ = try fixture.database.createNote(body: "recent replacement \(index)")
        }
        let model = TimelineViewModel(database: fixture.database)
        await model.loadInitialContent()
        XCTAssertFalse(model.notes.contains { $0.id == oldest.id })

        model.setSearchText("replacement")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.searchResults.isEmpty)

        model.setSearchText("needle")
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertTrue(model.isSearching)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.searchResults.map(\.id), [oldest.id])

        let result = try XCTUnwrap(model.searchResults.first)
        let revealed = await model.revealSearchResult(result)
        XCTAssertEqual(revealed?.id, oldest.id)
        XCTAssertTrue(model.notes.contains { $0.id == oldest.id })
        XCTAssertEqual(model.searchTargetNoteID, oldest.id)
        XCTAssertTrue(model.isShowingTimelineContext)

        let lastContextNote = try XCTUnwrap(model.notes.last)
        _ = await model.revealSearchResult(
            NoteSearchResult(note: lastContextNote, matchedTerms: ["recent"], relevance: nil)
        )
        XCTAssertTrue(model.isShowingTimelineContext)

        let newest = await model.returnToNewest()
        XCTAssertEqual(newest?.body, "recent replacement \(TimelineViewModel.pageSize)")
        XCTAssertFalse(model.isShowingTimelineContext)
        XCTAssertNil(model.searchTargetNoteID)
    }

    @MainActor
    func testSupersededNavigationFailuresDoNotOverwriteNewerState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let padding = String(repeating: "navigation padding ", count: 8_192)
        var createdNotes: [Note] = []
        for index in 0..<80 {
            createdNotes.append(
                try fixture.database.createNote(body: "stale navigation note \(index) \(padding)")
            )
        }

        let model = TimelineViewModel(database: fixture.database)
        await model.loadInitialContent()
        let loadedNewest = try XCTUnwrap(model.notes.last)
        XCTAssertFalse(model.notes.contains { $0.id == createdNotes[0].id })

        model.setSearchText("navigation")
        try await Task.sleep(nanoseconds: 600_000_000)
        let currentSearchResults = model.searchResults
        XCTAssertFalse(currentSearchResults.isEmpty)

        let corruptionQueue = try DatabaseQueue(
            path: fixture.rootURL
                .appendingPathComponent(ApplicationSupportDirectoryProvider.databaseFilename)
                .path
        )
        defer { try? corruptionQueue.close() }
        let invalidNeighborSortKey = createdNotes[1].sortKey
        try await corruptionQueue.write { database in
            try database.execute(
                sql: "UPDATE notes SET id = 'invalid-neighbor-id' WHERE sortKey = ?",
                arguments: [invalidNeighborSortKey]
            )
        }

        let staleReveal = Task {
            await model.revealSearchResult(
                NoteSearchResult(note: createdNotes[0], matchedTerms: ["navigation"], relevance: nil)
            )
        }
        await Task.yield()
        let newerReveal = await model.revealSearchResult(
            NoteSearchResult(note: loadedNewest, matchedTerms: ["navigation"], relevance: nil)
        )
        let staleRevealResult = await staleReveal.value
        XCTAssertEqual(newerReveal?.id, loadedNewest.id)
        XCTAssertNil(staleRevealResult)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.searchResults, currentSearchResults)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.searchTargetNoteID, loadedNewest.id)
        XCTAssertFalse(model.isShowingTimelineContext)

        let loadedOldest = try XCTUnwrap(model.notes.first)
        let invalidNewestPageSortKey = loadedOldest.sortKey
        try await corruptionQueue.write { database in
            try database.execute(
                sql: "UPDATE notes SET id = 'invalid-newest-page-id' WHERE sortKey = ?",
                arguments: [invalidNewestPageSortKey]
            )
        }

        let staleReturn = Task { await model.returnToNewest() }
        await Task.yield()
        _ = await model.revealSearchResult(
            NoteSearchResult(note: loadedNewest, matchedTerms: ["navigation"], relevance: nil)
        )
        let staleReturnResult = await staleReturn.value
        XCTAssertNil(staleReturnResult)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.searchTargetNoteID, loadedNewest.id)
        XCTAssertFalse(model.isShowingTimelineContext)
    }

    private func search(
        _ database: AppDatabase,
        text: String,
        filters: NoteSearchFilters = NoteSearchFilters(),
        sort: NoteSearchSort = .relevance
    ) throws -> NoteSearchResponse {
        try database.searchNotes(
            NoteSearchRequest(text: text, filters: filters, sort: sort)
        )
    }

    private func makeFixture() throws -> SearchDatabaseFixture {
        let rootURL = temporaryRoot()
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()
        return SearchDatabaseFixture(
            rootURL: rootURL,
            database: try AppDatabase(databaseURL: provider.databaseURL)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesSearchTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct SearchDatabaseFixture {
    let rootURL: URL
    let database: AppDatabase

    func cleanUp() {
        try? database.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
