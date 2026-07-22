import Darwin
import Foundation

final class RestoreRecoveryCoordinator: @unchecked Sendable {
    private static let identityFilename = ".selfdm-restore-identity.json"
    private static let journalFilename = "restore-journal.json"

    let provider: ApplicationSupportDirectoryProvider
    let controlDirectoryURL: URL
    let stagedLibraryURL: URL
    let rollbackLibraryURL: URL

    private let fileManager: FileManager
    private(set) var startupMode: RestoreStartupMode = .none

    private var journalURL: URL {
        controlDirectoryURL.appendingPathComponent(Self.journalFilename, isDirectory: false)
    }

    init(
        provider: ApplicationSupportDirectoryProvider,
        fileManager: FileManager = .default
    ) {
        self.provider = provider
        self.fileManager = fileManager
        let digest = SHA256Digest.hex(Data(provider.rootURL.path.utf8)).prefix(16)
        controlDirectoryURL = provider.rootURL.deletingLastPathComponent()
            .appendingPathComponent(".selfdmnotes-restore-\(digest)", isDirectory: true)
        stagedLibraryURL = controlDirectoryURL.appendingPathComponent(
            "staged-library",
            isDirectory: true
        )
        rollbackLibraryURL = controlDirectoryURL.appendingPathComponent(
            "rollback-library",
            isDirectory: true
        )
    }

    var hasPendingRestore: Bool {
        fileManager.fileExists(atPath: journalURL.path)
    }

    var isTrialLaunch: Bool {
        startupMode == .trial
    }

