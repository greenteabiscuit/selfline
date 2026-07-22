import CryptoKit
import Darwin
import Foundation
import GRDB

final class ArchiveService: @unchecked Sendable {
    static let backupFormatIdentifier = "com.selfdmnotes.backup"
    static let backupFormatVersion = 1
    static let minimumSupportedBackupSchemaVersion = 5
    static let portableExportFormatIdentifier = "com.selfdmnotes.portable-export"
    static let portableExportFormatVersion = 1
    static let automaticBackupInterval: TimeInterval = 24 * 60 * 60
    static let automaticBackupRetentionCount = 7

    private static let automaticBookmarkKey = "automaticBackupDirectoryBookmarkV1"
    private static let automaticDirectoryNameKey = "automaticBackupDirectoryNameV1"
    private static let automaticLastSuccessKey = "automaticBackupLastSuccessV1"
    private static let automaticBackupPrefix = "Self DM Notes Automatic Backup "

    let recoveryCoordinator: RestoreRecoveryCoordinator

    private let provider: ApplicationSupportDirectoryProvider
    private let database: AppDatabase
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let applicationVersion: String
    private let buildVersion: String

    init(
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        recoveryCoordinator: RestoreRecoveryCoordinator,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        applicationVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        buildVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
    ) {
        self.provider = provider
        self.database = database
        self.recoveryCoordinator = recoveryCoordinator
        self.fileManager = fileManager
        self.defaults = defaults
        self.applicationVersion = applicationVersion
        self.buildVersion = buildVersion
    }

    var startupMode: RestoreStartupMode {
        recoveryCoordinator.startupMode
    }

    var hasPendingRestore: Bool {
        recoveryCoordinator.hasPendingRestore
    }

    var hasAutomaticBackupDirectory: Bool {
        defaults.data(forKey: Self.automaticBookmarkKey) != nil
    }

    var automaticBackupDirectoryName: String? {
        defaults.string(forKey: Self.automaticDirectoryNameKey)
    }

    var lastAutomaticBackupSuccessDate: Date? {
        defaults.object(forKey: Self.automaticLastSuccessKey) as? Date
    }

