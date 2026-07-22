import GRDB

enum DatabaseMigrations {
    static let identifiers = [
        "v1_create_notes_and_drafts",
        "v2_create_note_search",
        "v3_create_managed_attachments",
        "v4_index_attachment_filenames",
        "v5_create_link_previews_and_index_metadata",
        "v6_create_note_threads"
    ]

    static var currentSchemaVersion: Int { identifiers.count }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(identifiers[0]) { database in
            try database.execute(sql: """
                CREATE TABLE notes (
                    sortKey INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    body TEXT NOT NULL CHECK (length(body) > 0),
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER,
                    deletedAt INTEGER
                );

                CREATE INDEX notes_active_sortKey
                    ON notes(sortKey)
                    WHERE deletedAt IS NULL;

                CREATE INDEX notes_deleted_sortKey
                    ON notes(sortKey)
                    WHERE deletedAt IS NOT NULL;

                CREATE TABLE drafts (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    body TEXT NOT NULL,
                    updatedAt INTEGER NOT NULL
                );
                """)
        }
        migrator.registerMigration(identifiers[1]) { database in
            try database.execute(sql: """
                CREATE VIRTUAL TABLE note_search USING fts5(
                    noteID UNINDEXED,
                    body,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                INSERT INTO note_search(rowid, noteID, body)
                    SELECT sortKey, id, body
                    FROM notes
                    WHERE deletedAt IS NULL;

                CREATE TRIGGER notes_search_insert
                AFTER INSERT ON notes
                WHEN new.deletedAt IS NULL
                BEGIN
                    INSERT INTO note_search(rowid, noteID, body)
                    VALUES (new.sortKey, new.id, new.body);
                END;

                CREATE TRIGGER notes_search_update
                AFTER UPDATE OF body, deletedAt ON notes
                BEGIN
                    DELETE FROM note_search WHERE rowid = old.sortKey;
                    INSERT INTO note_search(rowid, noteID, body)
                        SELECT new.sortKey, new.id, new.body
                        WHERE new.deletedAt IS NULL;
                END;

                CREATE TRIGGER notes_search_delete
                AFTER DELETE ON notes
                BEGIN
                    DELETE FROM note_search WHERE rowid = old.sortKey;
                END;
                """)
        }
        migrator.registerMigration(identifiers[2]) { database in
            let oldSequence = try Int64.fetchOne(
                database,
                sql: "SELECT seq FROM sqlite_sequence WHERE name = 'notes'"
            ) ?? 0

            try database.execute(sql: """
                DROP TRIGGER IF EXISTS notes_search_insert;
                DROP TRIGGER IF EXISTS notes_search_update;
                DROP TRIGGER IF EXISTS notes_search_delete;
                DROP TABLE IF EXISTS note_search;

                ALTER TABLE notes RENAME TO notes_v2;

                CREATE TABLE notes (
                    sortKey INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    body TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER,
                    deletedAt INTEGER
                );

                INSERT INTO notes(sortKey, id, body, createdAt, updatedAt, deletedAt)
                    SELECT sortKey, id, body, createdAt, updatedAt, deletedAt
                    FROM notes_v2;

                DROP TABLE notes_v2;

                CREATE INDEX notes_active_sortKey
                    ON notes(sortKey)
                    WHERE deletedAt IS NULL;

                CREATE INDEX notes_deleted_sortKey
                    ON notes(sortKey)
                    WHERE deletedAt IS NOT NULL;

                CREATE TABLE attachment_blobs (
                    id TEXT PRIMARY KEY,
                    contentHash TEXT NOT NULL UNIQUE CHECK (length(contentHash) = 64),
                    storedFilename TEXT NOT NULL UNIQUE,
                    thumbnailFilename TEXT UNIQUE,
                    mediaType TEXT NOT NULL,
                    byteSize INTEGER NOT NULL CHECK (byteSize >= 0),
                    width INTEGER CHECK (width > 0),
                    height INTEGER CHECK (height > 0),
                    createdAt INTEGER NOT NULL,
                    CHECK ((width IS NULL AND height IS NULL)
                        OR (width IS NOT NULL AND height IS NOT NULL))
                );

                CREATE TABLE attachments (
                    id TEXT PRIMARY KEY,
                    noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    blobID TEXT NOT NULL REFERENCES attachment_blobs(id) ON DELETE RESTRICT,
                    originalFilename TEXT NOT NULL CHECK (length(originalFilename) > 0),
                    createdAt INTEGER NOT NULL,
                    sortIndex INTEGER NOT NULL CHECK (sortIndex >= 0),
                    UNIQUE(noteID, sortIndex)
                );

                CREATE INDEX attachments_noteID ON attachments(noteID, sortIndex);
                CREATE INDEX attachments_blobID ON attachments(blobID);

                CREATE TABLE draft_attachments (
                    id TEXT PRIMARY KEY,
                    originalFilename TEXT NOT NULL CHECK (length(originalFilename) > 0),
                    stagingFilename TEXT NOT NULL UNIQUE,
                    thumbnailStagingFilename TEXT UNIQUE,
                    mediaType TEXT NOT NULL,
                    byteSize INTEGER NOT NULL CHECK (byteSize >= 0),
                    width INTEGER CHECK (width > 0),
                    height INTEGER CHECK (height > 0),
                    contentHash TEXT NOT NULL CHECK (length(contentHash) = 64),
                    createdAt INTEGER NOT NULL,
                    sortIndex INTEGER NOT NULL CHECK (sortIndex >= 0),
                    CHECK ((width IS NULL AND height IS NULL)
                        OR (width IS NOT NULL AND height IS NOT NULL))
                );
                """)

            let largestSortKey = try Int64.fetchOne(
                database,
                sql: "SELECT MAX(sortKey) FROM notes"
            ) ?? 0
            try database.execute(
                sql: "DELETE FROM sqlite_sequence WHERE name = 'notes'"
            )
            try database.execute(
                sql: "INSERT INTO sqlite_sequence(name, seq) VALUES ('notes', ?)",
                arguments: [max(oldSequence, largestSortKey)]
            )
        }
        migrator.registerMigration(identifiers[3]) { database in
            try database.execute(sql: """
                CREATE VIRTUAL TABLE note_search USING fts5(
                    noteID UNINDEXED,
                    body,
                    attachmentFilenames,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                INSERT INTO note_search(rowid, noteID, body, attachmentFilenames)
                    SELECT notes.sortKey, notes.id, notes.body,
                           COALESCE((
                               SELECT group_concat(attachments.originalFilename, ' ')
                               FROM attachments
                               WHERE attachments.noteID = notes.id
                           ), '')
                    FROM notes
                    WHERE notes.deletedAt IS NULL;

                CREATE TRIGGER notes_search_insert
                AFTER INSERT ON notes
                WHEN new.deletedAt IS NULL
                BEGIN
                    INSERT INTO note_search(rowid, noteID, body, attachmentFilenames)
                    VALUES (new.sortKey, new.id, new.body, '');
                END;

                CREATE TRIGGER notes_search_update
                AFTER UPDATE OF body, deletedAt ON notes
                BEGIN
                    DELETE FROM note_search WHERE rowid = old.sortKey;
                    INSERT INTO note_search(rowid, noteID, body, attachmentFilenames)
                        SELECT new.sortKey, new.id, new.body,
                               COALESCE((
                                   SELECT group_concat(attachments.originalFilename, ' ')
                                   FROM attachments
                                   WHERE attachments.noteID = new.id
                               ), '')
                        WHERE new.deletedAt IS NULL;
                END;

                CREATE TRIGGER notes_search_delete
                AFTER DELETE ON notes
                BEGIN
                    DELETE FROM note_search WHERE rowid = old.sortKey;
                END;

                CREATE TRIGGER attachments_search_insert
                AFTER INSERT ON attachments
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = new.noteID);
                    INSERT INTO note_search(rowid, noteID, body, attachmentFilenames)
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a
                                   WHERE a.noteID = notes.id
                               ), '')
                        FROM notes
                        WHERE notes.id = new.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER attachments_search_delete
                AFTER DELETE ON attachments
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = old.noteID);
                    INSERT INTO note_search(rowid, noteID, body, attachmentFilenames)
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a
                                   WHERE a.noteID = notes.id
                               ), '')
                        FROM notes
                        WHERE notes.id = old.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER attachments_search_update
                AFTER UPDATE OF originalFilename ON attachments
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = new.noteID);
                    INSERT INTO note_search(rowid, noteID, body, attachmentFilenames)
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a
                                   WHERE a.noteID = notes.id
                               ), '')
                        FROM notes
                        WHERE notes.id = new.noteID AND notes.deletedAt IS NULL;
                END;
                """)
        }
        migrator.registerMigration(identifiers[4]) { database in
            try database.execute(sql: """
                ALTER TABLE notes
                    ADD COLUMN linkPreviewRevision INTEGER NOT NULL DEFAULT 0;

                CREATE TABLE app_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    automaticLinkPreviewsEnabled INTEGER NOT NULL DEFAULT 0
                        CHECK (automaticLinkPreviewsEnabled IN (0, 1))
                );

                INSERT INTO app_settings(id, automaticLinkPreviewsEnabled) VALUES (1, 0);

                CREATE TABLE link_preview_cache (
                    requestKey TEXT PRIMARY KEY,
                    canonicalURL TEXT NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT,
                    imageURL TEXT,
                    localImageFilename TEXT UNIQUE,
                    siteName TEXT NOT NULL,
                    fetchedAt INTEGER NOT NULL,
                    retryAfter INTEGER
                );

                CREATE TABLE link_previews (
                    id TEXT PRIMARY KEY,
                    noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    originalURL TEXT NOT NULL,
                    requestKey TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'failed', 'removed')),
                    failureReason TEXT,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL,
                    nextFetchAt INTEGER,
                    reconciledRevision INTEGER NOT NULL,
                    UNIQUE(noteID, requestKey)
                );

                CREATE INDEX link_previews_noteID ON link_previews(noteID, createdAt, id);
                CREATE INDEX link_previews_work ON link_previews(requestKey, status);

                DROP TRIGGER IF EXISTS notes_search_insert;
                DROP TRIGGER IF EXISTS notes_search_update;
                DROP TRIGGER IF EXISTS notes_search_delete;
                DROP TRIGGER IF EXISTS attachments_search_insert;
                DROP TRIGGER IF EXISTS attachments_search_delete;
                DROP TRIGGER IF EXISTS attachments_search_update;
                DROP TABLE note_search;

                CREATE VIRTUAL TABLE note_search USING fts5(
                    noteID UNINDEXED,
                    body,
                    attachmentFilenames,
                    previewMetadata,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                INSERT INTO note_search(
                    rowid, noteID, body, attachmentFilenames, previewMetadata
                )
                    SELECT notes.sortKey, notes.id, notes.body,
                           COALESCE((
                               SELECT group_concat(attachments.originalFilename, ' ')
                               FROM attachments
                               WHERE attachments.noteID = notes.id
                           ), ''),
                           COALESCE((
                               SELECT group_concat(
                                   link_previews.originalURL || ' '
                                   || COALESCE(link_preview_cache.title, '') || ' '
                                   || COALESCE(link_preview_cache.summary, '') || ' '
                                   || COALESCE(link_preview_cache.siteName, ''),
                                   ' '
                               )
                               FROM link_previews
                               LEFT JOIN link_preview_cache
                                   ON link_preview_cache.requestKey = link_previews.requestKey
                               WHERE link_previews.noteID = notes.id
                                 AND link_previews.status != 'removed'
                                 AND link_previews.reconciledRevision = notes.linkPreviewRevision
                           ), '')
                    FROM notes
                    WHERE notes.deletedAt IS NULL;

                CREATE TRIGGER notes_search_insert
                AFTER INSERT ON notes
                WHEN new.deletedAt IS NULL
                BEGIN
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    ) VALUES (new.sortKey, new.id, new.body, '', '');
                END;

                CREATE TRIGGER notes_search_update
                AFTER UPDATE OF body, deletedAt ON notes
                BEGIN
                    DELETE FROM note_search WHERE rowid = old.sortKey;
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT new.sortKey, new.id, new.body,
                               COALESCE((
                                   SELECT group_concat(attachments.originalFilename, ' ')
                                   FROM attachments
                                   WHERE attachments.noteID = new.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       link_previews.originalURL || ' '
                                       || COALESCE(link_preview_cache.title, '') || ' '
                                       || COALESCE(link_preview_cache.summary, '') || ' '
                                       || COALESCE(link_preview_cache.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews
                                   LEFT JOIN link_preview_cache
                                       ON link_preview_cache.requestKey = link_previews.requestKey
                                   WHERE link_previews.noteID = new.id
                                     AND link_previews.status != 'removed'
                                     AND link_previews.reconciledRevision = new.linkPreviewRevision
                               ), '')
                        WHERE new.deletedAt IS NULL;
                END;

                CREATE TRIGGER notes_search_delete
                AFTER DELETE ON notes
                BEGIN
                    DELETE FROM note_search WHERE rowid = old.sortKey;
                END;

                CREATE TRIGGER attachments_search_insert
                AFTER INSERT ON attachments
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = new.noteID);
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a
                                   WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.id = new.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER attachments_search_delete
                AFTER DELETE ON attachments
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = old.noteID);
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a
                                   WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.id = old.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER attachments_search_update
                AFTER UPDATE OF originalFilename ON attachments
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = new.noteID);
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a
                                   WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.id = new.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER link_previews_search_insert
                AFTER INSERT ON link_previews
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = new.noteID);
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.id = new.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER link_previews_search_delete
                AFTER DELETE ON link_previews
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid = (SELECT sortKey FROM notes WHERE id = old.noteID);
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.id = old.noteID AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER link_previews_search_update
                AFTER UPDATE OF originalURL, requestKey, status ON link_previews
                BEGIN
                    DELETE FROM note_search
                    WHERE rowid IN (
                        SELECT sortKey FROM notes WHERE id IN (old.noteID, new.noteID)
                    );
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.id IN (old.noteID, new.noteID)
                          AND notes.deletedAt IS NULL;
                END;

                CREATE TRIGGER link_preview_cache_search_insert
                AFTER INSERT ON link_preview_cache
                BEGIN
                    DELETE FROM note_search WHERE rowid IN (
                        SELECT notes.sortKey
                        FROM notes JOIN link_previews ON link_previews.noteID = notes.id
                        WHERE link_previews.requestKey = new.requestKey
                    );
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.deletedAt IS NULL AND EXISTS (
                            SELECT 1 FROM link_previews p
                            WHERE p.noteID = notes.id AND p.requestKey = new.requestKey
                              AND p.reconciledRevision = notes.linkPreviewRevision
                        );
                END;

                CREATE TRIGGER link_preview_cache_search_update
                AFTER UPDATE OF canonicalURL, title, summary, imageURL,
                                localImageFilename, siteName, fetchedAt
                ON link_preview_cache
                BEGIN
                    DELETE FROM note_search WHERE rowid IN (
                        SELECT notes.sortKey
                        FROM notes JOIN link_previews ON link_previews.noteID = notes.id
                        WHERE link_previews.requestKey IN (old.requestKey, new.requestKey)
                    );
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.deletedAt IS NULL AND EXISTS (
                            SELECT 1 FROM link_previews p
                            WHERE p.noteID = notes.id
                              AND p.requestKey IN (old.requestKey, new.requestKey)
                              AND p.reconciledRevision = notes.linkPreviewRevision
                        );
                END;

                CREATE TRIGGER link_preview_cache_search_delete
                AFTER DELETE ON link_preview_cache
                BEGIN
                    DELETE FROM note_search WHERE rowid IN (
                        SELECT notes.sortKey
                        FROM notes JOIN link_previews ON link_previews.noteID = notes.id
                        WHERE link_previews.requestKey = old.requestKey
                    );
                    INSERT INTO note_search(
                        rowid, noteID, body, attachmentFilenames, previewMetadata
                    )
                        SELECT notes.sortKey, notes.id, notes.body,
                               COALESCE((
                                   SELECT group_concat(a.originalFilename, ' ')
                                   FROM attachments a WHERE a.noteID = notes.id
                               ), ''),
                               COALESCE((
                                   SELECT group_concat(
                                       p.originalURL || ' ' || COALESCE(c.title, '') || ' '
                                       || COALESCE(c.summary, '') || ' ' || COALESCE(c.siteName, ''),
                                       ' '
                                   )
                                   FROM link_previews p
                                   LEFT JOIN link_preview_cache c ON c.requestKey = p.requestKey
                                   WHERE p.noteID = notes.id AND p.status != 'removed'
                                     AND p.reconciledRevision = notes.linkPreviewRevision
                               ), '')
                        FROM notes
                        WHERE notes.deletedAt IS NULL AND EXISTS (
                            SELECT 1 FROM link_previews p
                            WHERE p.noteID = notes.id AND p.requestKey = old.requestKey
                              AND p.reconciledRevision = notes.linkPreviewRevision
                        );
                END;
                """)
        }
        migrator.registerMigration(identifiers[5]) { database in
            try database.execute(sql: """
                ALTER TABLE notes
                    ADD COLUMN threadRootID TEXT REFERENCES notes(id) ON DELETE CASCADE;

                ALTER TABLE notes
                    ADD COLUMN deletedWithRoot INTEGER NOT NULL DEFAULT 0
                    CHECK (deletedWithRoot IN (0, 1));

                CREATE INDEX notes_threadRootID_sortKey
                    ON notes(threadRootID, sortKey)
                    WHERE threadRootID IS NOT NULL;

                CREATE TRIGGER notes_thread_insert
                BEFORE INSERT ON notes
                WHEN new.threadRootID IS NOT NULL
                BEGIN
                    SELECT CASE WHEN new.threadRootID = new.id
                        OR NOT EXISTS (
                            SELECT 1 FROM notes AS root
                            WHERE root.id = new.threadRootID
                              AND root.threadRootID IS NULL
                              AND root.deletedAt IS NULL
                        )
                    THEN RAISE(ABORT, 'invalid thread root') END;
                END;

                CREATE TRIGGER notes_thread_update
                BEFORE UPDATE OF threadRootID ON notes
                WHEN new.threadRootID IS NOT old.threadRootID
                BEGIN
                    SELECT RAISE(ABORT, 'thread root is immutable');
                END;
                """)
        }
        return migrator
    }
}