    func prepareForStaging() throws {
        guard !hasPendingRestore else {
            throw ArchiveServiceError.restoreAlreadyPending
        }
        if fileManager.fileExists(atPath: controlDirectoryURL.path) {
            try ensureRegularDirectory(controlDirectoryURL)
            guard try fileManager.contentsOfDirectory(atPath: controlDirectoryURL.path).isEmpty else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
        } else {
            try fileManager.createDirectory(
                at: controlDirectoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try ensureRegularDirectory(controlDirectoryURL)
            try synchronizeDirectory(controlDirectoryURL.deletingLastPathComponent())
        }
    }

    func resolveBeforeOpeningLibrary() throws -> RestoreStartupMode {
        guard fileManager.fileExists(atPath: journalURL.path) else {
            startupMode = try validateUnarmedRestoreStateIfPresent() == nil
                ? .none
                : .unarmedCleanupPending
            return startupMode
        }

        var journal = try readJournal()
        switch journal.state {
        case .armed:
            try beginOrFinishTrial(journal: &journal)
            startupMode = .trial
        case .cancellationRequested:
            try validateCancellationCleanupState(journal: journal)
            startupMode = .cancellationCleanupPending
        case .trialStarted:
            let reason = "The previous restored-library trial did not reach startup confirmation. The original library was recovered automatically."
            try requestAndPerformRollback(journal: &journal, reason: reason)
            startupMode = .recoveredOriginal(reason)
        case .rollbackRequested:
            let reason = journal.failureReason
                ?? "The restored library did not pass startup checks. The original library was recovered automatically."
            try performRollbackIfNeeded(journal: journal)
            startupMode = .recoveredOriginal(reason)
        case .committed:
            try validateCommittedCleanupState(journal: journal)
            startupMode = .committedCleanupPending
        }
        return startupMode
    }

    func armRestore(backupID: UUID, stagedRoot: URL) throws {
        guard stagedRoot.standardizedFileURL == stagedLibraryURL.standardizedFileURL,
              !hasPendingRestore else {
            throw ArchiveServiceError.restoreAlreadyPending
        }
        try ensureRegularDirectory(provider.rootURL)
        try ensureRegularDirectory(stagedLibraryURL)
        try ensureSameVolume(provider.rootURL, stagedLibraryURL)

        let transactionID = UUID()
        let oldLibraryID = UUID()
        let newLibraryID = UUID()
        let oldIdentity = RestoreLibraryIdentity(
            transactionID: transactionID,
            libraryID: oldLibraryID,
            role: .old
        )
        let newIdentity = RestoreLibraryIdentity(
            transactionID: transactionID,
            libraryID: newLibraryID,
            role: .new
        )
        let journal = RestoreJournal(
            formatVersion: 1,
            transactionID: transactionID,
            backupID: backupID,
            oldLibraryID: oldLibraryID,
            newLibraryID: newLibraryID,
            state: .armed,
            failureReason: nil
        )
        var wroteOldIdentity = false
        var wroteNewIdentity = false

        do {
            try writeIdentity(oldIdentity, to: provider.rootURL)
            wroteOldIdentity = true
            try writeIdentity(newIdentity, to: stagedLibraryURL)
            wroteNewIdentity = true
            try synchronizeDirectory(provider.rootURL)
            try synchronizeDirectory(stagedLibraryURL)
            try writeJournal(journal)
        } catch {
            let originalError = error
            if fileManager.fileExists(atPath: journalURL.path) {
                if let persisted = try? readJournal() {
                    guard sameTransaction(persisted, journal: journal) else {
                        throw ArchiveServiceError.restoreResolutionRequired
                    }
                    throw ArchiveServiceError.restoreResolutionRequired
                }
                do {
                    try fileManager.removeItem(at: journalURL)
                    try synchronizeDirectory(controlDirectoryURL)
                } catch {
                    throw ArchiveServiceError.restoreResolutionRequired
                }
            }
            do {
                if wroteOldIdentity {
                    try removeIdentity(from: provider.rootURL)
                }
                if wroteNewIdentity {
                    try removeIdentity(from: stagedLibraryURL)
                }
            } catch {
                throw ArchiveServiceError.restoreResolutionRequired
            }
            throw originalError
        }
    }

    func cancelArmedRestore() throws {
        var journal = try readJournal()
        guard journal.state == .armed,
              try identity(at: provider.rootURL) == expectedIdentity(
                journal: journal,
                role: .old
              ),
              try identity(at: stagedLibraryURL) == expectedIdentity(
                journal: journal,
                role: .new
              ) else {
            throw ArchiveServiceError.restoreCancellationUnsafe
        }
        journal.state = .cancellationRequested
        try writeJournal(journal)
        try finishCancellation(journal: journal)
    }

    func requestRollback(_ reason: String) throws {
        var journal = try readJournal()
        guard journal.state == .trialStarted else { return }
        journal.state = .rollbackRequested
        journal.failureReason = String(reason.prefix(2_000))
        try writeJournal(journal)
    }

    func confirmSuccessfulStartup() throws {
        if startupMode == .unarmedCleanupPending {
            startupMode = .none
            do {
                try cleanUnarmedRestoreIfPresent()
            } catch {
                throw ArchiveServiceError.restoreUnarmedCleanupPending(
                    error.localizedDescription
                )
            }
            return
        }
        guard hasPendingRestore else {
            startupMode = .none
            return
        }
        var journal = try readJournal()
        switch startupMode {
        case .trial:
            guard journal.state == .trialStarted,
                  try identity(at: provider.rootURL) == expectedIdentity(
                    journal: journal,
                    role: .new
                  ),
                  try identity(at: rollbackLibraryURL) == expectedIdentity(
                    journal: journal,
                    role: .old
                  ) else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
        case .recoveredOriginal:
            guard journal.state == .rollbackRequested,
                  try identity(at: provider.rootURL) == expectedIdentity(
                    journal: journal,
                    role: .old
                  ) else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
        case .committedCleanupPending:
            guard journal.state == .committed else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
            try validateCommittedCleanupState(journal: journal)
            startupMode = .none
            do {
                try finishCommittedCleanup(journal: journal)
            } catch {
                throw ArchiveServiceError.restoreCommittedCleanupPending(
                    error.localizedDescription
                )
            }
            return
        case .cancellationCleanupPending:
            guard journal.state == .cancellationRequested else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
            try validateCancellationCleanupState(journal: journal)
            startupMode = .none
            do {
                try finishCancellation(journal: journal)
            } catch {
                throw ArchiveServiceError.restoreCancellationCleanupPending(
                    error.localizedDescription
                )
            }
            return
        case .unarmedCleanupPending:
            preconditionFailure("Unarmed cleanup is handled before journal loading.")
        case .none:
            return
        }

        let previousState = journal.state
        journal.state = .committed
        do {
            try writeJournal(journal)
        } catch {
            if let persisted = try? readJournal(), sameTransaction(persisted, journal: journal) {
                if persisted.state == .committed {
                    startupMode = .none
                    throw ArchiveServiceError.restoreCommittedCleanupPending(
                        error.localizedDescription
                    )
                }
                if persisted.state == previousState {
                    throw error
                }
            }
            startupMode = .none
            throw ArchiveServiceError.restoreResolutionRequired
        }
        startupMode = .none
        do {
            try finishCommittedCleanup(journal: journal)
        } catch {
            throw ArchiveServiceError.restoreCommittedCleanupPending(error.localizedDescription)
        }
    }

    private func beginOrFinishTrial(journal: inout RestoreJournal) throws {
        let activeIdentity = try identity(at: provider.rootURL)
        let stagedIdentity = try identity(at: stagedLibraryURL)
        let rollbackIdentity = try identity(at: rollbackLibraryURL)
        let oldIdentity = expectedIdentity(journal: journal, role: .old)
        let newIdentity = expectedIdentity(journal: journal, role: .new)

        if activeIdentity == oldIdentity, stagedIdentity == newIdentity, rollbackIdentity == nil {
            try swapDirectories(provider.rootURL, stagedLibraryURL)
        } else if activeIdentity == newIdentity,
                  (stagedIdentity == oldIdentity || rollbackIdentity == oldIdentity) {
            // A prior process completed the atomic swap and stopped before
            // durably advancing every recovery bookkeeping step.
        } else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }

        journal.state = .trialStarted
        try writeJournal(journal)
        if try identity(at: stagedLibraryURL) == oldIdentity {
            guard !fileManager.fileExists(atPath: rollbackLibraryURL.path) else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
            try fileManager.moveItem(at: stagedLibraryURL, to: rollbackLibraryURL)
            try synchronizeDirectory(controlDirectoryURL)
        }
        guard try identity(at: provider.rootURL) == newIdentity,
              try identity(at: rollbackLibraryURL) == oldIdentity else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
    }