    func configureAutomaticBackupDirectory(_ directoryURL: URL) throws {
        try validateDestinationDirectory(directoryURL)
        let accessed = directoryURL.startAccessingSecurityScopedResource()
        defer { if accessed { directoryURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.automaticBookmarkKey)
        defaults.set(directoryURL.lastPathComponent, forKey: Self.automaticDirectoryNameKey)
    }

    func removeAutomaticBackupDirectory() {
        defaults.removeObject(forKey: Self.automaticBookmarkKey)
        defaults.removeObject(forKey: Self.automaticDirectoryNameKey)
        defaults.removeObject(forKey: Self.automaticLastSuccessKey)
    }

    func createManualBackup(
        in destinationDirectory: URL,
        now: Date = Date(),
        progress: @escaping @Sendable (ArchiveOperationProgress) -> Void = { _ in }
    ) throws -> BackupCreationResult {
        try createBackup(
            in: destinationDirectory,
            kind: .manual,
            now: now,
            progress: progress
        )
    }

    func createAutomaticBackupIfDue(
        now: Date = Date(),
        progress: @escaping @Sendable (ArchiveOperationProgress) -> Void = { _ in }
    ) throws -> BackupCreationResult? {
        guard recoveryCoordinator.startupMode == .none,
              let bookmark = defaults.data(forKey: Self.automaticBookmarkKey) else {
            return nil
        }
        if let lastSuccess = defaults.object(forKey: Self.automaticLastSuccessKey) as? Date,
           now.timeIntervalSince(lastSuccess) < Self.automaticBackupInterval {
            return nil
        }
        let directory = try resolveAutomaticBackupDirectory(bookmark: bookmark)
        let result = try createBackup(
            in: directory,
            kind: .automatic,
            now: now,
            progress: progress
        )
        defaults.set(now, forKey: Self.automaticLastSuccessKey)
        return result
    }

    func exportPortableArchive(
        in destinationDirectory: URL,
        now: Date = Date(),
        progress: @escaping @Sendable (ArchiveOperationProgress) -> Void = { _ in }
    ) throws -> URL {
        try withSecurityScopedAccess(to: destinationDirectory) {
            try validateDestinationDirectory(destinationDirectory)
            try Task.checkCancellation()
            let exportID = UUID()
            let createdAt = Self.milliseconds(now)
            let partialURL = destinationDirectory.appendingPathComponent(
                ".selfdmnotes-export-\(exportID.uuidString.lowercased()).partial",
                isDirectory: true
            )
            let finalURL = destinationDirectory.appendingPathComponent(
                "Self DM Notes Export \(Self.filenameTimestamp(now)) \(Self.shortID(exportID)).selfdmexport",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: partialURL.path),
                  !fileManager.fileExists(atPath: finalURL.path) else {
                throw ArchiveServiceError.destinationAlreadyExists
            }

            var didPublish = false
            do {
                try createControlledDirectory(partialURL)
                let snapshotURL = partialURL.appendingPathComponent(
                    ".export-snapshot.sqlite",
                    isDirectory: false
                )
                progress(.init(kind: .export, fraction: 0.02, message: "Creating a consistent database snapshot…"))
                try database.createBackupSnapshot(at: snapshotURL) { fraction in
                    try Task.checkCancellation()
                    progress(.init(
                        kind: .export,
                        fraction: 0.02 + fraction * 0.13,
                        message: "Creating a consistent database snapshot…"
                    ))
                }
                try synchronizeRegularFile(snapshotURL)
                let contents = try ArchiveDatabaseInspector.inspect(
                    databaseURL: snapshotURL,
                    includePortableNotes: true
                )
                guard let databaseNotes = contents.notes else {
                    throw ArchiveServiceError.invalidDatabase("Portable note rows were unavailable.")
                }
                try Task.checkCancellation()

                let attachmentsDirectory = partialURL.appendingPathComponent(
                    "attachments",
                    isDirectory: true
                )
                try createControlledDirectory(attachmentsDirectory)
                let allocated = try allocateExportPaths(notes: databaseNotes)
                var fileRecords: [ArchiveFileRecord] = []
                let allAttachments = allocated.flatMap(\.attachments)
                for (index, attachment) in allAttachments.enumerated() {
                    try Task.checkCancellation()
                    let sourceURL = provider.originalsURL.appendingPathComponent(
                        attachment.managedFilename,
                        isDirectory: false
                    )
                    let destinationURL = partialURL.appendingPathComponent(
                        attachment.exportedPath,
                        isDirectory: false
                    )
                    let copied = try copyRegularFile(
                        from: sourceURL,
                        to: destinationURL,
                        expectedByteSize: attachment.byteSize,
                        expectedSHA256: attachment.contentHash
                    )
                    fileRecords.append(
                        ArchiveFileRecord(
                            path: attachment.exportedPath,
                            byteSize: copied.byteSize,
                            sha256: copied.sha256,
                            role: "attachmentOriginal"
                        )
                    )
                    let fraction = 0.18 + 0.60 * Double(index + 1)
                        / Double(max(allAttachments.count, 1))
                    progress(.init(
                        kind: .export,
                        fraction: fraction,
                        message: "Copying original attachments (\(index + 1) of \(allAttachments.count))…"
                    ))
                }

                let portable = PortableArchive(
                    formatIdentifier: Self.portableExportFormatIdentifier,
                    formatVersion: Self.portableExportFormatVersion,
                    exportID: exportID,
                    exportedAtMilliseconds: createdAt,
                    notes: allocated.map(\.portable)
                )
                let jsonURL = partialURL.appendingPathComponent("export.json")
                try writeDurable(try Self.encoder.encode(portable), to: jsonURL)
                fileRecords.append(try fileRecord(at: jsonURL, relativePath: "export.json", role: "portableJSON"))

                let markdownURL = partialURL.appendingPathComponent("notes.md")
                try writeDurable(
                    Data(Self.markdown(for: portable).utf8),
                    to: markdownURL
                )
                fileRecords.append(try fileRecord(at: markdownURL, relativePath: "notes.md", role: "markdown"))
                try fileManager.removeItem(at: snapshotURL)

                let manifest = PortableExportManifest(
                    formatIdentifier: Self.portableExportFormatIdentifier,
                    formatVersion: Self.portableExportFormatVersion,
                    exportID: exportID,
                    createdAtMilliseconds: createdAt,
                    applicationVersion: applicationVersion,
                    buildVersion: buildVersion,
                    files: fileRecords.sorted { $0.path < $1.path }
                )
                let manifestURL = partialURL.appendingPathComponent("manifest.json")
                try writeDurable(try Self.encoder.encode(manifest), to: manifestURL)
                try synchronizeDirectory(attachmentsDirectory)
                try synchronizeDirectory(partialURL)
                progress(.init(kind: .export, fraction: 0.90, message: "Verifying the portable archive…"))
                _ = try validatePortableExport(at: partialURL)
                try Task.checkCancellation()
                try publishDirectory(partialURL, as: finalURL)
                didPublish = true
                _ = try validatePortableExport(at: finalURL, allowsCancellation: false)
                progress(.init(kind: .export, fraction: 1, message: "Portable archive verified."))
                return finalURL
            } catch {
                if !didPublish {
                    try? fileManager.removeItem(at: partialURL)
                }
                throw error
            }
        }
    }

    func stageRestore(
        from selectedPackageURL: URL,
        progress: @escaping @Sendable (ArchiveOperationProgress) -> Void = { _ in }
    ) throws -> RestoreStagingResult {
        guard !recoveryCoordinator.hasPendingRestore else {
            throw ArchiveServiceError.restoreAlreadyPending
        }
        try rejectProtectedLocation(selectedPackageURL)
        return try withSecurityScopedAccess(to: selectedPackageURL) {
            progress(.init(kind: .restore, fraction: 0.02, message: "Reading the backup manifest…"))
            let manifestData = try readRegularData(
                at: selectedPackageURL.appendingPathComponent("manifest.json"),
                maximumByteCount: 4 * 1_024 * 1_024
            )
            let manifest = try decodeAndValidateBackupManifest(manifestData)
            try validateExactPackageEntries(
                packageURL: selectedPackageURL,
                expectedFilePaths: Set(manifest.files.map(\.path)).union(["manifest.json"]),
                allowedDirectories: Self.backupDirectoryPaths
            )
            try Task.checkCancellation()

            try recoveryCoordinator.prepareForStaging()
            let quarantineURL = recoveryCoordinator.controlDirectoryURL.appendingPathComponent(
                "quarantine-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try createControlledDirectory(quarantineURL)
            var armed = false
            do {
                for directory in Self.backupDirectoryPaths.sorted() where !directory.isEmpty {
                    try fileManager.createDirectory(
                        at: quarantineURL.appendingPathComponent(directory, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                }
                let quarantinedManifestURL = quarantineURL.appendingPathComponent("manifest.json")
                let copiedManifest = try copyRegularFile(
                    from: selectedPackageURL.appendingPathComponent("manifest.json"),
                    to: quarantinedManifestURL,
                    includeData: true
                )
                guard copiedManifest.data == manifestData else {
                    throw ArchiveServiceError.packageChangedDuringRead("manifest.json")
                }
                for (index, entry) in manifest.files.enumerated() {
                    try Task.checkCancellation()
                    let copied = try copyRegularFile(
                        from: selectedPackageURL.appendingPathComponent(entry.path),
                        to: quarantineURL.appendingPathComponent(entry.path),
                        expectedByteSize: entry.byteSize,
                        expectedSHA256: entry.sha256
                    )
                    guard copied.byteSize == entry.byteSize, copied.sha256 == entry.sha256 else {
                        throw ArchiveServiceError.checksumMismatch(entry.path)
                    }
                    progress(.init(
                        kind: .restore,
                        fraction: 0.05 + 0.65 * Double(index + 1) / Double(max(manifest.files.count, 1)),
                        message: "Copying backup into protected staging (\(index + 1) of \(manifest.files.count))…"
                    ))
                }
                try synchronizeBackupTree(at: quarantineURL)
                progress(.init(kind: .restore, fraction: 0.76, message: "Checking SQLite integrity and archive relationships…"))
                let validated = try validateBackup(at: quarantineURL)
                try Task.checkCancellation()

                guard !fileManager.fileExists(atPath: recoveryCoordinator.stagedLibraryURL.path),
                      !fileManager.fileExists(atPath: recoveryCoordinator.rollbackLibraryURL.path) else {
                    throw ArchiveServiceError.restoreAlreadyPending
                }
                try fileManager.moveItem(
                    at: quarantineURL.appendingPathComponent("library", isDirectory: true),
                    to: recoveryCoordinator.stagedLibraryURL
                )
                try synchronizeDirectory(recoveryCoordinator.controlDirectoryURL)
                try fileManager.removeItem(at: quarantineURL)
                // Cancellation is intentionally no longer observed after this
                // point. Arming is a monotonic durable recovery boundary.
                try recoveryCoordinator.armRestore(
                    backupID: validated.manifest.backupID,
                    stagedRoot: recoveryCoordinator.stagedLibraryURL
                )
                armed = true
                progress(.init(kind: .restore, fraction: 1, message: "Restore verified and ready for relaunch."))
                return RestoreStagingResult(
                    backupCreatedAtMilliseconds: validated.manifest.createdAtMilliseconds,
                    noteCount: validated.contents.noteCount
                )
            } catch {
                if !armed {
                    try? fileManager.removeItem(at: quarantineURL)
                    if !recoveryCoordinator.hasPendingRestore {
                        try? fileManager.removeItem(at: recoveryCoordinator.stagedLibraryURL)
                    }
                }
                throw error
            }
        }
    }

    func cancelPendingRestore() throws {
        try recoveryCoordinator.cancelArmedRestore()
    }

    func confirmSuccessfulStartup() throws {
        try recoveryCoordinator.confirmSuccessfulStartup()
    }

    func requestRestoreRollback(_ reason: String) throws {
        try recoveryCoordinator.requestRollback(reason)
    }

    @discardableResult
    func validateBackup(
        at packageURL: URL,
        allowsCancellation: Bool = true
    ) throws -> ValidatedBackup {
        let manifestData = try readRegularData(
            at: packageURL.appendingPathComponent("manifest.json"),
            maximumByteCount: 4 * 1_024 * 1_024
        )
        let manifest = try decodeAndValidateBackupManifest(manifestData)
        try validateExactPackageEntries(
            packageURL: packageURL,
            expectedFilePaths: Set(manifest.files.map(\.path)).union(["manifest.json"]),
            allowedDirectories: Self.backupDirectoryPaths
        )
        for entry in manifest.files {
            if allowsCancellation { try Task.checkCancellation() }
            let measured = try hashRegularFile(
                at: packageURL.appendingPathComponent(entry.path),
                includeData: false
            )
            guard measured.byteSize == entry.byteSize,
                  measured.sha256 == entry.sha256 else {
                throw ArchiveServiceError.checksumMismatch(entry.path)
            }
        }
        let databaseURL = packageURL.appendingPathComponent("library/notes.sqlite")
        let contents = try ArchiveDatabaseInspector.inspect(
            databaseURL: databaseURL,
            includePortableNotes: false
        )
        guard contents.migrations == manifest.databaseMigrations,
              DatabaseMigrations.identifiers.starts(with: contents.migrations),
              manifest.databaseSchemaVersion == contents.migrations.count else {
            throw ArchiveServiceError.incompatibleDatabaseSchema
        }
        let expectedRecords = try expectedBackupRecords(
            contents: contents,
            databaseURL: databaseURL
        )
        guard expectedRecords == manifest.files else {
            throw ArchiveServiceError.inventoryDoesNotMatchDatabase
        }
        try verifyDatabaseOwnedFileHashes(contents.requirements, packageRoot: packageURL)
        return ValidatedBackup(manifest: manifest, contents: contents)
    }

    @discardableResult
    func validatePortableExport(
        at packageURL: URL,
        allowsCancellation: Bool = true
    ) throws -> PortableArchive {
        let manifestData = try readRegularData(
            at: packageURL.appendingPathComponent("manifest.json"),
            maximumByteCount: 4 * 1_024 * 1_024
        )
        let manifest: PortableExportManifest
        do {
            manifest = try Self.decoder.decode(PortableExportManifest.self, from: manifestData)
        } catch {
            throw ArchiveServiceError.invalidManifest
        }
        let manifestPaths = manifest.files.map(\.path)
        guard manifest.formatIdentifier == Self.portableExportFormatIdentifier,
              manifest.formatVersion == Self.portableExportFormatVersion,
              manifest.files == manifest.files.sorted(by: { $0.path < $1.path }),
              Set(manifestPaths).count == manifest.files.count,
              Set(manifestPaths.map(Self.canonicalCollisionKey)).count == manifest.files.count,
              manifest.files.allSatisfy({ entry in
                  entry.byteSize >= 0
                      && Self.isLowercaseSHA256(entry.sha256)
                      && Self.isSafePortablePath(entry.path)
                      && Self.isValidPortableRole(entry.role, for: entry.path)
              }),
              manifestPaths.contains("export.json"),
              manifestPaths.contains("notes.md") else {
            throw ArchiveServiceError.invalidManifest
        }
        let recordsByPath = Dictionary(
            uniqueKeysWithValues: manifest.files.map { ($0.path, $0) }
        )
        try validateExactPackageEntries(
            packageURL: packageURL,
            expectedFilePaths: Set(manifestPaths).union(["manifest.json"]),
            allowedDirectories: ["", "attachments"]
        )
        for entry in manifest.files {
            if allowsCancellation { try Task.checkCancellation() }
            let measured = try hashRegularFile(
                at: packageURL.appendingPathComponent(entry.path),
                includeData: false
            )
            guard measured.byteSize == entry.byteSize,
                  measured.sha256 == entry.sha256 else {
                throw ArchiveServiceError.checksumMismatch(entry.path)
            }
        }
        guard let exportRecord = recordsByPath["export.json"],
              let markdownRecord = recordsByPath["notes.md"] else {
            throw ArchiveServiceError.invalidManifest
        }
        let exportData = try verifiedPortableData(
            at: packageURL.appendingPathComponent("export.json"),
            record: exportRecord
        )
        let portable: PortableArchive
        do {
            portable = try Self.decoder.decode(PortableArchive.self, from: exportData)
        } catch {
            throw ArchiveServiceError.invalidPortableExport
        }
        guard portable.formatIdentifier == Self.portableExportFormatIdentifier,
              portable.formatVersion == Self.portableExportFormatVersion,
              portable.exportID == manifest.exportID,
              portable.exportedAtMilliseconds == manifest.createdAtMilliseconds else {
            throw ArchiveServiceError.invalidPortableExport
        }
        let attachmentRecords = recordsByPath.filter { $0.value.role == "attachmentOriginal" }
        let attachments = portable.notes.flatMap(\.attachments)
        let attachmentPaths = attachments.map(\.exportedPath)
        let noteIDs = portable.notes.map(\.id)
        let attachmentIDs = attachments.map(\.id)
        let previewIDs = portable.notes.flatMap(\.linkPreviews).map(\.id)
        let notesByID = Dictionary(uniqueKeysWithValues: portable.notes.map { ($0.id, $0) })
        let notesAreChronological = zip(portable.notes, portable.notes.dropFirst()).allSatisfy {
            pair in pair.0.sortKey < pair.1.sortKey
        }
        let threadLinksAreValid = portable.notes.allSatisfy { note in
            guard let threadRootID = note.threadRootID,
                  let root = notesByID[threadRootID] else {
                return note.threadRootID == nil
            }
            return threadRootID != note.id
                && root.threadRootID == nil
                && root.sortKey < note.sortKey
                && (root.deletedAtMilliseconds == nil || note.deletedAtMilliseconds != nil)
        }
        guard Set(attachmentPaths).count == attachmentPaths.count,
              attachmentPaths.allSatisfy(Self.isSafePortableAttachmentPath),
              Set(attachmentPaths) == Set(attachmentRecords.keys),
              Set(noteIDs).count == noteIDs.count,
              Set(attachmentIDs).count == attachmentIDs.count,
              Set(previewIDs).count == previewIDs.count,
              notesAreChronological,
              threadLinksAreValid,
              portable.notes.allSatisfy(Self.isValidPortableNote),
              attachments.allSatisfy({ attachment in
                  guard let record = attachmentRecords[attachment.exportedPath] else {
                      return false
                  }
                  return record.byteSize == attachment.byteSize
                      && record.sha256 == attachment.contentHash
              }) else {
            throw ArchiveServiceError.invalidPortableExport
        }
        let markdownData = try verifiedPortableData(
            at: packageURL.appendingPathComponent("notes.md"),
            record: markdownRecord
        )
        let currentMarkdown = Data(Self.markdown(for: portable).utf8)
        let legacyMarkdown = portable.notes.allSatisfy { $0.threadRootID == nil }
            ? Data(Self.legacyMarkdown(for: portable).utf8)
            : nil
        guard markdownData == currentMarkdown || markdownData == legacyMarkdown else {
            throw ArchiveServiceError.invalidPortableExport
        }
        return portable
    }

    private func createBackup(
        in destinationDirectory: URL,
        kind: BackupKind,
        now: Date,
        progress: @escaping @Sendable (ArchiveOperationProgress) -> Void
    ) throws -> BackupCreationResult {
        try withSecurityScopedAccess(to: destinationDirectory) {
            try validateDestinationDirectory(destinationDirectory)
            try Task.checkCancellation()
            let backupID = UUID()
            let prefix = kind == .automatic
                ? Self.automaticBackupPrefix
                : "Self DM Notes Backup "
            let partialURL = destinationDirectory.appendingPathComponent(
                ".selfdmnotes-backup-\(backupID.uuidString.lowercased()).partial",
                isDirectory: true
            )
            let finalURL = destinationDirectory.appendingPathComponent(
                "\(prefix)\(Self.filenameTimestamp(now)) \(Self.shortID(backupID)).selfdmbackup",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: partialURL.path),
                  !fileManager.fileExists(atPath: finalURL.path) else {
                throw ArchiveServiceError.destinationAlreadyExists
            }
            var didPublish = false
            do {
                try createBackupDirectories(at: partialURL)
                let snapshotURL = partialURL.appendingPathComponent("library/notes.sqlite")
                progress(.init(kind: .backup, fraction: 0.02, message: "Creating a consistent SQLite snapshot…"))
                try database.createBackupSnapshot(at: snapshotURL) { fraction in
                    try Task.checkCancellation()
                    progress(.init(
                        kind: .backup,
                        fraction: 0.02 + fraction * 0.18,
                        message: "Creating a consistent SQLite snapshot…"
                    ))
                }
                try synchronizeRegularFile(snapshotURL)
                let contents = try ArchiveDatabaseInspector.inspect(
                    databaseURL: snapshotURL,
                    includePortableNotes: false
                )
                guard contents.migrations == DatabaseMigrations.identifiers else {
                    throw ArchiveServiceError.incompatibleDatabaseSchema
                }

                var records = [try fileRecord(
                    at: snapshotURL,
                    relativePath: "library/notes.sqlite",
                    role: "database"
                )]
                for (index, requirement) in contents.requirements.enumerated() {
                    try Task.checkCancellation()
                    let sourceURL = activeLibraryURL(for: requirement.path)
                    let destinationURL = partialURL.appendingPathComponent(requirement.path)
                    let copied = try copyRegularFile(
                        from: sourceURL,
                        to: destinationURL,
                        expectedByteSize: requirement.expectedByteSize,
                        expectedSHA256: requirement.expectedSHA256
                    )
                    records.append(
                        ArchiveFileRecord(
                            path: requirement.path,
                            byteSize: copied.byteSize,
                            sha256: copied.sha256,
                            role: requirement.role
                        )
                    )
                    progress(.init(
                        kind: .backup,
                        fraction: 0.22 + 0.58 * Double(index + 1)
                            / Double(max(contents.requirements.count, 1)),
                        message: "Copying managed library files (\(index + 1) of \(contents.requirements.count))…"
                    ))
                }
                records.sort { $0.path < $1.path }
                let manifest = BackupPackageManifest(
                    formatIdentifier: Self.backupFormatIdentifier,
                    formatVersion: Self.backupFormatVersion,
                    backupID: backupID,
                    backupKind: kind.rawValue,
                    createdAtMilliseconds: Self.milliseconds(now),
                    applicationVersion: applicationVersion,
                    buildVersion: buildVersion,
                    databaseSchemaVersion: DatabaseMigrations.currentSchemaVersion,
                    databaseMigrations: contents.migrations,
                    files: records
                )
                try writeDurable(
                    try Self.encoder.encode(manifest),
                    to: partialURL.appendingPathComponent("manifest.json")
                )
                try synchronizeBackupTree(at: partialURL)
                progress(.init(kind: .backup, fraction: 0.84, message: "Verifying checksums and SQLite integrity…"))
                _ = try validateBackup(at: partialURL)
                try Task.checkCancellation()
                try publishDirectory(partialURL, as: finalURL)
                didPublish = true
                _ = try validateBackup(at: finalURL, allowsCancellation: false)
                let rotationWarning = kind == .automatic
                    ? rotateAutomaticBackups(in: destinationDirectory, preserving: finalURL)
                    : nil
                progress(.init(kind: .backup, fraction: 1, message: "Backup verified."))
                return BackupCreationResult(
                    packageURL: finalURL,
                    rotationWarning: rotationWarning
                )
            } catch {
                if !didPublish {
                    try? fileManager.removeItem(at: partialURL)
                }
                throw error
            }
        }
    }

    func rotateAutomaticBackups(
        in directoryURL: URL,
        preserving newestURL: URL
    ) -> String? {
        var removedCount = 0
        do {
            var verified: [(url: URL, manifest: BackupPackageManifest)] = []
            let children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for url in children
            where url.lastPathComponent.hasPrefix(Self.automaticBackupPrefix)
                && url.pathExtension == "selfdmbackup" {
                do {
                    let validated = try validateBackup(at: url, allowsCancellation: false)
                    guard validated.manifest.backupKind == BackupKind.automatic.rawValue else {
                        continue
                    }
                    verified.append((url, validated.manifest))
                } catch {
                    // Invalid and partial packages are never rotation candidates.
                    continue
                }
            }
            guard let newestIndex = verified.firstIndex(where: {
                $0.url.standardizedFileURL == newestURL.standardizedFileURL
            }) else {
                throw ArchiveServiceError.checksumMismatch(newestURL.lastPathComponent)
            }
            let newest = verified.remove(at: newestIndex)
            verified.sort {
                if $0.manifest.createdAtMilliseconds == $1.manifest.createdAtMilliseconds {
                    return $0.manifest.backupID.uuidString > $1.manifest.backupID.uuidString
                }
                return $0.manifest.createdAtMilliseconds > $1.manifest.createdAtMilliseconds
            }
            let retainedPaths = Set(
                ([newest] + Array(verified.prefix(Self.automaticBackupRetentionCount - 1)))
                    .map { $0.url.standardizedFileURL.path }
            )
            for candidate in verified
            where !retainedPaths.contains(candidate.url.standardizedFileURL.path) {
                try fileManager.removeItem(at: candidate.url)
                removedCount += 1
            }
            try synchronizeDirectory(directoryURL)
            return nil
        } catch {
            let removalStatus = removedCount == 0
                ? "No older package was removed."
                : "\(removedCount) oldest verified package(s) were removed before rotation stopped; the seven newest verified packages were preserved."
            return "The new backup is verified, but rotation did not finish. \(removalStatus) Details: \(error.localizedDescription)"
        }
    }

    private func resolveAutomaticBackupDirectory(bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            try configureAutomaticBackupDirectory(url)
        }
        return url
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private func validateDestinationDirectory(_ url: URL) throws {
        try rejectProtectedLocation(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ArchiveServiceError.destinationIsNotSafeDirectory
        }
        let descriptor = try openDirectory(url)
        Darwin.close(descriptor)
    }

    private func rejectProtectedLocation(_ url: URL) throws {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        for protected in [provider.rootURL, recoveryCoordinator.controlDirectoryURL] {
            let protectedURL = protected.standardizedFileURL.resolvingSymlinksInPath()
            if Self.contains(protectedURL, candidate) || Self.contains(candidate, protectedURL) {
                throw ArchiveServiceError.destinationOverlapsLibrary
            }
        }
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path == parent.path || child.path.hasPrefix(parentPath)
    }
}

extension ArchiveService {
    fileprivate static let backupDirectoryPaths: Set<String> = [
        "library",
        "library/attachments",
        "library/attachments/originals",
        "library/attachments/thumbnails",
        "library/previews",
        "library/staging"
    ]

    fileprivate static let allowedBackupRoles: Set<String> = [
        "attachmentOriginal", "attachmentThumbnail", "database",
        "draftOriginal", "draftThumbnail", "previewImage"
    ]

    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    fileprivate static var decoder: JSONDecoder { JSONDecoder() }

    fileprivate func decodeAndValidateBackupManifest(
        _ data: Data
    ) throws -> BackupPackageManifest {
        let manifest: BackupPackageManifest
        do {
            manifest = try Self.decoder.decode(BackupPackageManifest.self, from: data)
        } catch {
            throw ArchiveServiceError.invalidManifest
        }
        if manifest.databaseSchemaVersion > DatabaseMigrations.currentSchemaVersion {
            throw ArchiveServiceError.backupFromNewerVersion
        }
        guard manifest.databaseSchemaVersion >= Self.minimumSupportedBackupSchemaVersion else {
            throw ArchiveServiceError.invalidManifest
        }
        let paths = manifest.files.map(\.path)
        let expectedMigrations = Array(
            DatabaseMigrations.identifiers.prefix(manifest.databaseSchemaVersion)
        )
        guard manifest.formatIdentifier == Self.backupFormatIdentifier,
              manifest.formatVersion == Self.backupFormatVersion,
              manifest.databaseMigrations == expectedMigrations,
              BackupKind(rawValue: manifest.backupKind) != nil,
              manifest.files == manifest.files.sorted(by: { $0.path < $1.path }),
              Set(paths).count == paths.count,
              Set(paths.map(Self.canonicalCollisionKey)).count == paths.count,
              paths.contains("library/notes.sqlite"),
              manifest.files.allSatisfy({ entry in
                  entry.byteSize >= 0
                      && Self.isLowercaseSHA256(entry.sha256)
                      && Self.isSafeBackupPath(entry.path)
                      && Self.allowedBackupRoles.contains(entry.role)
              }) else {
            throw ArchiveServiceError.invalidManifest
        }
        return manifest
    }

    fileprivate static func isSafeBackupPath(_ path: String) -> Bool {
        guard isSafeRelativePath(path) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components == ["library", "notes.sqlite"] {
            return true
        }
        if components.count == 4,
           components[0...2] == ["library", "attachments", "originals"] {
            return isManagedOriginalFilename(components[3])
        }
        if components.count == 4,
           components[0...2] == ["library", "attachments", "thumbnails"] {
            return isUUIDPNG(components[3])
        }
        if components.count == 3,
           components[0...1] == ["library", "previews"] {
            return isUUIDPNG(components[2])
        }
        if components.count == 3,
           components[0...1] == ["library", "staging"] {
            return isStagingFilename(components[2])
        }
        return false
    }

    fileprivate static func isSafePortablePath(_ path: String) -> Bool {
        path == "export.json" || path == "notes.md" || isSafePortableAttachmentPath(path)
    }

    fileprivate static func isValidPortableRole(_ role: String, for path: String) -> Bool {
        switch path {
        case "export.json":
            role == "portableJSON"
        case "notes.md":
            role == "markdown"
        default:
            role == "attachmentOriginal" && isSafePortableAttachmentPath(path)
        }
    }

    fileprivate static func isValidPortableNote(_ note: PortableNote) -> Bool {
        let attachmentsAreOrdered = note.attachments
            == note.attachments.sorted(by: portableAttachmentOrder)
        let previewsAreOrdered = note.linkPreviews == note.linkPreviews.sorted {
            if $0.createdAtMilliseconds != $1.createdAtMilliseconds {
                return $0.createdAtMilliseconds < $1.createdAtMilliseconds
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        return note.sortKey > 0
            && note.linkPreviewRevision >= 0
            && attachmentsAreOrdered
            && previewsAreOrdered
            && note.attachments.allSatisfy { attachment in
                let dimensionsAreValid = (attachment.width == nil && attachment.height == nil)
                    || ((attachment.width ?? 0) > 0 && (attachment.height ?? 0) > 0)
                return !attachment.originalFilename.isEmpty
                    && !attachment.mediaType.isEmpty
                    && attachment.byteSize >= 0
                    && attachment.sortIndex >= 0
                    && dimensionsAreValid
                    && isLowercaseSHA256(attachment.contentHash)
                    && isSafePortableAttachmentPath(attachment.exportedPath)
            }
            && note.linkPreviews.allSatisfy { preview in
                !preview.originalURL.isEmpty
                    && !preview.requestKey.isEmpty
                    && LinkPreviewStatus(rawValue: preview.status) != nil
                    && preview.reconciledRevision >= 0
            }
    }

    fileprivate static func isSafePortableAttachmentPath(_ path: String) -> Bool {
        guard isSafeRelativePath(path) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2
            && components[0] == "attachments"
            && !components[1].isEmpty
            && components[1].utf8.count <= 220
    }

    fileprivate static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains(":"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    fileprivate static func isManagedOriginalFilename(_ filename: String) -> Bool {
        guard filename == filename.lowercased(),
              filename.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "."
              }) else {
            return false
        }
        let components = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              isCanonicalLowercaseUUID(String(components[0])),
              !components[1].isEmpty else {
            return false
        }
        return components[1].unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    fileprivate static func isUUIDPNG(_ filename: String) -> Bool {
        filename.hasSuffix(".png")
            && isCanonicalLowercaseUUID(String(filename.dropLast(4)))
    }

    fileprivate static func isStagingFilename(_ filename: String) -> Bool {
        for suffix in [".original.stage", ".thumbnail.png"]
        where filename.hasSuffix(suffix) {
            return isCanonicalLowercaseUUID(String(filename.dropLast(suffix.count)))
        }
        return false
    }

    fileprivate static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    fileprivate func createBackupDirectories(at packageURL: URL) throws {
        try createControlledDirectory(packageURL)
        for path in Self.backupDirectoryPaths.sorted() {
            try fileManager.createDirectory(
                at: packageURL.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    fileprivate func synchronizeBackupTree(at packageURL: URL) throws {
        let deepestFirst = Self.backupDirectoryPaths.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            return lhsDepth == rhsDepth ? lhs < rhs : lhsDepth > rhsDepth
        }
        for path in deepestFirst {
            try synchronizeDirectory(
                packageURL.appendingPathComponent(path, isDirectory: true)
            )
        }
        try synchronizeDirectory(packageURL)
    }

    fileprivate func createControlledDirectory(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ArchiveServiceError.destinationAlreadyExists
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    fileprivate func activeLibraryURL(for backupPath: String) -> URL {
        let prefix = "library/"
        precondition(backupPath.hasPrefix(prefix))
        return provider.rootURL.appendingPathComponent(String(backupPath.dropFirst(prefix.count)))
    }

    fileprivate func expectedBackupRecords(
        contents: DatabaseArchiveContents,
        databaseURL: URL
    ) throws -> [ArchiveFileRecord] {
        let packageRoot = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        var records = [try fileRecord(
            at: databaseURL,
            relativePath: "library/notes.sqlite",
            role: "database"
        )]
        for requirement in contents.requirements {
            let measured = try hashRegularFile(
                at: packageRoot.appendingPathComponent(requirement.path),
                includeData: false
            )
            records.append(
                ArchiveFileRecord(
                    path: requirement.path,
                    byteSize: measured.byteSize,
                    sha256: measured.sha256,
                    role: requirement.role
                )
            )
        }
        return records.sorted { $0.path < $1.path }
    }

    fileprivate func verifyDatabaseOwnedFileHashes(
        _ requirements: [ManagedFileRequirement],
        packageRoot: URL
    ) throws {
        for requirement in requirements {
            guard requirement.expectedByteSize != nil || requirement.expectedSHA256 != nil else {
                continue
            }
            let measured = try hashRegularFile(
                at: packageRoot.appendingPathComponent(requirement.path),
                includeData: false
            )
            if let expectedByteSize = requirement.expectedByteSize,
               measured.byteSize != expectedByteSize {
                throw ArchiveServiceError.databaseFileMetadataMismatch(requirement.path)
            }
            if let expectedSHA256 = requirement.expectedSHA256,
               measured.sha256 != expectedSHA256 {
                throw ArchiveServiceError.databaseFileMetadataMismatch(requirement.path)
            }
        }
    }

    fileprivate func validateExactPackageEntries(
        packageURL: URL,
        expectedFilePaths: Set<String>,
        allowedDirectories: Set<String>
    ) throws {
        let rootValues = try packageURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ArchiveServiceError.invalidPackageEntry(packageURL.lastPathComponent)
        }
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ArchiveServiceError.invalidManifest
        }
        let canonicalRootPath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalRootPrefix = canonicalRootPath.hasSuffix("/")
            ? canonicalRootPath
            : canonicalRootPath + "/"
        var foundFiles = Set<String>()
        var foundCanonicalPaths = Set<String>()
        for case let url as URL in enumerator {
            let candidatePath = url.standardizedFileURL.path
            guard candidatePath.hasPrefix(canonicalRootPrefix) else {
                throw ArchiveServiceError.invalidPackageEntry(url.lastPathComponent)
            }
            let relative = String(candidatePath.dropFirst(canonicalRootPrefix.count))
            guard Self.isSafeRelativePath(relative) else {
                throw ArchiveServiceError.invalidPackageEntry(relative)
            }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw ArchiveServiceError.invalidPackageEntry(relative)
            }
            if values.isDirectory == true {
                guard allowedDirectories.contains(relative) else {
                    throw ArchiveServiceError.invalidPackageEntry(relative)
                }
            } else if values.isRegularFile == true {
                guard foundCanonicalPaths.insert(Self.canonicalCollisionKey(relative)).inserted else {
                    throw ArchiveServiceError.invalidPackageEntry(relative)
                }
                foundFiles.insert(relative)
            } else {
                throw ArchiveServiceError.invalidPackageEntry(relative)
            }
        }
        guard foundFiles == expectedFilePaths else {
            throw ArchiveServiceError.inventoryMismatch
        }
    }

    fileprivate func fileRecord(
        at url: URL,
        relativePath: String,
        role: String
    ) throws -> ArchiveFileRecord {
        let measured = try hashRegularFile(at: url, includeData: false)
        return ArchiveFileRecord(
            path: relativePath,
            byteSize: measured.byteSize,
            sha256: measured.sha256,
            role: role
        )
    }

    fileprivate func copyRegularFile(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteSize: Int64? = nil,
        expectedSHA256: String? = nil,
        includeData: Bool = false
    ) throws -> MeasuredFile {
        let sourceDescriptor = try openRegularFile(sourceURL, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? sourceHandle.close() }
        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0 else {
            throw ArchiveServiceError.fileSystemFailure("Could not inspect “\(sourceURL.lastPathComponent)”.")
        }
        if let expectedByteSize, before.st_size != expectedByteSize {
            throw ArchiveServiceError.databaseFileMetadataMismatch(sourceURL.lastPathComponent)
        }

        let destinationDescriptor = try openRegularFile(
            destinationURL,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        var hasher = SHA256()
        var size: Int64 = 0
        var captured = includeData ? Data() : nil
        do {
            while let chunk = try sourceHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                size += Int64(chunk.count)
                captured?.append(chunk)
                try destinationHandle.write(contentsOf: chunk)
            }
            try destinationHandle.synchronize()
            try destinationHandle.close()
        } catch {
            try? destinationHandle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        var after = stat()
        guard fstat(sourceDescriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              size == before.st_size else {
            try? fileManager.removeItem(at: destinationURL)
            throw ArchiveServiceError.packageChangedDuringRead(sourceURL.lastPathComponent)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard expectedSHA256.map({ $0 == digest }) ?? true else {
            try? fileManager.removeItem(at: destinationURL)
            throw ArchiveServiceError.databaseFileMetadataMismatch(sourceURL.lastPathComponent)
        }
        return MeasuredFile(byteSize: size, sha256: digest, data: captured)
    }

    fileprivate func hashRegularFile(
        at url: URL,
        includeData: Bool,
        maximumByteCount: Int64? = nil
    ) throws -> MeasuredFile {
        let descriptor = try openRegularFile(url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw ArchiveServiceError.fileSystemFailure("Could not inspect “\(url.lastPathComponent)”.")
        }
        if let maximumByteCount, before.st_size > maximumByteCount {
            throw ArchiveServiceError.invalidManifest
        }
        var hasher = SHA256()
        var size: Int64 = 0
        var captured = includeData ? Data() : nil
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
            if let maximumByteCount, size > maximumByteCount {
                throw ArchiveServiceError.invalidManifest
            }
            captured?.append(chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              size == before.st_size else {
            throw ArchiveServiceError.packageChangedDuringRead(url.lastPathComponent)
        }
        return MeasuredFile(
            byteSize: size,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            data: captured
        )
    }

    fileprivate func readRegularData(at url: URL, maximumByteCount: Int) throws -> Data {
        let measured = try hashRegularFile(
            at: url,
            includeData: true,
            maximumByteCount: Int64(maximumByteCount)
        )
        guard measured.byteSize <= maximumByteCount, let data = measured.data else {
            throw ArchiveServiceError.invalidManifest
        }
        return data
    }

    fileprivate func verifiedPortableData(
        at url: URL,
        record: ArchiveFileRecord
    ) throws -> Data {
        let measured = try hashRegularFile(
            at: url,
            includeData: true,
            maximumByteCount: 1_073_741_824
        )
        guard measured.byteSize <= 1_073_741_824,
              measured.byteSize == record.byteSize,
              measured.sha256 == record.sha256,
              let data = measured.data else {
            throw ArchiveServiceError.checksumMismatch(record.path)
        }
        return data
    }

    fileprivate func openRegularFile(
        _ url: URL,
        flags: Int32,
        mode: mode_t = 0
    ) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, flags, mode)
        }
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw ArchiveServiceError.fileSystemFailure(
                "Could not open “\(url.lastPathComponent)”: \(POSIXError(code).localizedDescription)"
            )
        }
        if flags & O_CREAT == 0 {
            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(descriptor)
                throw ArchiveServiceError.invalidPackageEntry(url.lastPathComponent)
            }
        }
        return descriptor
    }

    fileprivate func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw ArchiveServiceError.fileSystemFailure(
                "Could not open directory “\(url.lastPathComponent)”: \(POSIXError(code).localizedDescription)"
            )
        }
        return descriptor
    }

    fileprivate func synchronizeRegularFile(_ url: URL) throws {
        let descriptor = try openRegularFile(url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ArchiveServiceError.fileSystemFailure("Could not synchronize “\(url.lastPathComponent)”.")
        }
    }

    fileprivate func synchronizeDirectory(_ url: URL) throws {
        let descriptor = try openDirectory(url)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ArchiveServiceError.fileSystemFailure("Could not synchronize “\(url.lastPathComponent)”.")
        }
    }

    fileprivate func writeDurable(_ data: Data, to url: URL) throws {
        let descriptor = try openRegularFile(
            url,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    fileprivate func publishDirectory(_ partialURL: URL, as finalURL: URL) throws {
        let parentURL = partialURL.deletingLastPathComponent()
        guard parentURL.standardizedFileURL == finalURL.deletingLastPathComponent().standardizedFileURL else {
            throw ArchiveServiceError.destinationIsNotSafeDirectory
        }
        let parentDescriptor = try openDirectory(parentURL)
        defer { Darwin.close(parentDescriptor) }
        let result = partialURL.lastPathComponent.withCString { partialName in
            finalURL.lastPathComponent.withCString { finalName in
                renameatx_np(
                    parentDescriptor,
                    partialName,
                    parentDescriptor,
                    finalName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw ArchiveServiceError.fileSystemFailure(
                "Could not publish the verified package without overwriting another item: \(POSIXError(code).localizedDescription)"
            )
        }
        guard fsync(parentDescriptor) == 0 else {
            throw ArchiveServiceError.fileSystemFailure(
                "The package was published, but its destination folder could not be synchronized."
            )
        }
    }

    fileprivate static func canonicalCollisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    fileprivate static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    fileprivate static func filenameTimestamp(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        return String(
            format: "%04d-%02d-%02d %02d%02d%02dZ",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    fileprivate static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}

extension ArchiveService {
    fileprivate func allocateExportPaths(
        notes: [DatabaseArchiveNote]
    ) throws -> [AllocatedArchiveNote] {
        var usedKeys = Set<String>()
        return notes.map { note in
            let attachments = note.attachments.map { attachment in
                var filename = Self.safeExportFilename(attachment.originalFilename)
                var key = Self.canonicalCollisionKey(filename)
                if usedKeys.contains(key) {
                    filename = Self.filename(
                        filename,
                        appendingStableIdentifier: attachment.id
                    )
                    key = Self.canonicalCollisionKey(filename)
                }
                var attempt = 2
                while usedKeys.contains(key) {
                    filename = Self.filename(
                        Self.safeExportFilename(attachment.originalFilename),
                        appending: " (\(attempt)) [\(attachment.id.uuidString.lowercased())]"
                    )
                    key = Self.canonicalCollisionKey(filename)
                    attempt += 1
                }
                usedKeys.insert(key)
                var allocated = attachment
                allocated.exportedPath = "attachments/\(filename)"
                return allocated
            }
            return AllocatedArchiveNote(note: note, attachments: attachments)
        }
    }

    fileprivate static func safeExportFilename(_ original: String) -> String {
        let normalized = original.precomposedStringWithCanonicalMapping
        var result = ""
        for scalar in normalized.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":"
                || CharacterSet.controlCharacters.contains(scalar) {
                result.append("_")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        while result.last == "." || result.last == " " { result.removeLast() }
        if result.isEmpty || result == "." || result == ".." {
            result = "attachment"
        }
        while result.utf8.count > 180, !result.isEmpty { result.removeLast() }
        return result.isEmpty ? "attachment" : result
    }

    fileprivate static func filename(
        _ filename: String,
        appendingStableIdentifier id: UUID
    ) -> String {
        Self.filename(
            filename,
            appending: " [\(id.uuidString.lowercased())]"
        )
    }

    fileprivate static func filename(_ filename: String, appending suffix: String) -> String {
        let ns = filename as NSString
        let pathExtension = ns.pathExtension
        var stem = pathExtension.isEmpty
            ? filename
            : ns.deletingPathExtension
        let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        while (stem + suffix + extensionSuffix).utf8.count > 210, !stem.isEmpty {
            stem.removeLast()
        }
        return (stem.isEmpty ? "attachment" : stem) + suffix + extensionSuffix
    }

    fileprivate static func markdown(for archive: PortableArchive) -> String {
        markdown(for: archive, includesThreadMetadata: true)
    }

    fileprivate static func legacyMarkdown(for archive: PortableArchive) -> String {
        markdown(for: archive, includesThreadMetadata: false)
    }

    private static func markdown(
        for archive: PortableArchive,
        includesThreadMetadata: Bool
    ) -> String {
        var output = "# Self DM Notes portable export\n\n"
        output += "- Format: `\(archive.formatIdentifier)` version \(archive.formatVersion)\n"
        output += "- Exported: \(utcTimestamp(archive.exportedAtMilliseconds))\n"
        output += "- Notes: \(archive.notes.count)\n\n"
        output += "Notes are listed in original chronological order. Deleted notes remain marked as Trash.\n\n"

        for note in archive.notes {
            output += "---\n\n"
            output += "## \(utcTimestamp(note.createdAtMilliseconds))"
            output += note.deletedAtMilliseconds == nil ? " — Active\n\n" : " — Trash\n\n"
            output += "- Note ID: `\(note.id.uuidString.lowercased())`\n"
            output += "- Sort key: \(note.sortKey)\n"
            if includesThreadMetadata {
                if let threadRootID = note.threadRootID {
                    output += "- Thread root ID: `\(threadRootID.uuidString.lowercased())`\n"
                } else {
                    output += "- Thread: Root note\n"
                }
            }
            output += "- Link-preview revision: \(note.linkPreviewRevision)\n"
            if let updated = note.updatedAtMilliseconds {
                output += "- Edited: \(utcTimestamp(updated))\n"
            }
            if let deleted = note.deletedAtMilliseconds {
                output += "- Deleted: \(utcTimestamp(deleted))\n"
            }
            if !note.body.isEmpty {
                let fence = markdownFence(for: note.body)
                output += "\n### Text\n\n\(fence)text\n\(note.body)\n\(fence)\n"
            }
            if !note.attachments.isEmpty {
                output += "\n### Attachments\n\n"
                for attachment in note.attachments.sorted(by: Self.portableAttachmentOrder) {
                    output += "- [\(escapeMarkdownLabel(attachment.originalFilename))]"
                    output += "(\(percentEncodedRelativePath(attachment.exportedPath)))"
                    output += " — attachment ID `\(attachment.id.uuidString.lowercased())`"
                    output += " — `\(attachment.mediaType)`, \(attachment.byteSize) bytes, SHA-256 `\(attachment.contentHash)`"
                    output += ", created \(utcTimestamp(attachment.createdAtMilliseconds))\n"
                }
            }
            if !note.linkPreviews.isEmpty {
                output += "\n### Links and previews\n\n"
                for preview in note.linkPreviews {
                    output += "- `\(preview.originalURL.replacingOccurrences(of: "`", with: "\\`"))`"
                    output += " — preview ID `\(preview.id.uuidString.lowercased())`, status `\(preview.status)`"
                    if let title = preview.title { output += ", title “\(title)”" }
                    if let siteName = preview.siteName { output += ", site “\(siteName)”" }
                    output += "\n"
                    output += "  - Request key: `\(preview.requestKey)`\n"
                    output += "  - Created: \(utcTimestamp(preview.createdAtMilliseconds))\n"
                    output += "  - Updated: \(utcTimestamp(preview.updatedAtMilliseconds))\n"
                    output += "  - Reconciled revision: \(preview.reconciledRevision)\n"
                    if let nextFetch = preview.nextFetchAtMilliseconds {
                        output += "  - Next fetch: \(utcTimestamp(nextFetch))\n"
                    }
                    if let canonical = preview.canonicalURL {
                        output += "  - Canonical URL: `\(canonical.replacingOccurrences(of: "`", with: "\\`"))`\n"
                    }
                    if let summary = preview.summary { output += "  - Summary: \(summary)\n" }
                    if let imageURL = preview.imageURL {
                        output += "  - Remote image URL: `\(imageURL.replacingOccurrences(of: "`", with: "\\`"))`\n"
                    }
                    if let fetched = preview.fetchedAtMilliseconds {
                        output += "  - Metadata fetched: \(utcTimestamp(fetched))\n"
                    }
                    if let retryAfter = preview.retryAfterMilliseconds {
                        output += "  - Cache retry after: \(utcTimestamp(retryAfter))\n"
                    }
                    if let failure = preview.failureReason { output += "  - Failure: \(failure)\n" }
                }
            }
            output += "\n"
        }
        return output
    }

    fileprivate static func portableAttachmentOrder(
        _ lhs: PortableAttachment,
        _ rhs: PortableAttachment
    ) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    fileprivate static func markdownFence(for body: String) -> String {
        var longest = 0
        var current = 0
        for character in body {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    fileprivate static func escapeMarkdownLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    fileprivate static func percentEncodedRelativePath(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~/")
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    fileprivate static func utcTimestamp(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        let fractional = abs(milliseconds % 1_000)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03lldZ",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            fractional
        )
    }
}

enum ArchiveDatabaseInspector {
    static func inspect(
        databaseURL: URL,
        includePortableNotes: Bool
    ) throws -> DatabaseArchiveContents {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { database in
            try inspect(
                database: database,
                includePortableNotes: includePortableNotes
            )
        }
    }

    static func inspect(
        database: Database,
        includePortableNotes: Bool
    ) throws -> DatabaseArchiveContents {
        let integrity = try String.fetchAll(database, sql: "PRAGMA integrity_check")
        guard integrity == ["ok"] else {
            throw ArchiveServiceError.invalidDatabase(integrity.joined(separator: "; "))
        }
        guard try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw ArchiveServiceError.foreignKeyCheckFailed
        }
        let applied = try String.fetchAll(
            database,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
        )
        guard !applied.isEmpty,
              DatabaseMigrations.identifiers.starts(with: applied) else {
            throw ArchiveServiceError.incompatibleDatabaseSchema
        }

        let requirements = try managedRequirements(database)
        let noteCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM notes") ?? 0
        let notes = includePortableNotes ? try portableNotes(database) : nil
        return DatabaseArchiveContents(
            migrations: applied,
            requirements: requirements,
            noteCount: noteCount,
            notes: notes
        )
    }

    private static func managedRequirements(_ database: Database) throws -> [ManagedFileRequirement] {
        var requirements: [ManagedFileRequirement] = []
        let blobRows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, contentHash, storedFilename, thumbnailFilename, byteSize
                FROM attachment_blobs
                ORDER BY storedFilename
                """
        )
        for row in blobRows {
            let idString: String = row["id"]
            let storedFilename: String = row["storedFilename"]
            let hash: String = row["contentHash"]
            let size: Int64 = row["byteSize"]
            guard let id = UUID(uuidString: idString),
                  id.uuidString.lowercased() == storedFilename.split(separator: ".").first.map(String.init),
                  ArchiveService.isManagedOriginalFilename(storedFilename),
                  ArchiveService.isLowercaseSHA256(hash),
                  size >= 0 else {
                throw ArchiveServiceError.invalidManagedFilename(storedFilename)
            }
            requirements.append(
                ManagedFileRequirement(
                    path: "library/attachments/originals/\(storedFilename)",
                    role: "attachmentOriginal",
                    expectedByteSize: size,
                    expectedSHA256: hash
                )
            )
            if let thumbnail: String = row["thumbnailFilename"] {
                guard thumbnail == "\(id.uuidString.lowercased()).png",
                      ArchiveService.isUUIDPNG(thumbnail) else {
                    throw ArchiveServiceError.invalidManagedFilename(thumbnail)
                }
                requirements.append(
                    ManagedFileRequirement(
                        path: "library/attachments/thumbnails/\(thumbnail)",
                        role: "attachmentThumbnail",
                        expectedByteSize: nil,
                        expectedSHA256: nil
                    )
                )
            }
        }

        let draftRows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, stagingFilename, thumbnailStagingFilename,
                       byteSize, contentHash
                FROM draft_attachments
                ORDER BY stagingFilename
                """
        )
        for row in draftRows {
            let idString: String = row["id"]
            let staging: String = row["stagingFilename"]
            let hash: String = row["contentHash"]
            let size: Int64 = row["byteSize"]
            guard let id = UUID(uuidString: idString),
                  staging == "\(id.uuidString.lowercased()).original.stage",
                  ArchiveService.isStagingFilename(staging),
                  ArchiveService.isLowercaseSHA256(hash),
                  size >= 0 else {
                throw ArchiveServiceError.invalidManagedFilename(staging)
            }
            requirements.append(
                ManagedFileRequirement(
                    path: "library/staging/\(staging)",
                    role: "draftOriginal",
                    expectedByteSize: size,
                    expectedSHA256: hash
                )
            )
            if let thumbnail: String = row["thumbnailStagingFilename"] {
                guard thumbnail == "\(id.uuidString.lowercased()).thumbnail.png",
                      ArchiveService.isStagingFilename(thumbnail) else {
                    throw ArchiveServiceError.invalidManagedFilename(thumbnail)
                }
                requirements.append(
                    ManagedFileRequirement(
                        path: "library/staging/\(thumbnail)",
                        role: "draftThumbnail",
                        expectedByteSize: nil,
                        expectedSHA256: nil
                    )
                )
            }
        }

        let previewNames = try String.fetchAll(
            database,
            sql: """
                SELECT localImageFilename
                FROM link_preview_cache
                WHERE localImageFilename IS NOT NULL
                ORDER BY localImageFilename
                """
        )
        for filename in previewNames {
            guard ArchiveService.isUUIDPNG(filename) else {
                throw ArchiveServiceError.invalidManagedFilename(filename)
            }
            requirements.append(
                ManagedFileRequirement(
                    path: "library/previews/\(filename)",
                    role: "previewImage",
                    expectedByteSize: nil,
                    expectedSHA256: nil
                )
            )
        }
        requirements.sort { $0.path < $1.path }
        let paths = requirements.map(\.path)
        guard Set(paths).count == paths.count,
              Set(paths.map(ArchiveService.canonicalCollisionKey)).count == paths.count else {
            throw ArchiveServiceError.inventoryMismatch
        }
        return requirements
    }

    private static func portableNotes(_ database: Database) throws -> [DatabaseArchiveNote] {
        let noteRows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, body, createdAt, updatedAt, deletedAt, sortKey,
                       linkPreviewRevision, threadRootID
                FROM notes
                ORDER BY sortKey ASC
                """
        )
        var attachmentsByNote: [UUID: [DatabaseArchiveAttachment]] = [:]
        let attachmentRows = try Row.fetchAll(
            database,
            sql: """
                SELECT attachments.id, attachments.noteID,
                       attachments.originalFilename, attachments.createdAt,
                       attachments.sortIndex, attachment_blobs.mediaType,
                       attachment_blobs.byteSize, attachment_blobs.width,
                       attachment_blobs.height, attachment_blobs.contentHash,
                       attachment_blobs.storedFilename
                FROM attachments
                JOIN attachment_blobs ON attachment_blobs.id = attachments.blobID
                ORDER BY attachments.noteID, attachments.sortIndex,
                         attachments.createdAt, attachments.id
                """
        )
        for row in attachmentRows {
            let idString: String = row["id"]
            let noteIDString: String = row["noteID"]
            let hash: String = row["contentHash"]
            let storedFilename: String = row["storedFilename"]
            guard let id = UUID(uuidString: idString),
                  let noteID = UUID(uuidString: noteIDString),
                  ArchiveService.isLowercaseSHA256(hash),
                  ArchiveService.isManagedOriginalFilename(storedFilename) else {
                throw ArchiveServiceError.invalidDatabase("An attachment row is malformed.")
            }
            attachmentsByNote[noteID, default: []].append(
                DatabaseArchiveAttachment(
                    id: id,
                    originalFilename: row["originalFilename"],
                    mediaType: row["mediaType"],
                    byteSize: row["byteSize"],
                    width: row["width"],
                    height: row["height"],
                    contentHash: hash,
                    createdAtMilliseconds: row["createdAt"],
                    sortIndex: row["sortIndex"],
                    managedFilename: storedFilename,
                    exportedPath: ""
                )
            )
        }

        var previewsByNote: [UUID: [PortableLinkPreview]] = [:]
        let previewRows = try Row.fetchAll(
            database,
            sql: """
                SELECT link_previews.id, link_previews.noteID,
                       link_previews.originalURL, link_previews.requestKey,
                       link_previews.status, link_previews.failureReason,
                       link_previews.createdAt, link_previews.updatedAt,
                       link_previews.nextFetchAt, link_previews.reconciledRevision,
                       link_preview_cache.canonicalURL, link_preview_cache.title,
                       link_preview_cache.summary, link_preview_cache.imageURL,
                       link_preview_cache.siteName, link_preview_cache.fetchedAt,
                       link_preview_cache.retryAfter
                FROM link_previews
                LEFT JOIN link_preview_cache
                    ON link_preview_cache.requestKey = link_previews.requestKey
                ORDER BY link_previews.noteID, link_previews.createdAt, link_previews.id
                """
        )
        for row in previewRows {
            let idString: String = row["id"]
            let noteIDString: String = row["noteID"]
            let status: String = row["status"]
            guard let id = UUID(uuidString: idString),
                  let noteID = UUID(uuidString: noteIDString),
                  LinkPreviewStatus(rawValue: status) != nil else {
                throw ArchiveServiceError.invalidDatabase("A link-preview row is malformed.")
            }
            previewsByNote[noteID, default: []].append(
                PortableLinkPreview(
                    id: id,
                    originalURL: row["originalURL"],
                    requestKey: row["requestKey"],
                    status: status,
                    failureReason: row["failureReason"],
                    createdAtMilliseconds: row["createdAt"],
                    updatedAtMilliseconds: row["updatedAt"],
                    nextFetchAtMilliseconds: row["nextFetchAt"],
                    reconciledRevision: row["reconciledRevision"],
                    canonicalURL: row["canonicalURL"],
                    title: row["title"],
                    summary: row["summary"],
                    imageURL: row["imageURL"],
                    siteName: row["siteName"],
                    fetchedAtMilliseconds: row["fetchedAt"],
                    retryAfterMilliseconds: row["retryAfter"]
                )
            )
        }

        return try noteRows.map { row in
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw ArchiveServiceError.invalidDatabase("A note identifier is malformed.")
            }
            let threadRootIDString: String? = row["threadRootID"]
            let threadRootID: UUID?
            if let threadRootIDString {
                guard let parsed = UUID(uuidString: threadRootIDString) else {
                    throw ArchiveServiceError.invalidDatabase("A thread root identifier is malformed.")
                }
                threadRootID = parsed
            } else {
                threadRootID = nil
            }
            return DatabaseArchiveNote(
                id: id,
                body: row["body"],
                createdAtMilliseconds: row["createdAt"],
                updatedAtMilliseconds: row["updatedAt"],
                deletedAtMilliseconds: row["deletedAt"],
                sortKey: row["sortKey"],
                threadRootID: threadRootID,
                linkPreviewRevision: row["linkPreviewRevision"],
                attachments: attachmentsByNote[id] ?? [],
                linkPreviews: previewsByNote[id] ?? []
            )
        }
    }
}

struct ArchiveFileRecord: Codable, Equatable, Sendable {
    let path: String
    let byteSize: Int64
    let sha256: String
    let role: String
}

struct BackupPackageManifest: Codable, Equatable, Sendable {
    let formatIdentifier: String
    let formatVersion: Int
    let backupID: UUID
    let backupKind: String
    let createdAtMilliseconds: Int64
    let applicationVersion: String
    let buildVersion: String
    let databaseSchemaVersion: Int
    let databaseMigrations: [String]
    let files: [ArchiveFileRecord]
}

struct PortableExportManifest: Codable, Equatable, Sendable {
    let formatIdentifier: String
    let formatVersion: Int
    let exportID: UUID
    let createdAtMilliseconds: Int64
    let applicationVersion: String
    let buildVersion: String
    let files: [ArchiveFileRecord]
}

struct PortableArchive: Codable, Equatable, Sendable {
    let formatIdentifier: String
    let formatVersion: Int
    let exportID: UUID
    let exportedAtMilliseconds: Int64
    let notes: [PortableNote]
}

struct PortableNote: Codable, Equatable, Sendable {
    let id: UUID
    let body: String
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64?
    let deletedAtMilliseconds: Int64?
    let sortKey: Int64
    let threadRootID: UUID?
    let linkPreviewRevision: Int64
    let attachments: [PortableAttachment]
    let linkPreviews: [PortableLinkPreview]
}

struct PortableAttachment: Codable, Equatable, Sendable {
    let id: UUID
    let originalFilename: String
    let exportedPath: String
    let mediaType: String
    let byteSize: Int64
    let width: Int?
    let height: Int?
    let contentHash: String
    let createdAtMilliseconds: Int64
    let sortIndex: Int
}

struct PortableLinkPreview: Codable, Equatable, Sendable {
    let id: UUID
    let originalURL: String
    let requestKey: String
    let status: String
    let failureReason: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
    let nextFetchAtMilliseconds: Int64?
    let reconciledRevision: Int64
    let canonicalURL: String?
    let title: String?
    let summary: String?
    let imageURL: String?
    let siteName: String?
    let fetchedAtMilliseconds: Int64?
    let retryAfterMilliseconds: Int64?
}

struct ValidatedBackup: Sendable {
    let manifest: BackupPackageManifest
    let contents: DatabaseArchiveContents
}

struct DatabaseArchiveContents: Sendable {
    let migrations: [String]
    let requirements: [ManagedFileRequirement]
    let noteCount: Int
    let notes: [DatabaseArchiveNote]?
}

struct ManagedFileRequirement: Equatable, Sendable {
    let path: String
    let role: String
    let expectedByteSize: Int64?
    let expectedSHA256: String?
}

struct DatabaseArchiveNote: Equatable, Sendable {
    let id: UUID
    let body: String
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64?
    let deletedAtMilliseconds: Int64?
    let sortKey: Int64
    let threadRootID: UUID?
    let linkPreviewRevision: Int64
    let attachments: [DatabaseArchiveAttachment]
    let linkPreviews: [PortableLinkPreview]
}

struct DatabaseArchiveAttachment: Equatable, Sendable {
    let id: UUID
    let originalFilename: String
    let mediaType: String
    let byteSize: Int64
    let width: Int?
    let height: Int?
    let contentHash: String
    let createdAtMilliseconds: Int64
    let sortIndex: Int
    let managedFilename: String
    var exportedPath: String

    var portable: PortableAttachment {
        PortableAttachment(
            id: id,
            originalFilename: originalFilename,
            exportedPath: exportedPath,
            mediaType: mediaType,
            byteSize: byteSize,
            width: width,
            height: height,
            contentHash: contentHash,
            createdAtMilliseconds: createdAtMilliseconds,
            sortIndex: sortIndex
        )
    }
}

struct AllocatedArchiveNote: Sendable {
    let note: DatabaseArchiveNote
    let attachments: [DatabaseArchiveAttachment]

    var portable: PortableNote {
        PortableNote(
            id: note.id,
            body: note.body,
            createdAtMilliseconds: note.createdAtMilliseconds,
            updatedAtMilliseconds: note.updatedAtMilliseconds,
            deletedAtMilliseconds: note.deletedAtMilliseconds,
            sortKey: note.sortKey,
            threadRootID: note.threadRootID,
            linkPreviewRevision: note.linkPreviewRevision,
            attachments: attachments.map(\.portable),
            linkPreviews: note.linkPreviews
        )
    }
}

struct MeasuredFile {
    let byteSize: Int64
    let sha256: String
    let data: Data?
}

enum BackupKind: String, Codable {
    case manual
    case automatic
}

enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ArchiveServiceError: LocalizedError, Equatable {
    case backupFromNewerVersion
    case checksumMismatch(String)
    case databaseFileMetadataMismatch(String)
    case destinationAlreadyExists
    case destinationIsNotSafeDirectory
    case destinationOverlapsLibrary
    case fileSystemFailure(String)
    case foreignKeyCheckFailed
    case incompatibleDatabaseSchema
    case invalidDatabase(String)
    case invalidManagedFilename(String)
    case invalidManifest
    case invalidPackageEntry(String)
    case invalidPortableExport
    case inventoryDoesNotMatchDatabase
    case inventoryMismatch
    case missingRequiredDatabase
    case packageChangedDuringRead(String)
    case restoreAlreadyPending
    case restoreCancellationUnsafe
    case restoreCancellationCleanupPending(String)
    case restoreCommittedCleanupPending(String)
    case restoreResolutionRequired
    case restoreStateAmbiguous
    case restoreUnarmedCleanupPending(String)

    var errorDescription: String? {
        switch self {
        case .backupFromNewerVersion:
            "This backup was created by a newer Self DM Notes database version. Update the app before restoring it."
        case let .checksumMismatch(path):
            "The checksum for “\(path)” does not match the manifest. The package may be incomplete or corrupt."
        case let .databaseFileMetadataMismatch(path):
            "“\(path)” does not match the size or SHA-256 stored in the database."
        case .destinationAlreadyExists:
            "A file or folder already exists at the generated destination. Nothing was overwritten."
        case .destinationIsNotSafeDirectory:
            "The selected destination is not a regular, non-symbolic-link folder."
        case .destinationOverlapsLibrary:
            "Choose a destination outside the active library and its restore-recovery area."
        case let .fileSystemFailure(details):
            details
        case .foreignKeyCheckFailed:
            "SQLite found broken database relationships. The active library was not changed."
        case .incompatibleDatabaseSchema:
            "The backup database schema or migration history is not compatible with this app version."
        case let .invalidDatabase(details):
            "The SQLite snapshot did not pass integrity or semantic checks. Details: \(details)"
        case let .invalidManagedFilename(filename):
            "The database contains an unsafe managed filename: “\(filename)”."
        case .invalidManifest:
            "The package manifest is missing, malformed, unsorted, or incompatible."
        case let .invalidPackageEntry(path):
            "The package contains an unsafe file, folder, or alias: “\(path)”."
        case .invalidPortableExport:
            "The portable JSON does not match the export manifest."
        case .inventoryDoesNotMatchDatabase:
            "The backup inventory does not exactly match files referenced by its database."
        case .inventoryMismatch:
            "The package contains missing or unlisted items."
        case .missingRequiredDatabase:
            "The backup does not contain library/notes.sqlite."
        case let .packageChangedDuringRead(path):
            "“\(path)” changed while it was being read. Retry after other file operations finish."
        case .restoreAlreadyPending:
            "A restore is already staged or awaiting startup confirmation."
        case .restoreCancellationUnsafe:
            "The restore has crossed the atomic-switch boundary and can no longer be canceled safely."
        case let .restoreCancellationCleanupPending(details):
            "The original library remains active and the restore remains canceled, but staged-library cleanup did not finish. Reopen the app to resume cleanup. Details: \(details)"
        case let .restoreCommittedCleanupPending(details):
            "The current active library is durably accepted, but retained-library cleanup did not finish. Reopen the app to resume cleanup. Details: \(details)"
        case .restoreResolutionRequired:
            "Restore bookkeeping reached an uncertain durability boundary. Both library copies were preserved. Quit and reopen Self DM Notes before making more changes."
        case .restoreStateAmbiguous:
            "Restore recovery state is ambiguous. Both library copies were preserved; do not delete either one."
        case let .restoreUnarmedCleanupPending(details):
            "The active library was never switched, but unarmed restore staging cleanup did not finish. Reopen the app to resume cleanup. Details: \(details)"
        }
    }
}
