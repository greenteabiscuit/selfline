import Darwin
import Foundation
import GRDB

final class AppDatabase: @unchecked Sendable {
    static let maximumPageSize = 200
    static let maximumSearchResultCount = 200
    static let linkPreviewCacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let linkPreviewRefreshFailureBackoff: TimeInterval = 24 * 60 * 60

    private let queue: DatabaseQueue
    private let databaseURL: URL
    private let databaseFileIdentity: DatabaseFileIdentity

    init(
        databaseURL: URL,
        migrator: DatabaseMigrator = DatabaseMigrations.makeMigrator()
    ) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        queue = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(queue)
        guard let identity = Self.databaseFileIdentity(at: databaseURL) else {
            try? queue.close()
            throw AppDatabaseError.databaseLocationChanged
        }
        databaseFileIdentity = identity
    }

    func verifyConnection() throws {
        let result = try queue.read { database in
            try Int.fetchOne(database, sql: "SELECT 1")
        }
        guard result == 1 else {
            throw AppDatabaseError.connectionVerificationFailed
        }
    }

    func verifyFTS5Availability() throws {
        try queue.writeWithoutTransaction { database in
            try database.execute(
                sql: "CREATE VIRTUAL TABLE temp.__fts5_verification USING fts5(content)"
            )
            defer {
                try? database.execute(sql: "DROP TABLE temp.__fts5_verification")
            }

            try database.execute(
                sql: "INSERT INTO temp.__fts5_verification (content) VALUES (?)",
                arguments: ["searchable archive"]
            )
            let matchCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM temp.__fts5_verification
                    WHERE __fts5_verification MATCH ?
                    """,
                arguments: ["searchable"]
            )
            guard matchCount == 1 else {
                throw AppDatabaseError.fts5VerificationFailed
            }
        }
    }

    func verifyIntegrityAndForeignKeys() throws {
        try queue.read { database in
            let integrity = try String.fetchAll(database, sql: "PRAGMA integrity_check")
            guard integrity == ["ok"] else {
                throw AppDatabaseError.integrityCheckFailed
            }
            guard try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw AppDatabaseError.foreignKeyCheckFailed
            }
        }
    }

    func inspectArchiveContents(includePortableNotes: Bool) throws -> DatabaseArchiveContents {
        guard Self.databaseFileIdentity(at: databaseURL) == databaseFileIdentity else {
            throw AppDatabaseError.databaseLocationChanged
        }
        let contents = try queue.read { database in
            try ArchiveDatabaseInspector.inspect(
                database: database,
                includePortableNotes: includePortableNotes
            )
        }
        guard Self.databaseFileIdentity(at: databaseURL) == databaseFileIdentity else {
            throw AppDatabaseError.databaseLocationChanged
        }
        return contents
    }

    func createNote(
        body: String,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        attachments: [NewAttachment] = []
    ) throws -> Note {
        try createNote(
            body: body,
            id: id,
            createdAt: createdAt,
            attachments: attachments,
            threadRootID: nil,
            consumesDraft: true
        )
    }

    func createReply(
        rootID: UUID,
        body: String,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        attachments: [NewAttachment] = []
    ) throws -> Note {
        try createNote(
            body: body,
            id: id,
            createdAt: createdAt,
            attachments: attachments,
            threadRootID: rootID,
            consumesDraft: false
        )
    }

    private func createNote(
        body: String,
        id: UUID,
        createdAt: Date,
        attachments: [NewAttachment],
        threadRootID: UUID?,
        consumesDraft: Bool
    ) throws -> Note {
        guard Self.hasVisibleText(body) || !attachments.isEmpty else {
            throw AppDatabaseError.emptyNote
        }
        guard Set(attachments.map(\.id)).count == attachments.count,
              Set(attachments.map(\.sortIndex)).count == attachments.count,
              attachments.allSatisfy({
                  !$0.originalFilename.isEmpty
                      && $0.sortIndex >= 0
                      && $0.blob.contentHash.count == 64
                      && $0.blob.byteSize >= 0
              }) else {
            throw AppDatabaseError.invalidAttachmentMetadata
        }

        return try queue.write { database in
            let suppliedAttachmentIDs = Set(attachments.map { $0.id.uuidString })
            if consumesDraft {
                let persistedDraftAttachmentIDs = Set(
                    try String.fetchAll(database, sql: "SELECT id FROM draft_attachments")
                )
                guard persistedDraftAttachmentIDs == suppliedAttachmentIDs else {
                    throw AppDatabaseError.draftAttachmentsChanged
                }
            } else {
                guard let threadRootID,
                      try Bool.fetchOne(
                        database,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM notes
                                WHERE id = ? AND threadRootID IS NULL AND deletedAt IS NULL
                            )
                            """,
                        arguments: [threadRootID.uuidString]
                      ) == true else {
                    throw AppDatabaseError.invalidThreadRoot
                }
            }

            try database.execute(
                sql: """
                    INSERT INTO notes (id, body, createdAt, threadRootID)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    id.uuidString,
                    body,
                    Self.encode(createdAt),
                    threadRootID?.uuidString
                ]
            )
            for attachment in attachments {
                try database.execute(
                    sql: """
                        INSERT INTO attachment_blobs (
                            id, contentHash, storedFilename, thumbnailFilename,
                            mediaType, byteSize, width, height, createdAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(contentHash) DO NOTHING
                        """,
                    arguments: [
                        attachment.blob.id.uuidString,
                        attachment.blob.contentHash,
                        attachment.blob.storedFilename,
                        attachment.blob.thumbnailFilename,
                        attachment.blob.mediaType,
                        attachment.blob.byteSize,
                        attachment.blob.width,
                        attachment.blob.height,
                        Self.encode(attachment.blob.createdAt)
                    ]
                )
                let storedBlob = try Self.fetchBlob(
                    contentHash: attachment.blob.contentHash,
                    from: database
                )
                guard Self.blobStorageMatches(storedBlob, attachment.blob) else {
                    throw AppDatabaseError.attachmentHashCollision
                }
                try database.execute(
                    sql: """
                        INSERT INTO attachments (
                            id, noteID, blobID, originalFilename, createdAt, sortIndex
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        attachment.id.uuidString,
                        id.uuidString,
                        storedBlob.id.uuidString,
                        attachment.originalFilename,
                        Self.encode(attachment.createdAt),
                        attachment.sortIndex
                    ]
                )
            }
            if consumesDraft {
                try database.execute(sql: "DELETE FROM drafts WHERE id = 1")
                for attachmentID in suppliedAttachmentIDs {
                    try database.execute(
                        sql: "DELETE FROM draft_attachments WHERE id = ?",
                        arguments: [attachmentID]
                    )
                }
            }
            return try Self.fetchNote(id: id, from: database)
        }
    }

    func fetchNotesPage(
        beforeSortKey: Int64? = nil,
        limit requestedLimit: Int = 50
    ) throws -> NotePage {
        try fetchPage(
            deleted: false,
            beforeSortKey: beforeSortKey,
            limit: requestedLimit
        )
    }

    func fetchTrashPage(
        beforeSortKey: Int64? = nil,
        limit requestedLimit: Int = 50
    ) throws -> NotePage {
        try fetchPage(
            deleted: true,
            beforeSortKey: beforeSortKey,
            limit: requestedLimit
        )
    }

    func searchNotes(_ request: NoteSearchRequest) throws -> NoteSearchResponse {
        guard request.limit > 0 else {
            throw AppDatabaseError.invalidPageSize
        }
        guard !request.filters.requestsFutureContent else {
            throw AppDatabaseError.unavailableSearchFilter
        }
        if let startDate = request.filters.startDate,
           let endDate = request.filters.endDateExclusive,
           startDate >= endDate {
            throw AppDatabaseError.invalidSearchDateRange
        }

        let parsedQuery = ParsedNoteSearchQuery.parse(request.text)
        let limit = min(request.limit, Self.maximumSearchResultCount)
        return try queue.read { database in
            let query = Self.makeSearchSQL(
                parsedQuery: parsedQuery,
                filters: request.filters,
                sort: request.sort
            )
            let totalCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM (\(query.selectionSQL))",
                arguments: query.arguments
            ) ?? 0
            let rows = try Row.fetchAll(
                database,
                sql: "\(query.selectionSQL) \(query.orderSQL) LIMIT ?",
                arguments: query.arguments + [limit]
            )
            let notes = try Self.notesWithAttachments(
                try rows.map(Self.note(from:)),
                from: database
            )
            return NoteSearchResponse(
                results: notes.enumerated().map { index, note in
                    NoteSearchResult(
                        note: note,
                        matchedTerms: parsedQuery.highlightedTerms,
                        relevance: rows[index]["relevance"]
                    )
                },
                totalCount: totalCount
            )
        }
    }

    func fetchTimelineContext(
        around noteID: UUID,
        radius requestedRadius: Int = 25
    ) throws -> TimelineContext {
        guard requestedRadius > 0 else {
            throw AppDatabaseError.invalidPageSize
        }
        let radius = min(requestedRadius, Self.maximumPageSize / 2)
        return try queue.read { database in
            let selected = try Self.fetchActiveRootNote(id: noteID, from: database)
            let columns = "id, body, createdAt, updatedAt, deletedAt, sortKey, threadRootID"
            let olderRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT \(columns)
                    FROM notes
                    WHERE deletedAt IS NULL AND threadRootID IS NULL AND sortKey < ?
                    ORDER BY sortKey DESC
                    LIMIT ?
                    """,
                arguments: [selected.sortKey, radius]
            )
            let newerRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT \(columns)
                    FROM notes
                    WHERE deletedAt IS NULL AND threadRootID IS NULL AND sortKey > ?
                    ORDER BY sortKey ASC
                    LIMIT ?
                    """,
                arguments: [selected.sortKey, radius]
            )
            let unhydratedOlderNotes = try olderRows.map(Self.note(from:)).reversed()
            let unhydratedNewerNotes = try newerRows.map(Self.note(from:))
            let hydrated = try Self.notesWithAttachments(
                Array(unhydratedOlderNotes) + [selected] + Array(unhydratedNewerNotes),
                from: database
            )
            let olderNotes = hydrated.prefix(unhydratedOlderNotes.count)
            let hydratedSelected = hydrated[unhydratedOlderNotes.count]
            let newerNotes = hydrated.dropFirst(unhydratedOlderNotes.count + 1)
            let oldestSortKey = olderNotes.first?.sortKey ?? selected.sortKey
            let hasOlder = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM notes
                        WHERE deletedAt IS NULL AND threadRootID IS NULL AND sortKey < ?
                    )
                    """,
                arguments: [oldestSortKey]
            ) ?? false
            let hasNewer = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM notes
                        WHERE deletedAt IS NULL AND threadRootID IS NULL AND sortKey > ?
                    )
                    """,
                arguments: [selected.sortKey]
            ) ?? false
            return TimelineContext(
                notes: Array(olderNotes) + [hydratedSelected] + Array(newerNotes),
                selectedNoteID: noteID,
                hasOlder: hasOlder,
                hasNewer: hasNewer
            )
        }
    }

    func fetchNote(id: UUID) throws -> Note {
        try queue.read { database in
            try Self.fetchNote(id: id, from: database)
        }
    }

    func fetchThread(rootID: UUID) throws -> NoteThread {
        try queue.read { database in
            let root = try Self.fetchActiveRootNote(id: rootID, from: database)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, body, createdAt, updatedAt, deletedAt, sortKey, threadRootID
                    FROM notes
                    WHERE threadRootID = ? AND deletedAt IS NULL
                    ORDER BY sortKey ASC
                    """,
                arguments: [rootID.uuidString]
            )
            let replies = try rows.map(Self.note(from:))
            let hydrated = try Self.notesWithAttachments([root] + replies, from: database)
            return NoteThread(root: hydrated[0], replies: Array(hydrated.dropFirst()))
        }
    }

    func fetchReplyCounts(rootIDs: [UUID]) throws -> [UUID: Int] {
        try queue.read { database in
            try Self.fetchReplyCounts(rootIDs: rootIDs, from: database)
        }
    }

    func editNote(id: UUID, body: String, updatedAt: Date = Date()) throws -> Note {
        return try queue.write { database in
            let hasAttachment = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM attachments WHERE noteID = ?)",
                arguments: [id.uuidString]
            ) ?? false
            guard Self.hasVisibleText(body) || hasAttachment else {
                throw AppDatabaseError.emptyNote
            }
            try database.execute(
                sql: """
                    UPDATE notes
                    SET body = ?, updatedAt = ?,
                        linkPreviewRevision = linkPreviewRevision + 1
                    WHERE id = ? AND deletedAt IS NULL
                    """,
                arguments: [body, Self.encode(updatedAt), id.uuidString]
            )
            guard database.changesCount == 1 else {
                throw AppDatabaseError.noteUnavailable
            }
            return try Self.fetchNote(id: id, from: database)
        }
    }

    func moveNoteToTrash(id: UUID, deletedAt: Date = Date()) throws -> Note {
        try queue.write { database in
            guard let target = try Row.fetchOne(
                database,
                sql: "SELECT threadRootID FROM notes WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString]
            ) else {
                throw AppDatabaseError.noteUnavailable
            }
            let encodedDeletedAt = Self.encode(deletedAt)
            let threadRootID: String? = target["threadRootID"]
            if threadRootID == nil {
                try database.execute(
                    sql: """
                        UPDATE notes
                        SET deletedAt = ?, deletedWithRoot = 0
                        WHERE id = ? AND deletedAt IS NULL
                        """,
                    arguments: [encodedDeletedAt, id.uuidString]
                )
                try database.execute(
                    sql: """
                        UPDATE notes
                        SET deletedAt = ?, deletedWithRoot = 1
                        WHERE threadRootID = ? AND deletedAt IS NULL
                        """,
                    arguments: [encodedDeletedAt, id.uuidString]
                )
            } else {
                try database.execute(
                    sql: """
                        UPDATE notes
                        SET deletedAt = ?, deletedWithRoot = 0
                        WHERE id = ? AND deletedAt IS NULL
                        """,
                    arguments: [encodedDeletedAt, id.uuidString]
                )
            }
            return try Self.fetchNote(id: id, from: database)
        }
    }

    func restoreNote(id: UUID) throws -> Note {
        try queue.write { database in
            guard let target = try Row.fetchOne(
                database,
                sql: "SELECT threadRootID, deletedAt FROM notes WHERE id = ? AND deletedAt IS NOT NULL",
                arguments: [id.uuidString]
            ) else {
                throw AppDatabaseError.noteUnavailable
            }
            let threadRootID: String? = target["threadRootID"]
            if let threadRootID {
                guard try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM notes
                            WHERE id = ? AND threadRootID IS NULL AND deletedAt IS NULL
                        )
                        """,
                    arguments: [threadRootID]
                ) == true else {
                    throw AppDatabaseError.invalidThreadRoot
                }
                try database.execute(
                    sql: """
                        UPDATE notes
                        SET deletedAt = NULL, deletedWithRoot = 0
                        WHERE id = ? AND deletedAt IS NOT NULL
                        """,
                    arguments: [id.uuidString]
                )
            } else {
                try database.execute(
                    sql: """
                        UPDATE notes
                        SET deletedAt = NULL, deletedWithRoot = 0
                        WHERE id = ? AND deletedAt IS NOT NULL
                        """,
                    arguments: [id.uuidString]
                )
                try database.execute(
                    sql: """
                        UPDATE notes
                        SET deletedAt = NULL, deletedWithRoot = 0
                        WHERE threadRootID = ? AND deletedWithRoot = 1
                        """,
                    arguments: [id.uuidString]
                )
            }
            return try Self.fetchNote(id: id, from: database)
        }
    }

    func permanentlyDeleteNote(id: UUID) throws -> PermanentlyDeletedManagedFiles {
        try queue.write { database in
            let blobs = try Self.fetchBlobs(
                sql: """
                    SELECT DISTINCT attachment_blobs.*
                    FROM attachment_blobs
                    JOIN attachments ON attachments.blobID = attachment_blobs.id
                    JOIN notes ON notes.id = attachments.noteID
                    WHERE (notes.id = ? OR notes.threadRootID = ?)
                    """,
                arguments: [id.uuidString, id.uuidString],
                from: database
            )
            let affectedPreviewKeys = try String.fetchAll(
                database,
                sql: """
                    SELECT link_previews.requestKey
                    FROM link_previews
                    JOIN notes ON notes.id = link_previews.noteID
                    WHERE notes.id = ? OR notes.threadRootID = ?
                    """,
                arguments: [id.uuidString, id.uuidString]
            )
            try database.execute(
                sql: "DELETE FROM notes WHERE id = ? AND deletedAt IS NOT NULL",
                arguments: [id.uuidString]
            )
            guard database.changesCount == 1 else {
                throw AppDatabaseError.noteUnavailable
            }
            var deletedBlobs: [AttachmentBlob] = []
            for blob in blobs {
                try database.execute(
                    sql: """
                        DELETE FROM attachment_blobs
                        WHERE id = ?
                          AND NOT EXISTS (
                              SELECT 1 FROM attachments WHERE blobID = attachment_blobs.id
                          )
                        """,
                    arguments: [blob.id.uuidString]
                )
                if database.changesCount == 1 {
                    deletedBlobs.append(blob)
                }
            }
            var previewImageFilenames: [String] = []
            for requestKey in Set(affectedPreviewKeys) {
                if let filename = try Self.deleteUnusedPreviewCache(
                    requestKey: requestKey,
                    from: database
                ) {
                    previewImageFilenames.append(filename)
                }
            }
            return PermanentlyDeletedManagedFiles(
                blobs: deletedBlobs,
                previewImageFilenames: previewImageFilenames
            )
        }
    }

    func automaticLinkPreviewsEnabled() throws -> Bool {
        try queue.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT automaticLinkPreviewsEnabled FROM app_settings WHERE id = 1"
            ) ?? false
        }
    }

    func setAutomaticLinkPreviewsEnabled(_ enabled: Bool) throws {
        try queue.write { database in
            try database.execute(
                sql: "UPDATE app_settings SET automaticLinkPreviewsEnabled = ? WHERE id = 1",
                arguments: [enabled]
            )
            guard database.changesCount == 1 else {
                throw AppDatabaseError.settingsUnavailable
            }
        }
    }

    func fetchLinkReconciliationSnapshots(
        afterSortKey: Int64?,
        limit requestedLimit: Int = 100
    ) throws -> [LinkPreviewReconciliationSnapshot] {
        guard requestedLimit > 0 else { throw AppDatabaseError.invalidPageSize }
        let limit = min(requestedLimit, Self.maximumPageSize)
        return try queue.read { database in
            let rows: [Row]
            if let afterSortKey {
                rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, body, sortKey, linkPreviewRevision
                        FROM notes
                        WHERE deletedAt IS NULL AND sortKey > ?
                        ORDER BY sortKey ASC
                        LIMIT ?
                        """,
                    arguments: [afterSortKey, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, body, sortKey, linkPreviewRevision
                        FROM notes
                        WHERE deletedAt IS NULL
                        ORDER BY sortKey ASC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
            }
            return try rows.map { row in
                let idString: String = row["id"]
                guard let noteID = UUID(uuidString: idString) else {
                    throw AppDatabaseError.invalidStoredNoteIdentifier
                }
                return LinkPreviewReconciliationSnapshot(
                    noteID: noteID,
                    body: row["body"],
                    sortKey: row["sortKey"],
                    revision: row["linkPreviewRevision"]
                )
            }
        }
    }

    func fetchLinkReconciliationSnapshot(
        noteID: UUID
    ) throws -> LinkPreviewReconciliationSnapshot? {
        try queue.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, body, sortKey, linkPreviewRevision
                    FROM notes
                    WHERE id = ? AND deletedAt IS NULL
                    """,
                arguments: [noteID.uuidString]
            ) else {
                return nil
            }
            return LinkPreviewReconciliationSnapshot(
                noteID: noteID,
                body: row["body"],
                sortKey: row["sortKey"],
                revision: row["linkPreviewRevision"]
            )
        }
    }

    func reconcileLinkPreviews(
        snapshot: LinkPreviewReconciliationSnapshot,
        detectedLinks: [DetectedLink],
        now: Date = Date()
    ) throws -> LinkPreviewReconciliationResult {
        try queue.write { database in
            guard let current = try Row.fetchOne(
                database,
                sql: """
                    SELECT body, linkPreviewRevision
                    FROM notes
                    WHERE id = ? AND deletedAt IS NULL
                    """,
                arguments: [snapshot.noteID.uuidString]
            ) else {
                return LinkPreviewReconciliationResult(
                    wasApplied: false,
                    changedNoteIDs: [],
                    unusedImageFilenames: []
                )
            }
            let currentBody: String = current["body"]
            let currentRevision: Int64 = current["linkPreviewRevision"]
            guard currentBody == snapshot.body,
                  currentRevision == snapshot.revision else {
                return LinkPreviewReconciliationResult(
                    wasApplied: false,
                    changedNoteIDs: [],
                    unusedImageFilenames: []
                )
            }

            let uniqueLinks = detectedLinks.reduce(into: [String: DetectedLink]()) { result, link in
                if result[link.requestKey] == nil {
                    result[link.requestKey] = link
                }
            }
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT requestKey FROM link_previews WHERE noteID = ?",
                arguments: [snapshot.noteID.uuidString]
            )
            let existingKeys = Set(rows.map { row -> String in row["requestKey"] })
            let removedKeys = existingKeys.subtracting(uniqueLinks.keys)
            let timestamp = Self.encode(now)

            for requestKey in removedKeys {
                try database.execute(
                    sql: "DELETE FROM link_previews WHERE noteID = ? AND requestKey = ?",
                    arguments: [snapshot.noteID.uuidString, requestKey]
                )
            }
            for (requestKey, link) in uniqueLinks {
                if existingKeys.contains(requestKey) {
                    try database.execute(
                        sql: """
                            UPDATE link_previews
                            SET originalURL = ?, updatedAt = ?, reconciledRevision = ?
                            WHERE noteID = ? AND requestKey = ?
                            """,
                        arguments: [
                            link.originalURL,
                            timestamp,
                            currentRevision,
                            snapshot.noteID.uuidString,
                            requestKey
                        ]
                    )
                } else {
                    let cache = try Row.fetchOne(
                        database,
                        sql: """
                            SELECT fetchedAt, retryAfter
                            FROM link_preview_cache
                            WHERE requestKey = ?
                            """,
                        arguments: [requestKey]
                    )
                    let cachedAt: Int64? = cache?["fetchedAt"]
                    let retryAfter: Int64? = cache?["retryAfter"]
                    let nextFetchAt = [
                        cachedAt.map { $0 + Int64(Self.linkPreviewCacheLifetime * 1_000) },
                        retryAfter
                    ].compactMap { $0 }.max()
                    try database.execute(
                        sql: """
                            INSERT INTO link_previews(
                                id, noteID, originalURL, requestKey, status,
                                failureReason, createdAt, updatedAt, nextFetchAt,
                                reconciledRevision
                            ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
                            """,
                        arguments: [
                            UUID().uuidString,
                            snapshot.noteID.uuidString,
                            link.originalURL,
                            requestKey,
                            cachedAt != nil ? LinkPreviewStatus.ready.rawValue
                                : LinkPreviewStatus.pending.rawValue,
                            timestamp,
                            timestamp,
                            nextFetchAt,
                            currentRevision
                        ]
                    )
                }
            }

            var unusedImages: [String] = []
            for requestKey in removedKeys {
                if let filename = try Self.deleteUnusedPreviewCache(
                    requestKey: requestKey,
                    from: database
                ) {
                    unusedImages.append(filename)
                }
            }
            return LinkPreviewReconciliationResult(
                wasApplied: true,
                changedNoteIDs: [snapshot.noteID],
                unusedImageFilenames: unusedImages
            )
        }
    }

    func fetchLinkPreviewWork(
        fetchBefore: Date,
        excludingRequestKeys: Set<String>,
        limit requestedLimit: Int = 20
    ) throws -> [LinkPreviewWorkItem] {
        guard requestedLimit > 0 else { throw AppDatabaseError.invalidPageSize }
        let limit = min(requestedLimit, Self.maximumPageSize)
        return try queue.read { database in
            var excludedArguments = StatementArguments()
            let exclusionSQL: String
            if excludingRequestKeys.isEmpty {
                exclusionSQL = ""
            } else {
                exclusionSQL = "AND link_previews.requestKey NOT IN (\(Array(repeating: "?", count: excludingRequestKeys.count).joined(separator: ", ")))"
                for key in excludingRequestKeys.sorted() {
                    excludedArguments += [key]
                }
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT link_previews.requestKey, MIN(link_previews.originalURL) AS originalURL
                    FROM link_previews
                    JOIN notes ON notes.id = link_previews.noteID
                    LEFT JOIN link_preview_cache
                        ON link_preview_cache.requestKey = link_previews.requestKey
                    WHERE notes.deletedAt IS NULL
                      AND link_previews.status != 'removed'
                      AND link_previews.reconciledRevision = notes.linkPreviewRevision
                      AND (
                          link_preview_cache.retryAfter IS NULL
                          OR link_preview_cache.retryAfter <= ?
                      )
                      AND (
                          link_previews.status = 'pending'
                          OR (link_previews.status = 'ready' AND (
                              link_preview_cache.requestKey IS NULL
                              OR link_previews.nextFetchAt IS NULL
                              OR link_previews.nextFetchAt <= ?
                          ))
                      )
                      \(exclusionSQL)
                    GROUP BY link_previews.requestKey
                    ORDER BY MIN(link_previews.createdAt), link_previews.requestKey
                    LIMIT ?
                    """,
                arguments: [Self.encode(fetchBefore), Self.encode(fetchBefore)]
                    + excludedArguments + [limit]
            )
            return rows.map {
                LinkPreviewWorkItem(
                    requestKey: $0["requestKey"],
                    originalURL: $0["originalURL"]
                )
            }
        }
    }

    func hasEligibleLinkPreviewWork(requestKey: String) throws -> Bool {
        try queue.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM link_previews
                        JOIN notes ON notes.id = link_previews.noteID
                        WHERE link_previews.requestKey = ?
                          AND link_previews.status != 'removed'
                          AND notes.deletedAt IS NULL
                          AND link_previews.reconciledRevision = notes.linkPreviewRevision
                    )
                    """,
                arguments: [requestKey]
            ) ?? false
        }
    }

    func markLinkPreviewFailure(
        requestKey: String,
        reason: String,
        now: Date = Date()
    ) throws -> Set<UUID> {
        try queue.write { database in
            let noteIDs = try Self.activePreviewNoteIDs(
                requestKey: requestKey,
                statuses: [.pending, .ready],
                from: database
            )
            guard !noteIDs.isEmpty else { return [] }
            try database.execute(
                sql: """
                    UPDATE link_previews
                    SET status = 'failed', failureReason = ?, updatedAt = ?, nextFetchAt = NULL
                    WHERE requestKey = ? AND status = 'pending'
                      AND EXISTS (
                          SELECT 1 FROM notes
                          WHERE notes.id = link_previews.noteID
                            AND notes.deletedAt IS NULL
                            AND notes.linkPreviewRevision = link_previews.reconciledRevision
                      )
                    """,
                arguments: [String(reason.prefix(500)), Self.encode(now), requestKey]
            )
            try database.execute(
                sql: """
                    UPDATE link_previews
                    SET nextFetchAt = ?
                    WHERE requestKey = ? AND status = 'ready'
                      AND EXISTS (
                          SELECT 1 FROM notes
                          WHERE notes.id = link_previews.noteID
                            AND notes.deletedAt IS NULL
                            AND notes.linkPreviewRevision = link_previews.reconciledRevision
                      )
                    """,
                arguments: [
                    Self.encode(now.addingTimeInterval(Self.linkPreviewRefreshFailureBackoff)),
                    requestKey
                ]
            )
            try database.execute(
                sql: "UPDATE link_preview_cache SET retryAfter = ? WHERE requestKey = ?",
                arguments: [
                    Self.encode(now.addingTimeInterval(Self.linkPreviewRefreshFailureBackoff)),
                    requestKey
                ]
            )
            return noteIDs
        }
    }

    func commitLinkPreviewMetadata(
        requestKey: String,
        metadata: LinkPreviewMetadata,
        localImageFilename: String?,
        fetchedAt: Date = Date()
    ) throws -> LinkPreviewCacheCommitResult {
        try queue.write { database in
            let enabled = try Bool.fetchOne(
                database,
                sql: "SELECT automaticLinkPreviewsEnabled FROM app_settings WHERE id = 1"
            ) ?? false
            let noteIDs = try Self.activePreviewNoteIDs(
                requestKey: requestKey,
                statuses: [.pending, .ready, .failed],
                from: database
            )
            guard enabled, !noteIDs.isEmpty else {
                return LinkPreviewCacheCommitResult(
                    changedNoteIDs: [],
                    replacedImageFilename: nil,
                    acceptedNewImage: false
                )
            }
            let oldImageFilename = try String.fetchOne(
                database,
                sql: "SELECT localImageFilename FROM link_preview_cache WHERE requestKey = ?",
                arguments: [requestKey]
            )
            try database.execute(
                sql: """
                    INSERT INTO link_preview_cache(
                        requestKey, canonicalURL, title, summary, imageURL,
                        localImageFilename, siteName, fetchedAt, retryAfter
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(requestKey) DO UPDATE SET
                        canonicalURL = excluded.canonicalURL,
                        title = excluded.title,
                        summary = excluded.summary,
                        imageURL = COALESCE(excluded.imageURL, link_preview_cache.imageURL),
                        localImageFilename = COALESCE(
                            excluded.localImageFilename,
                            link_preview_cache.localImageFilename
                        ),
                        siteName = excluded.siteName,
                        fetchedAt = excluded.fetchedAt,
                        retryAfter = NULL
                    """,
                arguments: [
                    requestKey,
                    metadata.canonicalURL,
                    metadata.title,
                    metadata.summary,
                    metadata.imageURL,
                    localImageFilename,
                    metadata.siteName,
                    Self.encode(fetchedAt)
                ]
            )
            try database.execute(
                sql: """
                    UPDATE link_previews
                    SET status = 'ready', failureReason = NULL,
                        updatedAt = ?, nextFetchAt = ?
                    WHERE requestKey = ? AND status != 'removed'
                      AND EXISTS (
                          SELECT 1 FROM notes
                          WHERE notes.id = link_previews.noteID
                            AND notes.deletedAt IS NULL
                            AND notes.linkPreviewRevision = link_previews.reconciledRevision
                      )
                    """,
                arguments: [
                    Self.encode(fetchedAt),
                    Self.encode(fetchedAt.addingTimeInterval(Self.linkPreviewCacheLifetime)),
                    requestKey
                ]
            )
            return LinkPreviewCacheCommitResult(
                changedNoteIDs: noteIDs,
                replacedImageFilename: localImageFilename != nil
                    && oldImageFilename != localImageFilename ? oldImageFilename : nil,
                acceptedNewImage: localImageFilename != nil
            )
        }
    }

    func retryLinkPreview(id: UUID, now: Date = Date()) throws -> UUID {
        try queue.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT link_previews.noteID, link_previews.requestKey
                    FROM link_previews JOIN notes ON notes.id = link_previews.noteID
                    WHERE link_previews.id = ? AND link_previews.status != 'removed'
                      AND notes.deletedAt IS NULL
                      AND link_previews.reconciledRevision = notes.linkPreviewRevision
                    """,
                arguments: [id.uuidString]
            ) else {
                throw AppDatabaseError.linkPreviewUnavailable
            }
            let noteIDString: String = row["noteID"]
            let requestKey: String = row["requestKey"]
            guard let noteID = UUID(uuidString: noteIDString) else {
                throw AppDatabaseError.invalidStoredNoteIdentifier
            }
            try database.execute(
                sql: """
                    UPDATE link_previews
                    SET status = 'pending', failureReason = NULL,
                        updatedAt = ?, nextFetchAt = NULL
                    WHERE id = ?
                    """,
                arguments: [Self.encode(now), id.uuidString]
            )
            try database.execute(
                sql: "UPDATE link_preview_cache SET retryAfter = NULL WHERE requestKey = ?",
                arguments: [requestKey]
            )
            return noteID
        }
    }

    func removeLinkPreview(id: UUID, now: Date = Date()) throws -> LinkPreviewRemovalResult {
        try queue.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT link_previews.noteID, link_previews.requestKey
                    FROM link_previews
                    JOIN notes ON notes.id = link_previews.noteID
                    WHERE link_previews.id = ?
                      AND link_previews.reconciledRevision = notes.linkPreviewRevision
                    """,
                arguments: [id.uuidString]
            ) else {
                throw AppDatabaseError.linkPreviewUnavailable
            }
            let noteIDString: String = row["noteID"]
            let requestKey: String = row["requestKey"]
            guard let noteID = UUID(uuidString: noteIDString) else {
                throw AppDatabaseError.invalidStoredNoteIdentifier
            }
            try database.execute(
                sql: """
                    UPDATE link_previews
                    SET status = 'removed', failureReason = NULL, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [Self.encode(now), id.uuidString]
            )
            return LinkPreviewRemovalResult(
                changedNoteID: noteID,
                unusedImageFilename: try Self.deleteUnusedPreviewCache(
                    requestKey: requestKey,
                    from: database
                )
            )
        }
    }

    func linkPreviewMaintenanceState() throws -> LinkPreviewMaintenanceState {
        try queue.read { database in
            LinkPreviewMaintenanceState(
                referencedImageFilenames: Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT localImageFilename
                            FROM link_preview_cache
                            WHERE localImageFilename IS NOT NULL
                            """
                    )
                )
            )
        }
    }

    func clearMissingLinkPreviewImages(_ filenames: Set<String>) throws -> Set<UUID> {
        guard !filenames.isEmpty else { return [] }
        return try queue.write { database in
            var arguments = StatementArguments()
            for filename in filenames.sorted() { arguments += [filename] }
            let placeholders = Array(repeating: "?", count: filenames.count).joined(separator: ", ")
            let noteIDStrings = try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT link_previews.noteID
                    FROM link_previews
                    JOIN link_preview_cache
                        ON link_preview_cache.requestKey = link_previews.requestKey
                    WHERE link_preview_cache.localImageFilename IN (\(placeholders))
                    """,
                arguments: arguments
            )
            try database.execute(
                sql: """
                    UPDATE link_preview_cache SET localImageFilename = NULL
                    WHERE localImageFilename IN (\(placeholders))
                    """,
                arguments: arguments
            )
            return Set(noteIDStrings.compactMap(UUID.init(uuidString:)))
        }
    }

    func saveDraft(body: String, updatedAt: Date = Date()) throws {
        try queue.write { database in
            if body.isEmpty {
                try database.execute(sql: "DELETE FROM drafts WHERE id = 1")
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO drafts (id, body, updatedAt)
                        VALUES (1, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            body = excluded.body,
                            updatedAt = excluded.updatedAt
                        """,
                    arguments: [body, Self.encode(updatedAt)]
                )
            }
        }
    }

    func loadDraft() throws -> Draft? {
        try queue.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT body, updatedAt FROM drafts WHERE id = 1"
            ) else {
                return nil
            }
            let body: String = row["body"]
            let updatedAt: Int64 = row["updatedAt"]
            return Draft(body: body, updatedAt: Self.decode(updatedAt))
        }
    }

    func discardDraft() throws -> [StagedAttachment] {
        try queue.write { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, originalFilename, stagingFilename, thumbnailStagingFilename,
                           mediaType, byteSize, width, height, contentHash, createdAt, sortIndex
                    FROM draft_attachments
                    ORDER BY sortIndex ASC, createdAt ASC
                    """
            )
            let attachments = try rows.map(Self.stagedAttachment(from:))
            try database.execute(sql: "DELETE FROM drafts WHERE id = 1")
            try database.execute(sql: "DELETE FROM draft_attachments")
            return attachments
        }
    }

    func saveStagedAttachment(_ attachment: StagedAttachment) throws {
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO draft_attachments (
                        id, originalFilename, stagingFilename, thumbnailStagingFilename,
                        mediaType, byteSize, width, height, contentHash, createdAt, sortIndex
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        originalFilename = excluded.originalFilename,
                        stagingFilename = excluded.stagingFilename,
                        thumbnailStagingFilename = excluded.thumbnailStagingFilename,
                        mediaType = excluded.mediaType,
                        byteSize = excluded.byteSize,
                        width = excluded.width,
                        height = excluded.height,
                        contentHash = excluded.contentHash,
                        createdAt = excluded.createdAt,
                        sortIndex = excluded.sortIndex
                    """,
                arguments: [
                    attachment.id.uuidString,
                    attachment.originalFilename,
                    attachment.stagingFilename,
                    attachment.thumbnailStagingFilename,
                    attachment.mediaType,
                    attachment.byteSize,
                    attachment.width,
                    attachment.height,
                    attachment.contentHash,
                    Self.encode(attachment.createdAt),
                    attachment.sortIndex
                ]
            )
        }
    }

    func fetchStagedAttachments() throws -> [StagedAttachment] {
        try queue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, originalFilename, stagingFilename, thumbnailStagingFilename,
                           mediaType, byteSize, width, height, contentHash, createdAt, sortIndex
                    FROM draft_attachments
                    ORDER BY sortIndex ASC, createdAt ASC
                    """
            )
            return try rows.map(Self.stagedAttachment(from:))
        }
    }

    func deleteStagedAttachment(id: UUID) throws {
        try queue.write { database in
            try database.execute(
                sql: "DELETE FROM draft_attachments WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func fetchAttachmentBlob(contentHash: String) throws -> AttachmentBlob? {
        try queue.read { database in
            try Self.fetchOptionalBlob(contentHash: contentHash, from: database)
        }
    }

    func fetchAttachmentBlobReferences() throws -> [AttachmentBlobReference] {
        try queue.read { database in
            let blobs = try Self.fetchBlobs(
                sql: "SELECT * FROM attachment_blobs ORDER BY createdAt, id",
                from: database
            )
            return try blobs.map { blob in
                let filenames = try String.fetchAll(
                    database,
                    sql: """
                        SELECT attachments.originalFilename
                        FROM attachments
                        WHERE attachments.blobID = ?
                        ORDER BY attachments.createdAt, attachments.id
                        """,
                    arguments: [blob.id.uuidString]
                )
                return AttachmentBlobReference(blob: blob, originalFilenames: filenames)
            }
        }
    }

    func createBackupSnapshot(
        at destinationURL: URL,
        progress: @escaping @Sendable (Double) throws -> Void = { _ in }
    ) throws {
        let destination = try DatabaseQueue(path: destinationURL.path)
        do {
            try queue.backup(to: destination, pagesPerStep: 256) { state in
                let fraction: Double
                if state.totalPageCount > 0 {
                    fraction = Double(state.completedPageCount) / Double(state.totalPageCount)
                } else {
                    fraction = state.isCompleted ? 1 : 0
                }
                try progress(min(max(fraction, 0), 1))
            }
            try destination.close()
        } catch {
            try? destination.close()
            throw error
        }
    }

    func close() throws {
        try queue.close()
    }

    private func fetchPage(
        deleted: Bool,
        beforeSortKey: Int64?,
        limit requestedLimit: Int
    ) throws -> NotePage {
        guard requestedLimit > 0 else {
            throw AppDatabaseError.invalidPageSize
        }
        let limit = min(requestedLimit, Self.maximumPageSize)

        return try queue.read { database in
            let deletionPredicate = deleted
                ? """
                    deletedAt IS NOT NULL AND (
                        threadRootID IS NULL OR EXISTS (
                            SELECT 1 FROM notes AS root
                            WHERE root.id = notes.threadRootID
                              AND root.deletedAt IS NULL
                        )
                    )
                    """
                : "deletedAt IS NULL AND threadRootID IS NULL"
            let rows: [Row]
            if let beforeSortKey {
                rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, body, createdAt, updatedAt, deletedAt, sortKey, threadRootID
                        FROM notes
                        WHERE \(deletionPredicate) AND sortKey < ?
                        ORDER BY sortKey DESC
                        LIMIT ?
                        """,
                    arguments: [beforeSortKey, limit + 1]
                )
            } else {
                rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, body, createdAt, updatedAt, deletedAt, sortKey, threadRootID
                        FROM notes
                        WHERE \(deletionPredicate)
                        ORDER BY sortKey DESC
                        LIMIT ?
                        """,
                    arguments: [limit + 1]
                )
            }

            let hasOlder = rows.count > limit
            let unhydratedNotes = Array(try rows.prefix(limit).map(Self.note(from:)).reversed())
            return NotePage(
                notes: try Self.notesWithAttachments(unhydratedNotes, from: database),
                hasOlder: hasOlder
            )
        }
    }

    private static func fetchNote(id: UUID, from database: Database) throws -> Note {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT id, body, createdAt, updatedAt, deletedAt, sortKey, threadRootID
                FROM notes
                WHERE id = ?
                """,
            arguments: [id.uuidString]
        ) else {
            throw AppDatabaseError.noteUnavailable
        }
        return try notesWithAttachments([note(from: row)], from: database)[0]
    }

    private static func fetchActiveRootNote(id: UUID, from database: Database) throws -> Note {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT id, body, createdAt, updatedAt, deletedAt, sortKey, threadRootID
                FROM notes
                WHERE id = ? AND deletedAt IS NULL AND threadRootID IS NULL
                """,
            arguments: [id.uuidString]
        ) else {
            throw AppDatabaseError.noteUnavailable
        }
        return try note(from: row)
    }

    private static func makeSearchSQL(
        parsedQuery: ParsedNoteSearchQuery,
        filters: NoteSearchFilters,
        sort: NoteSearchSort
    ) -> (selectionSQL: String, orderSQL: String, arguments: StatementArguments) {
        var predicates = ["notes.deletedAt IS NULL"]
        var arguments = StatementArguments()
        let usesFTS = parsedQuery.matchExpression != nil
        if let matchExpression = parsedQuery.matchExpression {
            predicates.append("note_search MATCH ?")
            arguments += [matchExpression]
        }
        for literal in parsedQuery.literalTerms {
            predicates.append("""
                (instr(notes.body, ?) > 0 OR EXISTS (
                    SELECT 1
                    FROM attachments
                    WHERE attachments.noteID = notes.id
                      AND instr(attachments.originalFilename, ?) > 0
                ) OR EXISTS (
                    SELECT 1
                    FROM link_previews
                    LEFT JOIN link_preview_cache
                        ON link_preview_cache.requestKey = link_previews.requestKey
                    WHERE link_previews.noteID = notes.id
                      AND link_previews.status != 'removed'
                      AND link_previews.reconciledRevision = notes.linkPreviewRevision
                      AND (
                          instr(link_previews.originalURL, ?) > 0
                          OR instr(COALESCE(link_preview_cache.title, ''), ?) > 0
                          OR instr(COALESCE(link_preview_cache.summary, ''), ?) > 0
                          OR instr(COALESCE(link_preview_cache.siteName, ''), ?) > 0
                      )
                ))
                """)
            arguments += [literal, literal, literal, literal, literal, literal]
        }
        if let startDate = filters.startDate {
            predicates.append("notes.createdAt >= ?")
            arguments += [encode(startDate)]
        }
        if let endDate = filters.endDateExclusive {
            predicates.append("notes.createdAt < ?")
            arguments += [encode(endDate)]
        }
        if filters.hasAttachment {
            predicates.append("EXISTS (SELECT 1 FROM attachments WHERE attachments.noteID = notes.id)")
        }
        if filters.hasImage {
            predicates.append("""
                EXISTS (
                    SELECT 1
                    FROM attachments
                    JOIN attachment_blobs ON attachment_blobs.id = attachments.blobID
                    WHERE attachments.noteID = notes.id
                      AND attachment_blobs.width IS NOT NULL
                      AND attachment_blobs.height IS NOT NULL
                      AND attachment_blobs.thumbnailFilename IS NOT NULL
                )
                """)
        }
        if filters.hasLink {
            predicates.append(
                """
                EXISTS (
                    SELECT 1 FROM link_previews
                    WHERE link_previews.noteID = notes.id
                      AND link_previews.reconciledRevision = notes.linkPreviewRevision
                )
                """
            )
        }

        let relevance = usesFTS ? "bm25(note_search)" : "NULL"
        let from = usesFTS
            ? "note_search JOIN notes ON notes.sortKey = note_search.rowid"
            : "notes"
        let selectionSQL = """
            SELECT notes.id, notes.body, notes.createdAt, notes.updatedAt,
                   notes.deletedAt, notes.sortKey, notes.threadRootID,
                   \(relevance) AS relevance
            FROM \(from)
            WHERE \(predicates.joined(separator: " AND "))
            """
        let orderSQL = switch sort {
        case .relevance where usesFTS:
            "ORDER BY relevance ASC, notes.sortKey DESC"
        case .oldest:
            "ORDER BY notes.createdAt ASC, notes.sortKey ASC"
        default:
            "ORDER BY notes.createdAt DESC, notes.sortKey DESC"
        }
        return (selectionSQL, orderSQL, arguments)
    }

    private static func note(from row: Row) throws -> Note {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw AppDatabaseError.invalidStoredNoteIdentifier
        }
        let body: String = row["body"]
        let createdAt: Int64 = row["createdAt"]
        let updatedAt: Int64? = row["updatedAt"]
        let deletedAt: Int64? = row["deletedAt"]
        let sortKey: Int64 = row["sortKey"]
        let threadRootIDString: String? = row["threadRootID"]
        let threadRootID: UUID?
        if let threadRootIDString {
            guard let parsed = UUID(uuidString: threadRootIDString) else {
                throw AppDatabaseError.invalidStoredNoteIdentifier
            }
            threadRootID = parsed
        } else {
            threadRootID = nil
        }
        return Note(
            id: id,
            body: body,
            createdAt: decode(createdAt),
            updatedAt: updatedAt.map(decode),
            deletedAt: deletedAt.map(decode),
            sortKey: sortKey,
            threadRootID: threadRootID
        )
    }

    private static func notesWithAttachments(
        _ notes: [Note],
        from database: Database
    ) throws -> [Note] {
        guard !notes.isEmpty else { return [] }
        var arguments = StatementArguments()
        for note in notes {
            arguments += [note.id.uuidString]
        }
        let placeholders = Array(repeating: "?", count: notes.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT attachments.id AS attachmentID,
                       attachments.noteID,
                       attachments.originalFilename,
                       attachments.createdAt AS attachmentCreatedAt,
                       attachments.sortIndex,
                       attachment_blobs.contentHash,
                       attachment_blobs.storedFilename,
                       attachment_blobs.thumbnailFilename,
                       attachment_blobs.mediaType,
                       attachment_blobs.byteSize,
                       attachment_blobs.width,
                       attachment_blobs.height
                FROM attachments
                JOIN attachment_blobs ON attachment_blobs.id = attachments.blobID
                WHERE attachments.noteID IN (\(placeholders))
                ORDER BY attachments.noteID, attachments.sortIndex
                """,
            arguments: arguments
        )
        let attachments = try rows.map(attachment(from:))
        let attachmentsByNote = Dictionary(grouping: attachments, by: \.noteID)
        let previewRows = try Row.fetchAll(
            database,
            sql: """
                SELECT link_previews.id AS previewID,
                       link_previews.noteID,
                       link_previews.originalURL,
                       link_previews.requestKey,
                       link_previews.status,
                       link_previews.failureReason,
                       link_preview_cache.canonicalURL,
                       link_preview_cache.title,
                       link_preview_cache.summary,
                       link_preview_cache.imageURL,
                       link_preview_cache.localImageFilename,
                       link_preview_cache.siteName,
                       link_preview_cache.fetchedAt
                FROM link_previews
                JOIN notes ON notes.id = link_previews.noteID
                LEFT JOIN link_preview_cache
                    ON link_preview_cache.requestKey = link_previews.requestKey
                WHERE link_previews.noteID IN (\(placeholders))
                  AND link_previews.reconciledRevision = notes.linkPreviewRevision
                ORDER BY link_previews.noteID, link_previews.createdAt, link_previews.id
                """,
            arguments: arguments
        )
        let previews = try previewRows.map(linkPreview(from:))
        let previewsByNote = Dictionary(grouping: previews, by: \.noteID)
        let replyCountsByRoot = try fetchReplyCounts(
            rootIDs: notes.filter { !$0.isReply }.map(\.id),
            from: database
        )
        return notes.map { note in
            Note(
                id: note.id,
                body: note.body,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                deletedAt: note.deletedAt,
                sortKey: note.sortKey,
                threadRootID: note.threadRootID,
                replyCount: replyCountsByRoot[note.id] ?? 0,
                attachments: attachmentsByNote[note.id] ?? [],
                linkPreviews: previewsByNote[note.id] ?? []
            )
        }
    }

    private static func fetchReplyCounts(
        rootIDs: [UUID],
        from database: Database
    ) throws -> [UUID: Int] {
        let uniqueRootIDs = Array(Set(rootIDs))
        guard !uniqueRootIDs.isEmpty else { return [:] }
        var arguments = StatementArguments()
        for rootID in uniqueRootIDs {
            arguments += [rootID.uuidString]
        }
        let placeholders = Array(repeating: "?", count: uniqueRootIDs.count)
            .joined(separator: ", ")
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT threadRootID, COUNT(*) AS replyCount
                FROM notes
                WHERE threadRootID IN (\(placeholders)) AND deletedAt IS NULL
                GROUP BY threadRootID
                """,
            arguments: arguments
        )
        var counts = Dictionary(uniqueKeysWithValues: uniqueRootIDs.map { ($0, 0) })
        for row in rows {
            let rootIDString: String = row["threadRootID"]
            guard let rootID = UUID(uuidString: rootIDString) else {
                throw AppDatabaseError.invalidStoredNoteIdentifier
            }
            counts[rootID] = row["replyCount"]
        }
        return counts
    }

    private static func linkPreview(from row: Row) throws -> LinkPreview {
        let idString: String = row["previewID"]
        let noteIDString: String = row["noteID"]
        let statusString: String = row["status"]
        guard let id = UUID(uuidString: idString),
              let noteID = UUID(uuidString: noteIDString),
              let status = LinkPreviewStatus(rawValue: statusString) else {
            throw AppDatabaseError.invalidStoredLinkPreview
        }
        let fetchedAt: Int64? = row["fetchedAt"]
        return LinkPreview(
            id: id,
            noteID: noteID,
            originalURL: row["originalURL"],
            requestKey: row["requestKey"],
            status: status,
            canonicalURL: row["canonicalURL"],
            title: row["title"],
            summary: row["summary"],
            imageURL: row["imageURL"],
            localImageFilename: row["localImageFilename"],
            siteName: row["siteName"],
            failureReason: row["failureReason"],
            fetchedAt: fetchedAt.map(decode)
        )
    }

    private static func activePreviewNoteIDs(
        requestKey: String,
        statuses: Set<LinkPreviewStatus>,
        from database: Database
    ) throws -> Set<UUID> {
        var arguments = StatementArguments([requestKey])
        for status in statuses.sorted(by: { $0.rawValue < $1.rawValue }) {
            arguments += [status.rawValue]
        }
        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        let values = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT link_previews.noteID
                FROM link_previews
                JOIN notes ON notes.id = link_previews.noteID
                WHERE link_previews.requestKey = ?
                  AND link_previews.status IN (\(placeholders))
                  AND notes.deletedAt IS NULL
                  AND link_previews.reconciledRevision = notes.linkPreviewRevision
                """,
            arguments: arguments
        )
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    private static func deleteUnusedPreviewCache(
        requestKey: String,
        from database: Database
    ) throws -> String? {
        let hasReference = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM link_previews
                    WHERE requestKey = ? AND status != 'removed'
                )
                """,
            arguments: [requestKey]
        ) ?? false
        guard !hasReference else { return nil }
        let filename = try String.fetchOne(
            database,
            sql: "SELECT localImageFilename FROM link_preview_cache WHERE requestKey = ?",
            arguments: [requestKey]
        )
        try database.execute(
            sql: "DELETE FROM link_preview_cache WHERE requestKey = ?",
            arguments: [requestKey]
        )
        return filename
    }

    private static func attachment(from row: Row) throws -> Attachment {
        let idString: String = row["attachmentID"]
        let noteIDString: String = row["noteID"]
        guard let id = UUID(uuidString: idString),
              let noteID = UUID(uuidString: noteIDString) else {
            throw AppDatabaseError.invalidStoredAttachmentIdentifier
        }
        let createdAt: Int64 = row["attachmentCreatedAt"]
        return Attachment(
            id: id,
            noteID: noteID,
            originalFilename: row["originalFilename"],
            mediaType: row["mediaType"],
            byteSize: row["byteSize"],
            width: row["width"],
            height: row["height"],
            contentHash: row["contentHash"],
            createdAt: decode(createdAt),
            sortIndex: row["sortIndex"],
            storedFilename: row["storedFilename"],
            thumbnailFilename: row["thumbnailFilename"]
        )
    }

    private static func stagedAttachment(from row: Row) throws -> StagedAttachment {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw AppDatabaseError.invalidStoredAttachmentIdentifier
        }
        let createdAt: Int64 = row["createdAt"]
        return StagedAttachment(
            id: id,
            originalFilename: row["originalFilename"],
            stagingFilename: row["stagingFilename"],
            thumbnailStagingFilename: row["thumbnailStagingFilename"],
            mediaType: row["mediaType"],
            byteSize: row["byteSize"],
            width: row["width"],
            height: row["height"],
            contentHash: row["contentHash"],
            createdAt: decode(createdAt),
            sortIndex: row["sortIndex"]
        )
    }

    private static func fetchOptionalBlob(
        contentHash: String,
        from database: Database
    ) throws -> AttachmentBlob? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM attachment_blobs WHERE contentHash = ?",
            arguments: [contentHash]
        ) else {
            return nil
        }
        return try blob(from: row)
    }

    private static func fetchBlob(
        contentHash: String,
        from database: Database
    ) throws -> AttachmentBlob {
        guard let blob = try fetchOptionalBlob(contentHash: contentHash, from: database) else {
            throw AppDatabaseError.invalidAttachmentMetadata
        }
        return blob
    }

    private static func fetchBlobs(
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        from database: Database
    ) throws -> [AttachmentBlob] {
        try Row.fetchAll(database, sql: sql, arguments: arguments).map(blob(from:))
    }

    private static func blob(from row: Row) throws -> AttachmentBlob {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw AppDatabaseError.invalidStoredAttachmentIdentifier
        }
        let createdAt: Int64 = row["createdAt"]
        return AttachmentBlob(
            id: id,
            contentHash: row["contentHash"],
            storedFilename: row["storedFilename"],
            thumbnailFilename: row["thumbnailFilename"],
            mediaType: row["mediaType"],
            byteSize: row["byteSize"],
            width: row["width"],
            height: row["height"],
            createdAt: decode(createdAt)
        )
    }

    private static func blobStorageMatches(
        _ lhs: AttachmentBlob,
        _ rhs: AttachmentBlob
    ) -> Bool {
        lhs.contentHash == rhs.contentHash
            && lhs.storedFilename == rhs.storedFilename
            && lhs.thumbnailFilename == rhs.thumbnailFilename
            && lhs.mediaType == rhs.mediaType
            && lhs.byteSize == rhs.byteSize
            && lhs.width == rhs.width
            && lhs.height == rhs.height
    }

    private static func hasVisibleText(_ body: String) -> Bool {
        body.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func databaseFileIdentity(at url: URL) -> DatabaseFileIdentity? {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        guard result == 0, information.st_mode & S_IFMT == S_IFREG else { return nil }
        return DatabaseFileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func encode(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func decode(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

private struct DatabaseFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

enum AppDatabaseError: LocalizedError, Equatable {
    case attachmentHashCollision
    case connectionVerificationFailed
    case databaseLocationChanged
    case draftAttachmentsChanged
    case emptyNote
    case fts5VerificationFailed
    case foreignKeyCheckFailed
    case integrityCheckFailed
    case invalidAttachmentMetadata
    case invalidPageSize
    case invalidSearchDateRange
    case invalidStoredAttachmentIdentifier
    case invalidStoredLinkPreview
    case invalidStoredNoteIdentifier
    case invalidThreadRoot
    case linkPreviewUnavailable
    case noteUnavailable
    case settingsUnavailable
    case unavailableSearchFilter

    var errorDescription: String? {
        switch self {
        case .attachmentHashCollision:
            "Attachment bytes or metadata conflict with an existing content hash. No note was saved."
        case .connectionVerificationFailed:
            "The local database did not respond to a health check."
        case .databaseLocationChanged:
            "The local database file changed at its expected location. Quit and reopen the app before continuing."
        case .draftAttachmentsChanged:
            "The recoverable attachment draft changed before send. No note was saved; reload the draft and retry."
        case .emptyNote:
            "A note must contain text other than spaces or line breaks, or have an attachment."
        case .fts5VerificationFailed:
            "SQLite FTS5 is unavailable or did not return the expected result."
        case .foreignKeyCheckFailed:
            "The local database contains broken relationships."
        case .integrityCheckFailed:
            "The local database did not pass SQLite integrity checks."
        case .invalidAttachmentMetadata:
            "Attachment metadata is incomplete or invalid."
        case .invalidPageSize:
            "The requested note page size must be greater than zero."
        case .invalidSearchDateRange:
            "The search start date must be earlier than the end date."
        case .invalidStoredAttachmentIdentifier:
            "A stored attachment has an invalid identifier."
        case .invalidStoredLinkPreview:
            "Stored link-preview metadata is invalid."
        case .invalidStoredNoteIdentifier:
            "A stored note has an invalid identifier."
        case .invalidThreadRoot:
            "Replies must belong directly to an active root note."
        case .linkPreviewUnavailable:
            "The link preview no longer exists or is not available for that action."
        case .noteUnavailable:
            "The note no longer exists or is not available for that action."
        case .settingsUnavailable:
            "Link preview settings could not be updated."
        case .unavailableSearchFilter:
            "The link filter is unavailable until link previews are implemented."
        }
    }
}