    private func requestAndPerformRollback(
        journal: inout RestoreJournal,
        reason: String
    ) throws {
        journal.state = .rollbackRequested
        journal.failureReason = reason
        try writeJournal(journal)
        try performRollbackIfNeeded(journal: journal)
    }

    private func performRollbackIfNeeded(journal: RestoreJournal) throws {
        let activeIdentity = try identity(at: provider.rootURL)
        let oldIdentity = expectedIdentity(journal: journal, role: .old)
        let newIdentity = expectedIdentity(journal: journal, role: .new)
        let counterpartURL: URL
        if try identity(at: rollbackLibraryURL) != nil {
            counterpartURL = rollbackLibraryURL
        } else {
            counterpartURL = stagedLibraryURL
        }
        let counterpartIdentity = try identity(at: counterpartURL)

        if activeIdentity == newIdentity, counterpartIdentity == oldIdentity {
            try swapDirectories(provider.rootURL, counterpartURL)
        } else if activeIdentity == oldIdentity, counterpartIdentity == newIdentity {
            // The reverse swap was already completed before interruption.
        } else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
    }

    private func finishCommittedCleanup(journal: RestoreJournal) throws {
        try validateCommittedCleanupState(journal: journal)
        for url in [stagedLibraryURL, rollbackLibraryURL]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try synchronizeDirectory(controlDirectoryURL)
        try removeIdentity(from: provider.rootURL)
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
        try removeControlDirectoryIfEmpty()
        try synchronizeDirectory(provider.rootURL.deletingLastPathComponent())
    }

    private func validateCommittedCleanupState(journal: RestoreJournal) throws {
        let activeIdentity = try identity(at: provider.rootURL)
        let isExpectedActive = activeIdentity == expectedIdentity(journal: journal, role: .new)
            || activeIdentity == expectedIdentity(journal: journal, role: .old)
        let isResumingCompletedCleanup = activeIdentity == nil
            && !fileManager.fileExists(atPath: stagedLibraryURL.path)
            && !fileManager.fileExists(atPath: rollbackLibraryURL.path)
        guard isExpectedActive || isResumingCompletedCleanup else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
    }

