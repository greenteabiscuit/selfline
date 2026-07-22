import CryptoKit
import Darwin
import Foundation
import OSLog

enum DiagnosticEvent: String, Codable, Sendable {
    case applicationStartup
    case backup
    case libraryHealthCheck
    case portableExport
    case restore
    case supportInformationExport
}

enum DiagnosticOutcome: String, Codable, Sendable {
    case canceled
    case failed
    case started
    case succeeded
}

enum DiagnosticMetric: String, Sendable {
    case checksumMismatchCount
    case expectedManagedFileCount
    case inaccessibleManagedFileCount
    case issueCount
    case metadataMismatchCount
    case missingManagedFileCount
    case unexpectedManagedItemCount
    case unsafeManagedItemCount
}

struct RedactedDiagnosticRecord: Codable, Equatable, Sendable {
    let occurredAtMilliseconds: Int64
    let event: DiagnosticEvent
    let outcome: DiagnosticOutcome
    let metrics: [String: Int]
}

final class RedactedDiagnosticLog: @unchecked Sendable {
    static let shared = RedactedDiagnosticLog()

    private static let maximumRecordCount = 200

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.selfdmnotes.SelfDMNotes", category: "diagnostics")
    private var records: [RedactedDiagnosticRecord] = []

    func record(
        _ event: DiagnosticEvent,
        outcome: DiagnosticOutcome,
        metrics: [DiagnosticMetric: Int] = [:],
        now: Date = Date()
    ) {
        let safeMetrics = Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value) })
        let record = RedactedDiagnosticRecord(
            occurredAtMilliseconds: Self.milliseconds(now),
            event: event,
            outcome: outcome,
            metrics: safeMetrics
        )

        lock.lock()
        records.append(record)
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }
        lock.unlock()

        logger.notice("event=\(event.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
    }

    func snapshot() -> [RedactedDiagnosticRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

enum LibraryHealthStatus: String, Codable, Sendable {
    case healthy
    case needsAttention
    case unavailable
}

struct LibraryHealthReport: Codable, Equatable, Sendable {
    let checkedAtMilliseconds: Int64
    let status: LibraryHealthStatus
    let databaseSchemaVersion: Int
    let noteCount: Int?
    let expectedManagedFileCount: Int
    let missingManagedFileCount: Int
    let inaccessibleManagedFileCount: Int
    let metadataMismatchCount: Int
    let checksumMismatchCount: Int
    let unexpectedManagedItemCount: Int
    let unsafeManagedItemCount: Int
    let inaccessibleManagedDirectoryCount: Int

    var issueCount: Int {
        missingManagedFileCount
            + inaccessibleManagedFileCount
            + metadataMismatchCount
            + checksumMismatchCount
            + unexpectedManagedItemCount
            + unsafeManagedItemCount
            + inaccessibleManagedDirectoryCount
            + (status == .unavailable ? 1 : 0)
    }

    var summary: String {
        switch status {
        case .healthy:
            "SQLite integrity, database relationships, and all \(expectedManagedFileCount) referenced managed files passed checks."
        case .unavailable:
            "The database check could not complete. No library data was changed. Quit and reopen the app, then run the check again before relying on this result."
        case .needsAttention:
            "The check found \(issueCount) aggregate issue(s). No library data was changed. Create a new verified backup if possible, preserve the current Application Support folder, and review the counts below before deleting or replacing anything."
        }
    }
}

private struct ManagedFileHealthCounts: Sendable {
    var missing = 0
    var inaccessible = 0
    var metadataMismatch = 0
    var checksumMismatch = 0
    var unexpected = 0
    var unsafe = 0
    var inaccessibleDirectory = 0

    var hasIssues: Bool {
        missing > 0
            || inaccessible > 0
            || metadataMismatch > 0
            || checksumMismatch > 0
            || unexpected > 0
            || unsafe > 0
            || inaccessibleDirectory > 0
    }
}

final class LibraryHealthService: @unchecked Sendable {
    private static let copyBufferSize = 1_048_576
    private static let managedDirectories = [
        "attachments/originals",
        "attachments/thumbnails",
        "previews",
        "staging"
    ]

    private let provider: ApplicationSupportDirectoryProvider
    private let database: AppDatabase
    private let diagnostics: RedactedDiagnosticLog

    init(
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        diagnostics: RedactedDiagnosticLog = .shared
    ) {
        self.provider = provider
        self.database = database
        self.diagnostics = diagnostics
    }

    func check(now: Date = Date()) -> LibraryHealthReport {
        diagnostics.record(.libraryHealthCheck, outcome: .started, now: now)
        let checkedAt = Self.milliseconds(now)
        let contents: DatabaseArchiveContents
        do {
            contents = try database.inspectArchiveContents(includePortableNotes: false)
        } catch {
            let report = LibraryHealthReport(
                checkedAtMilliseconds: checkedAt,
                status: .unavailable,
                databaseSchemaVersion: DatabaseMigrations.currentSchemaVersion,
                noteCount: nil,
                expectedManagedFileCount: 0,
                missingManagedFileCount: 0,
                inaccessibleManagedFileCount: 0,
                metadataMismatchCount: 0,
                checksumMismatchCount: 0,
                unexpectedManagedItemCount: 0,
                unsafeManagedItemCount: 0,
                inaccessibleManagedDirectoryCount: 0
            )
            diagnostics.record(
                .libraryHealthCheck,
                outcome: .failed,
                metrics: [.issueCount: report.issueCount]
            )
            return report
        }

        let counts = inspectManagedFiles(requirements: contents.requirements)
        let status: LibraryHealthStatus = counts.hasIssues ? .needsAttention : .healthy
        let report = LibraryHealthReport(
            checkedAtMilliseconds: checkedAt,
            status: status,
            databaseSchemaVersion: DatabaseMigrations.currentSchemaVersion,
            noteCount: contents.noteCount,
            expectedManagedFileCount: contents.requirements.count,
            missingManagedFileCount: counts.missing,
            inaccessibleManagedFileCount: counts.inaccessible,
            metadataMismatchCount: counts.metadataMismatch,
            checksumMismatchCount: counts.checksumMismatch,
            unexpectedManagedItemCount: counts.unexpected,
            unsafeManagedItemCount: counts.unsafe,
            inaccessibleManagedDirectoryCount: counts.inaccessibleDirectory
        )
        diagnostics.record(
            .libraryHealthCheck,
            outcome: status == .healthy ? .succeeded : .failed,
            metrics: [
                .checksumMismatchCount: counts.checksumMismatch,
                .expectedManagedFileCount: contents.requirements.count,
                .inaccessibleManagedFileCount: counts.inaccessible,
                .issueCount: report.issueCount,
                .metadataMismatchCount: counts.metadataMismatch,
                .missingManagedFileCount: counts.missing,
                .unexpectedManagedItemCount: counts.unexpected,
                .unsafeManagedItemCount: counts.unsafe
            ]
        )
        return report
    }

    private func inspectManagedFiles(
        requirements: [ManagedFileRequirement]
    ) -> ManagedFileHealthCounts {
        var counts = ManagedFileHealthCounts()
        var expectedNamesByDirectory: [String: Set<String>] = [:]
        let directories = Dictionary(
            uniqueKeysWithValues: Self.managedDirectories.compactMap { path in
                openManagedDirectory(path: path).map { (path, $0) }
            }
        )
        counts.inaccessibleDirectory = Self.managedDirectories.count - directories.count

        for requirement in requirements {
            let relativePath = String(requirement.path.dropFirst("library/".count))
            let directoryPath = (relativePath as NSString).deletingLastPathComponent
            let filename = (relativePath as NSString).lastPathComponent
            expectedNamesByDirectory[directoryPath, default: []].insert(filename)

            guard let directory = directories[directoryPath] else {
                counts.inaccessible += 1
                continue
            }
            switch inspectReferencedFile(
                named: filename,
                in: directory.descriptor,
                requirement: requirement
            ) {
            case .valid:
                break
            case .missing:
                counts.missing += 1
            case .inaccessible:
                counts.inaccessible += 1
            case .metadataMismatch:
                counts.metadataMismatch += 1
            case .checksumMismatch:
                counts.checksumMismatch += 1
            case .unsafe:
                counts.unsafe += 1
            }
        }

        for directoryPath in Self.managedDirectories {
            guard let directory = directories[directoryPath] else { continue }
            let expectedNames = expectedNamesByDirectory[directoryPath] ?? []
            guard let entries = directoryEntries(descriptor: directory.descriptor) else {
                counts.inaccessibleDirectory += 1
                continue
            }
            for name in entries where !expectedNames.contains(name) {
                counts.unexpected += 1
                var information = stat()
                let result = name.withCString {
                    fstatat(directory.descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
                }
                if result != 0 || information.st_mode & S_IFMT != S_IFREG {
                    counts.unsafe += 1
                }
            }
        }
        return counts
    }

    private func openManagedDirectory(path: String) -> ManagedDirectoryDescriptor? {
        var descriptor = provider.rootURL.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else { return Int32(-1) }
            return Darwin.open(
                fileSystemPath,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { return nil }

        for component in path.split(separator: "/") {
            let nextDescriptor = String(component).withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                )
            }
            Darwin.close(descriptor)
            guard nextDescriptor >= 0 else { return nil }
            descriptor = nextDescriptor
        }
        return ManagedDirectoryDescriptor(descriptor)
    }

    private func directoryEntries(descriptor: Int32) -> [String]? {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return nil
        }
        defer { closedir(directory) }

        var entries: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != ".", name != ".." {
                entries.append(name)
            }
            errno = 0
        }
        return errno == 0 ? entries : nil
    }

    private enum ReferencedFileStatus {
        case valid
        case missing
        case inaccessible
        case metadataMismatch
        case checksumMismatch
        case unsafe
    }

    private func inspectReferencedFile(
        named filename: String,
        in directoryDescriptor: Int32,
        requirement: ManagedFileRequirement
    ) -> ReferencedFileStatus {
        let descriptor = filename.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                return .missing
            case ELOOP:
                return .unsafe
            default:
                return .inaccessible
            }
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { return .inaccessible }
        guard before.st_mode & S_IFMT == S_IFREG else { return .unsafe }
        if let expectedSize = requirement.expectedByteSize,
           before.st_size != expectedSize {
            return .metadataMismatch
        }
        if let expectedHash = requirement.expectedSHA256 {
            do {
                let measuredHash = try hash(descriptor: descriptor)
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino,
                      before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
                    return .inaccessible
                }
                guard measuredHash == expectedHash else {
                    return .checksumMismatch
                }
            } catch {
                return .inaccessible
            }
        }
        return .valid
    }

    private func hash(descriptor: Int32) throws -> String {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.copyBufferSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private final class ManagedDirectoryDescriptor {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}

enum SupportExportFault: Sendable {
    case none
    case failBeforePublication(POSIXErrorCode)
}

enum SupportServiceError: LocalizedError, Equatable {
    case destinationAlreadyExists
    case destinationIsNotSafe
    case destinationOverlapsLibrary
    case publicationDurabilityUncertain
    case simulatedFileSystemFailure(POSIXErrorCode)
    case writeFailed(POSIXErrorCode)

    var errorDescription: String? {
        switch self {
        case .destinationAlreadyExists:
            "A file already exists at that destination. Choose a new filename; support export never overwrites existing data."
        case .destinationIsNotSafe:
            "Choose an ordinary JSON file in a writable, non-symbolic-link folder."
        case .destinationOverlapsLibrary:
            "Choose a support-export destination outside the active Self DM Notes library."
        case .publicationDurabilityUncertain:
            "The support file may have been created, but its destination folder could not be synchronized. Verify the file before sending it."
        case let .simulatedFileSystemFailure(code), let .writeFailed(code):
            "The redacted support file was not created. Existing files were not changed. Details: \(POSIXError(code).localizedDescription)"
        }
    }
}

private struct SupportBackupSummary: Codable, Sendable {
    let automaticBackupsConfigured: Bool
    let lastAutomaticBackupSuccessMilliseconds: Int64?
}

private struct SupportStorageSummary: Codable, Sendable {
    let scope: String
    let cloudSyncEnabled: Bool
    let absolutePathIncluded: Bool
}

private struct SupportInformationPayload: Codable, Sendable {
    let formatIdentifier: String
    let formatVersion: Int
    let generatedAtMilliseconds: Int64
    let applicationVersion: String
    let buildVersion: String
    let operatingSystemVersion: String
    let architecture: String
    let databaseSchemaVersion: Int
    let databaseMigrations: [String]
    let storage: SupportStorageSummary
    let backup: SupportBackupSummary
    let health: LibraryHealthReport
    let diagnostics: [RedactedDiagnosticRecord]
    let intentionallyExcluded: [String]
}

final class SupportService: @unchecked Sendable {
    static let formatIdentifier = "com.selfdmnotes.support-information"
    static let formatVersion = 1

    let libraryLocation: URL
    let applicationVersion: String
    let buildVersion: String

    private let provider: ApplicationSupportDirectoryProvider
    private let archiveService: ArchiveService
    private let healthService: LibraryHealthService
    private let diagnostics: RedactedDiagnosticLog
    private let exportFault: SupportExportFault

    init(
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        archiveService: ArchiveService,
        diagnostics: RedactedDiagnosticLog = .shared,
        applicationVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        buildVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown",
        exportFault: SupportExportFault = .none
    ) {
        self.provider = provider
        self.archiveService = archiveService
        self.diagnostics = diagnostics
        self.applicationVersion = applicationVersion
        self.buildVersion = buildVersion
        self.exportFault = exportFault
        libraryLocation = provider.rootURL
        healthService = LibraryHealthService(
            provider: provider,
            database: database,
            diagnostics: diagnostics
        )
    }

    var automaticBackupStatus: String {
        guard archiveService.hasAutomaticBackupDirectory else {
            return "Automatic backups are off."
        }
        guard let lastSuccess = archiveService.lastAutomaticBackupSuccessDate else {
            return "Automatic backups are configured; no successful automatic backup is recorded yet."
        }
        return "Automatic backups are configured. Last success: \(lastSuccess.formatted(date: .complete, time: .standard))."
    }

    func checkLibrary(now: Date = Date()) -> LibraryHealthReport {
        healthService.check(now: now)
    }

    func exportSupportInformation(
        to destinationURL: URL,
        latestHealthReport: LibraryHealthReport? = nil,
        now: Date = Date()
    ) throws -> URL {
        diagnostics.record(.supportInformationExport, outcome: .started, now: now)
        let health = latestHealthReport ?? healthService.check(now: now)
        let payload = SupportInformationPayload(
            formatIdentifier: Self.formatIdentifier,
            formatVersion: Self.formatVersion,
            generatedAtMilliseconds: Self.milliseconds(now),
            applicationVersion: applicationVersion,
            buildVersion: buildVersion,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            databaseSchemaVersion: DatabaseMigrations.currentSchemaVersion,
            databaseMigrations: DatabaseMigrations.identifiers,
            storage: SupportStorageSummary(
                scope: "Local user Application Support",
                cloudSyncEnabled: false,
                absolutePathIncluded: false
            ),
            backup: SupportBackupSummary(
                automaticBackupsConfigured: archiveService.hasAutomaticBackupDirectory,
                lastAutomaticBackupSuccessMilliseconds: archiveService.lastAutomaticBackupSuccessDate.map(Self.milliseconds)
            ),
            health: health,
            diagnostics: diagnostics.snapshot(),
            intentionallyExcluded: [
                "attachment bytes and hashes",
                "attachment and original filenames",
                "cached preview text and images",
                "draft and note bodies",
                "file-system paths and folder names",
                "link-preview metadata and URLs"
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)

        do {
            try writeWithoutOverwrite(data, to: destinationURL)
            diagnostics.record(.supportInformationExport, outcome: .succeeded)
            return destinationURL
        } catch {
            diagnostics.record(.supportInformationExport, outcome: .failed)
            throw error
        }
    }

    private func writeWithoutOverwrite(_ data: Data, to destinationURL: URL) throws {
        let accessed = destinationURL.startAccessingSecurityScopedResource()
        defer { if accessed { destinationURL.stopAccessingSecurityScopedResource() } }

        let destination = destinationURL.standardizedFileURL
        let library = provider.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestination = destination.resolvingSymlinksInPath()
        let libraryPrefix = library.path.hasSuffix("/") ? library.path : library.path + "/"
        guard resolvedDestination.path != library.path,
              !resolvedDestination.path.hasPrefix(libraryPrefix) else {
            throw SupportServiceError.destinationOverlapsLibrary
        }

        let parentURL = destination.deletingLastPathComponent()
        let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else {
            throw SupportServiceError.destinationIsNotSafe
        }
        defer { Darwin.close(parentDescriptor) }

        let finalName = destination.lastPathComponent
        guard !finalName.isEmpty, finalName != ".", finalName != ".." else {
            throw SupportServiceError.destinationIsNotSafe
        }
        var existingInformation = stat()
        let existingResult = finalName.withCString {
            fstatat(parentDescriptor, $0, &existingInformation, AT_SYMLINK_NOFOLLOW)
        }
        if existingResult == 0 {
            throw SupportServiceError.destinationAlreadyExists
        }
        guard errno == ENOENT else {
            throw SupportServiceError.destinationIsNotSafe
        }

        let partialName = ".selfdmnotes-support-\(UUID().uuidString.lowercased()).partial"
        let partialDescriptor = partialName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard partialDescriptor >= 0 else {
            throw SupportServiceError.writeFailed(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var didPublish = false
        do {
            let handle = FileHandle(fileDescriptor: partialDescriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw SupportServiceError.writeFailed(.EIO)
            }

            if case let .failBeforePublication(code) = exportFault {
                throw SupportServiceError.simulatedFileSystemFailure(code)
            }

            let result = partialName.withCString { partialPath in
                finalName.withCString { finalPath in
                    renameatx_np(
                        parentDescriptor,
                        partialPath,
                        parentDescriptor,
                        finalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                if code == .EEXIST {
                    throw SupportServiceError.destinationAlreadyExists
                }
                throw SupportServiceError.writeFailed(code)
            }
            didPublish = true
            guard fsync(parentDescriptor) == 0 else {
                throw SupportServiceError.publicationDurabilityUncertain
            }
        } catch {
            if !didPublish {
                partialName.withCString { _ = unlinkat(parentDescriptor, $0, 0) }
            }
            throw error
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