    private func finishCancellation(journal: RestoreJournal) throws {
        try validateCancellationCleanupState(journal: journal)
        let oldIdentity = expectedIdentity(journal: journal, role: .old)
        let activeIdentity = try identity(at: provider.rootURL)
        if activeIdentity == oldIdentity {
            try removeIdentity(from: provider.rootURL)
        }
        if fileManager.fileExists(atPath: stagedLibraryURL.path) {
            try fileManager.removeItem(at: stagedLibraryURL)
        }
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
        try removeControlDirectoryIfEmpty()
        try synchronizeDirectory(provider.rootURL.deletingLastPathComponent())
    }

    private func validateCancellationCleanupState(journal: RestoreJournal) throws {
        let oldIdentity = expectedIdentity(journal: journal, role: .old)
        let newIdentity = expectedIdentity(journal: journal, role: .new)
        let activeIdentity = try identity(at: provider.rootURL)
        let stagedIdentity = try identity(at: stagedLibraryURL)
        guard activeIdentity == oldIdentity || activeIdentity == nil,
              stagedIdentity == newIdentity || stagedIdentity == nil,
              !fileManager.fileExists(atPath: rollbackLibraryURL.path) else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
    }

    private func cleanUnarmedRestoreIfPresent() throws {
        guard let entries = try validateUnarmedRestoreStateIfPresent() else { return }
        let activeIdentity = try identity(at: provider.rootURL)
        if activeIdentity?.role == .old {
            try removeIdentity(from: provider.rootURL)
        }
        for entry in entries {
            try fileManager.removeItem(at: entry)
        }
        try removeControlDirectoryIfEmpty()
        try synchronizeDirectory(provider.rootURL.deletingLastPathComponent())
    }

    private func validateUnarmedRestoreStateIfPresent() throws -> [URL]? {
        guard fileManager.fileExists(atPath: controlDirectoryURL.path) else {
            if fileManager.fileExists(
                atPath: provider.rootURL.appendingPathComponent(
                    Self.identityFilename
                ).path
            ) {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
            return nil
        }
        try ensureRegularDirectory(controlDirectoryURL)
        let activeIdentity = try identity(at: provider.rootURL)
        let stagedIdentity = try identity(at: stagedLibraryURL)
        guard activeIdentity?.role != .new,
              stagedIdentity?.role != .old,
              !fileManager.fileExists(atPath: rollbackLibraryURL.path) else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }

        let entries = try fileManager.contentsOfDirectory(
            at: controlDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries {
            let isStagedLibrary = entry.lastPathComponent == stagedLibraryURL.lastPathComponent
            let isQuarantine = entry.lastPathComponent.hasPrefix("quarantine-")
            guard isStagedLibrary || isQuarantine else {
                throw ArchiveServiceError.restoreStateAmbiguous
            }
            try ensureRegularDirectory(entry)
        }
        return entries
    }

    private func expectedIdentity(
        journal: RestoreJournal,
        role: RestoreLibraryIdentity.Role
    ) -> RestoreLibraryIdentity {
        RestoreLibraryIdentity(
            transactionID: journal.transactionID,
            libraryID: role == .old ? journal.oldLibraryID : journal.newLibraryID,
            role: role
        )
    }

    private func sameTransaction(_ lhs: RestoreJournal, journal rhs: RestoreJournal) -> Bool {
        lhs.formatVersion == rhs.formatVersion
            && lhs.transactionID == rhs.transactionID
            && lhs.backupID == rhs.backupID
            && lhs.oldLibraryID == rhs.oldLibraryID
            && lhs.newLibraryID == rhs.newLibraryID
    }

    private func identity(at root: URL) throws -> RestoreLibraryIdentity? {
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        let url = root.appendingPathComponent(Self.identityFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try readRegularData(at: url, maximumByteCount: 16_384)
        return try strictDecoder.decode(RestoreLibraryIdentity.self, from: data)
    }

    private func writeIdentity(_ identity: RestoreLibraryIdentity, to root: URL) throws {
        let url = root.appendingPathComponent(Self.identityFilename, isDirectory: false)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
        try writeDurable(try strictEncoder.encode(identity), to: url)
    }

    private func removeIdentity(from root: URL) throws {
        let url = root.appendingPathComponent(Self.identityFilename, isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            try synchronizeDirectory(root)
        }
    }

    private func readJournal() throws -> RestoreJournal {
        let data = try readRegularData(at: journalURL, maximumByteCount: 65_536)
        let journal = try strictDecoder.decode(RestoreJournal.self, from: data)
        guard journal.formatVersion == 1 else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
        return journal
    }

    private func writeJournal(_ journal: RestoreJournal) throws {
        if fileManager.fileExists(atPath: controlDirectoryURL.path) {
            try ensureRegularDirectory(controlDirectoryURL)
        } else {
            try fileManager.createDirectory(
                at: controlDirectoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try writeDurable(try strictEncoder.encode(journal), to: journalURL)
        try synchronizeDirectory(controlDirectoryURL)
    }

    private func writeDurable(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let descriptor = try openRegularFile(at: url)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ArchiveServiceError.fileSystemFailure("Could not synchronize recovery metadata.")
        }
    }

    private func readRegularData(at url: URL, maximumByteCount: Int) throws -> Data {
        let descriptor = try openRegularFile(at: url)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_size <= maximumByteCount else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
        return data
    }

    private func openRegularFile(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ArchiveServiceError.fileSystemFailure(
                "Could not open recovery item “\(url.lastPathComponent)”."
            )
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ArchiveServiceError.restoreStateAmbiguous
        }
        return descriptor
    }

    private func swapDirectories(_ first: URL, _ second: URL) throws {
        try ensureRegularDirectory(first)
        try ensureRegularDirectory(second)
        try ensureSameVolume(first, second)
        let firstParent = first.deletingLastPathComponent()
        let secondParent = second.deletingLastPathComponent()
        let firstParentDescriptor = try openDirectory(firstParent)
        let secondParentDescriptor = try openDirectory(secondParent)
        defer {
            Darwin.close(firstParentDescriptor)
            Darwin.close(secondParentDescriptor)
        }
        let result = first.lastPathComponent.withCString { firstName in
            second.lastPathComponent.withCString { secondName in
                renameatx_np(
                    firstParentDescriptor,
                    firstName,
                    secondParentDescriptor,
                    secondName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw ArchiveServiceError.fileSystemFailure(
                "The filesystem could not atomically switch libraries: \(POSIXError(code).localizedDescription)"
            )
        }
        guard fsync(firstParentDescriptor) == 0,
              firstParent.path == secondParent.path || fsync(secondParentDescriptor) == 0 else {
            throw ArchiveServiceError.fileSystemFailure(
                "The atomic library switch completed, but its directory could not be synchronized. Reopen the app to resolve recovery state."
            )
        }
    }

    private func ensureSameVolume(_ lhs: URL, _ rhs: URL) throws {
        var lhsInformation = stat()
        var rhsInformation = stat()
        let lhsResult = lhs.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &lhsInformation) } ?? -1
        }
        let rhsResult = rhs.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &rhsInformation) } ?? -1
        }
        guard lhsResult == 0,
              rhsResult == 0,
              lhsInformation.st_dev == rhsInformation.st_dev else {
            throw ArchiveServiceError.fileSystemFailure(
                "The staged and active libraries are not on the same filesystem."
            )
        }
    }

    private func ensureRegularDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ArchiveServiceError.restoreStateAmbiguous
        }
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ArchiveServiceError.fileSystemFailure(
                "Could not open recovery directory “\(url.lastPathComponent)”."
            )
        }
        return descriptor
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = try openDirectory(url)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ArchiveServiceError.fileSystemFailure(
                "Could not synchronize directory “\(url.lastPathComponent)”."
            )
        }
    }

    private func removeControlDirectoryIfEmpty() throws {
        guard fileManager.fileExists(atPath: controlDirectoryURL.path) else { return }
        let entries = try fileManager.contentsOfDirectory(atPath: controlDirectoryURL.path)
        if entries.isEmpty {
            try fileManager.removeItem(at: controlDirectoryURL)
        }
    }

    private var strictEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var strictDecoder: JSONDecoder { JSONDecoder() }
}

private struct RestoreLibraryIdentity: Codable, Equatable {
    enum Role: String, Codable {
        case old
        case new
    }

    let transactionID: UUID
    let libraryID: UUID
    let role: Role
}

private struct RestoreJournal: Codable {
    enum State: String, Codable {
        case armed
        case cancellationRequested
        case trialStarted
        case rollbackRequested
        case committed
    }

    let formatVersion: Int
    let transactionID: UUID
    let backupID: UUID
    let oldLibraryID: UUID
    let newLibraryID: UUID
    var state: State
    var failureReason: String?
}
