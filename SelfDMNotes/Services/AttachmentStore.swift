import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class AttachmentStore: @unchecked Sendable {
    static let copyBufferSize = 1_048_576
    static let thumbnailMaximumPixelSize = 512
    static let maximumSourceImagePixelCount: Int64 = 200_000_000

    private let provider: ApplicationSupportDirectoryProvider
    private let database: AppDatabase
    private let fileManager: FileManager
    private let coordinatorLock = NSLock()

    init(
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        fileManager: FileManager = .default
    ) {
        self.provider = provider
        self.database = database
        self.fileManager = fileManager
    }

    func stageSelectedFile(
        at sourceURL: URL,
        id: UUID,
        sortIndex: Int,
        persistDraft: Bool = true,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> StagedAttachment {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return try stageFile(
            at: sourceURL,
            originalFilename: sourceURL.lastPathComponent,
            id: id,
            sortIndex: sortIndex,
            persistDraft: persistDraft,
            progress: progress
        )
    }

    func stageClipboardImage(
        data: Data,
        originalFilename: String,
        mediaType: String,
        id: UUID,
        sortIndex: Int,
        persistDraft: Bool = true,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> StagedAttachment {
        let sourceExtension = UTType(mediaType)?.preferredFilenameExtension ?? "data"
        let temporarySourceURL = provider.stagingURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).clipboard.\(sourceExtension)",
            isDirectory: false
        )
        try? fileManager.removeItem(at: temporarySourceURL)
        try data.write(to: temporarySourceURL, options: .atomic)
        defer { try? fileManager.removeItem(at: temporarySourceURL) }
        return try stageFile(
            at: temporarySourceURL,
            originalFilename: originalFilename,
            id: id,
            sortIndex: sortIndex,
            persistDraft: persistDraft,
            progress: progress
        )
    }

    func discardStagedAttachment(_ attachment: StagedAttachment) throws {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }

        try database.deleteStagedAttachment(id: attachment.id)
        try? fileManager.removeItem(at: stagingURL(for: attachment))
        if let thumbnailURL = thumbnailStagingURL(for: attachment) {
            try? fileManager.removeItem(at: thumbnailURL)
        }
    }

    func discardStagingFiles(id: UUID) {
        for suffix in [".original.stage", ".thumbnail.png", ".clipboard.data"] {
            try? fileManager.removeItem(
                at: provider.stagingURL.appendingPathComponent(
                    id.uuidString.lowercased() + suffix,
                    isDirectory: false
                )
            )
        }
        try? database.deleteStagedAttachment(id: id)
    }

    func removeDiscardedDraftFiles(_ attachments: [StagedAttachment]) -> Bool {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }

        var cleanupFailed = false
        for attachment in attachments {
            if !removeFileIfPresent(at: stagingURL(for: attachment)) {
                cleanupFailed = true
            }
            if let thumbnailURL = thumbnailStagingURL(for: attachment),
               !removeFileIfPresent(at: thumbnailURL) {
                cleanupFailed = true
            }
        }
        return cleanupFailed
    }

    func loadStagedAttachmentManifest() throws -> [RecoveredStagedAttachment] {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }

        return try database.fetchStagedAttachments().map { attachment in
            let originalURL = stagingURL(for: attachment)
            let isAvailable: Bool
            do {
                isAvailable = try regularFileSize(at: originalURL) == attachment.byteSize
            } catch {
                isAvailable = false
            }
            return RecoveredStagedAttachment(
                attachment: attachment,
                isAvailable: isAvailable
            )
        }
    }

    func performStartupMaintenance(
        recoveredAttachments: [RecoveredStagedAttachment]
    ) throws -> AttachmentMaintenanceReport {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }

        let stagedAttachments = recoveredAttachments.map(\.attachment)
        var expectedStagingNames = Set<String>()
        for attachment in stagedAttachments {
            expectedStagingNames.insert(attachment.stagingFilename)
            if let thumbnail = attachment.thumbnailStagingFilename {
                expectedStagingNames.insert(thumbnail)
            }
        }

        var removedAbandoned = 0
        for url in try immediateFiles(at: provider.stagingURL)
        where !expectedStagingNames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
            removedAbandoned += 1
        }

        let missingStaged = recoveredAttachments.compactMap { recovered in
            recovered.isAvailable ? nil : recovered.attachment.originalFilename
        }
        for recovered in recoveredAttachments where recovered.isAvailable {
            let attachment = recovered.attachment
            if attachment.width != nil,
               attachment.height != nil,
               let thumbnailName = attachment.thumbnailStagingFilename {
                let thumbnailURL = provider.stagingURL.appendingPathComponent(thumbnailName)
                if !fileManager.fileExists(atPath: thumbnailURL.path) {
                    try createThumbnail(
                        from: stagingURL(for: attachment),
                        at: thumbnailURL
                    )
                }
            }
        }

        let references = try database.fetchAttachmentBlobReferences()
        let expectedOriginalNames = Set(references.map(\.blob.storedFilename))
        let expectedThumbnailNames = Set(references.compactMap(\.blob.thumbnailFilename))
        var removedOrphans = 0
        for url in try immediateFiles(at: provider.originalsURL)
        where !expectedOriginalNames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
            removedOrphans += 1
        }
        for url in try immediateFiles(at: provider.thumbnailsURL)
        where !expectedThumbnailNames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
            removedOrphans += 1
        }

        var missingOriginalFilenames: [String] = []
        var missingThumbnailCount = 0
        for reference in references {
            if !fileManager.fileExists(atPath: originalURL(for: reference.blob).path) {
                missingOriginalFilenames.append(contentsOf: reference.originalFilenames)
            }
            if let thumbnailFilename = reference.blob.thumbnailFilename,
               !fileManager.fileExists(
                   atPath: provider.thumbnailsURL.appendingPathComponent(thumbnailFilename).path
               ) {
                missingThumbnailCount += 1
            }
        }

        let report = AttachmentMaintenanceReport(
            removedAbandonedStagingItems: removedAbandoned,
            removedOrphanedManagedItems: removedOrphans,
            missingManagedOriginalFilenames: missingOriginalFilenames.sorted(),
            missingThumbnailCount: missingThumbnailCount,
            missingStagedAttachmentFilenames: missingStaged.sorted()
        )
        return report
    }

    func performStartupMaintenance() throws -> AttachmentStartupState {
        let recoveredAttachments = try loadStagedAttachmentManifest()
        return AttachmentStartupState(
            report: try performStartupMaintenance(
                recoveredAttachments: recoveredAttachments
            ),
            recoveredAttachments: recoveredAttachments
        )
    }

    func commitNote(body: String, stagedAttachments: [StagedAttachment]) throws -> AttachmentCommitResult {
        try commitNote(body: body, threadRootID: nil, stagedAttachments: stagedAttachments)
    }

    func commitReply(
        rootID: UUID,
        body: String,
        stagedAttachments: [StagedAttachment]
    ) throws -> AttachmentCommitResult {
        try commitNote(body: body, threadRootID: rootID, stagedAttachments: stagedAttachments)
    }

    private func commitNote(
        body: String,
        threadRootID: UUID?,
        stagedAttachments: [StagedAttachment]
    ) throws -> AttachmentCommitResult {
        guard !stagedAttachments.isEmpty else {
            return AttachmentCommitResult(
                note: try threadRootID.map { rootID in
                    try database.createReply(rootID: rootID, body: body)
                } ?? database.createNote(body: body),
                stagingCleanupFailed: false
            )
        }

        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }

        let grouped = Dictionary(grouping: stagedAttachments, by: \.contentHash)
        var blobsByHash: [String: AttachmentBlob] = [:]
        var rollbackURLs: [URL] = []

        do {
            for (contentHash, group) in grouped {
                guard let representative = group.first else { continue }
                let representativeURL = stagingURL(for: representative)
                guard try regularFileSize(at: representativeURL) == representative.byteSize,
                      try hashFile(at: representativeURL) == representative.contentHash else {
                    throw AttachmentStoreError.stagedFileChanged(representative.originalFilename)
                }
                for duplicate in group.dropFirst() {
                    guard duplicate.byteSize == representative.byteSize,
                          try filesAreEqual(
                              stagingURL(for: duplicate),
                              representativeURL
                          ) else {
                        throw AttachmentStoreError.hashCollision
                    }
                }

                if let existingBlob = try database.fetchAttachmentBlob(contentHash: contentHash) {
                    guard existingBlob.byteSize == representative.byteSize else {
                        throw AttachmentStoreError.hashCollision
                    }
                    let managedOriginalURL = originalURL(for: existingBlob)
                    if fileManager.fileExists(atPath: managedOriginalURL.path) {
                        guard try hashFile(at: managedOriginalURL) == contentHash,
                              try filesAreEqual(managedOriginalURL, representativeURL) else {
                            throw AttachmentStoreError.managedFileCorrupt(
                                representative.originalFilename
                            )
                        }
                    } else {
                        try publishImmutableFile(from: representativeURL, to: managedOriginalURL)
                    }
                    if let thumbnailFilename = existingBlob.thumbnailFilename,
                       let stagedThumbnailURL = thumbnailStagingURL(for: representative) {
                        let managedThumbnailURL = provider.thumbnailsURL.appendingPathComponent(
                            thumbnailFilename
                        )
                        if !fileManager.fileExists(atPath: managedThumbnailURL.path) {
                            try publishImmutableFile(
                                from: stagedThumbnailURL,
                                to: managedThumbnailURL
                            )
                        }
                    }
                    blobsByHash[contentHash] = existingBlob
                    continue
                }

                let blobID = UUID()
                let storedFilename = makeStoredFilename(
                    id: blobID,
                    mediaType: representative.mediaType,
                    originalFilename: representative.originalFilename
                )
                let thumbnailFilename = representative.thumbnailStagingFilename == nil
                    ? nil
                    : "\(blobID.uuidString.lowercased()).png"
                let blob = AttachmentBlob(
                    id: blobID,
                    contentHash: contentHash,
                    storedFilename: storedFilename,
                    thumbnailFilename: thumbnailFilename,
                    mediaType: representative.mediaType,
                    byteSize: representative.byteSize,
                    width: representative.width,
                    height: representative.height,
                    createdAt: representative.createdAt
                )
                let managedOriginalURL = originalURL(for: blob)
                try publishImmutableFile(from: representativeURL, to: managedOriginalURL)
                rollbackURLs.append(managedOriginalURL)
                if let thumbnailFilename,
                   let stagedThumbnailURL = thumbnailStagingURL(for: representative) {
                    let managedThumbnailURL = provider.thumbnailsURL.appendingPathComponent(
                        thumbnailFilename
                    )
                    try publishImmutableFile(from: stagedThumbnailURL, to: managedThumbnailURL)
                    rollbackURLs.append(managedThumbnailURL)
                }
                blobsByHash[contentHash] = blob
            }

            let attachments = try stagedAttachments.map { staged in
                guard let blob = blobsByHash[staged.contentHash] else {
                    throw AttachmentStoreError.invalidStagingMetadata
                }
                return NewAttachment(
                    id: staged.id,
                    originalFilename: staged.originalFilename,
                    createdAt: staged.createdAt,
                    sortIndex: staged.sortIndex,
                    blob: blob
                )
            }
            let note = try threadRootID.map { rootID in
                try database.createReply(rootID: rootID, body: body, attachments: attachments)
            } ?? database.createNote(body: body, attachments: attachments)

            var cleanupFailed = false
            for attachment in stagedAttachments {
                do {
                    try fileManager.removeItem(at: stagingURL(for: attachment))
                } catch {
                    cleanupFailed = true
                }
                if let thumbnailURL = thumbnailStagingURL(for: attachment) {
                    do {
                        try fileManager.removeItem(at: thumbnailURL)
                    } catch {
                        cleanupFailed = true
                    }
                }
            }
            return AttachmentCommitResult(note: note, stagingCleanupFailed: cleanupFailed)
        } catch {
            for url in rollbackURLs.reversed() {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    func permanentlyDeleteNote(id: UUID) throws -> AttachmentDeletionResult {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }

        let deletedFiles = try database.permanentlyDeleteNote(id: id)
        var cleanupFailed = false
        for blob in deletedFiles.blobs {
            do {
                try fileManager.removeItem(at: originalURL(for: blob))
            } catch CocoaError.fileNoSuchFile {
                // A missing managed file was already reported by startup maintenance.
            } catch {
                cleanupFailed = true
            }
            if let thumbnailURL = thumbnailURL(for: blob) {
                do {
                    try fileManager.removeItem(at: thumbnailURL)
                } catch CocoaError.fileNoSuchFile {
                    // Thumbnails are regenerable derivatives.
                } catch {
                    cleanupFailed = true
                }
            }
        }
        for filename in deletedFiles.previewImageFilenames {
            guard let imageURL = LinkPreviewImageStore.safeImageURL(
                filename: filename,
                provider: provider,
                fileManager: fileManager
            ) else {
                continue
            }
            do {
                try fileManager.removeItem(at: imageURL)
            } catch CocoaError.fileNoSuchFile {
                // Cached preview images are optional derivatives.
            } catch {
                cleanupFailed = true
            }
        }
        return AttachmentDeletionResult(managedFileCleanupFailed: cleanupFailed)
    }

    func originalURL(for attachment: Attachment) -> URL {
        provider.originalsURL.appendingPathComponent(
            attachment.storedFilename,
            isDirectory: false
        )
    }

    func thumbnailURL(for attachment: Attachment) -> URL? {
        attachment.thumbnailFilename.map {
            provider.thumbnailsURL.appendingPathComponent($0, isDirectory: false)
        }
    }

    func attachmentIsAvailable(_ attachment: Attachment) -> Bool {
        fileManager.fileExists(atPath: originalURL(for: attachment).path)
    }

    func makeExternalPresentation(for attachment: Attachment) throws -> URL {
        let sourceURL = originalURL(for: attachment)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AttachmentStoreError.managedFileMissing(attachment.originalFilename)
        }
        let presentationDirectory = provider.stagingURL.appendingPathComponent(
            "presentation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: presentationDirectory,
            withIntermediateDirectories: false
        )
        let presentationURL = presentationDirectory.appendingPathComponent(
            attachment.originalFilename,
            isDirectory: false
        )
        do {
            // Presentation paths are intentionally independent copies. A hard link
            // would let another app mutate the managed blob and every deduplicated
            // logical attachment that references it.
            try fileManager.copyItem(at: sourceURL, to: presentationURL)
            return presentationURL
        } catch {
            try? fileManager.removeItem(at: presentationDirectory)
            throw error
        }
    }

    func exportAttachment(_ attachment: Attachment, to destinationURL: URL) throws {
        let sourceURL = originalURL(for: attachment)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AttachmentStoreError.managedFileMissing(attachment.originalFilename)
        }
        let accessedSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        try copyForExport(from: sourceURL, to: destinationURL)
    }

    private func stageFile(
        at sourceURL: URL,
        originalFilename: String,
        id: UUID,
        sortIndex: Int,
        persistDraft: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> StagedAttachment {
        guard !originalFilename.isEmpty, sortIndex >= 0 else {
            throw AttachmentStoreError.invalidStagingMetadata
        }
        try Task.checkCancellation()
        discardStagingFiles(id: id)

        let stagingFilename = "\(id.uuidString.lowercased()).original.stage"
        let stagingURL = provider.stagingURL.appendingPathComponent(stagingFilename)
        let thumbnailFilename = "\(id.uuidString.lowercased()).thumbnail.png"
        let thumbnailURL = provider.stagingURL.appendingPathComponent(thumbnailFilename)
        do {
            let copied = try copyAndHash(
                from: sourceURL,
                to: stagingURL,
                progress: progress
            )
            try Task.checkCancellation()
            let metadata = try inspectAndThumbnail(
                originalFilename: originalFilename,
                stagedURL: stagingURL,
                thumbnailURL: thumbnailURL
            )
            let attachment = StagedAttachment(
                id: id,
                originalFilename: originalFilename,
                stagingFilename: stagingFilename,
                thumbnailStagingFilename: metadata.isImage ? thumbnailFilename : nil,
                mediaType: metadata.mediaType,
                byteSize: copied.byteSize,
                width: metadata.width,
                height: metadata.height,
                contentHash: copied.contentHash,
                createdAt: Self.millisecondPrecision(Date()),
                sortIndex: sortIndex
            )
            try Task.checkCancellation()
            if persistDraft {
                try database.saveStagedAttachment(attachment)
            }
            try Task.checkCancellation()
            progress(1)
            return attachment
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: thumbnailURL)
            try? database.deleteStagedAttachment(id: id)
            throw error
        }
    }

    private func copyAndHash(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> (byteSize: Int64, contentHash: String) {
        let sourceDescriptor = try openRegularFileForReading(at: sourceURL)
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? sourceHandle.close() }
        let expectedSize = try fileSize(descriptor: sourceDescriptor)

        let destinationDescriptor = destinationURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard destinationDescriptor >= 0 else {
            throw posixError(operation: "create staging file", url: destinationURL)
        }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        defer { try? destinationHandle.close() }

        var hasher = SHA256()
        var copiedBytes: Int64 = 0
        progress(expectedSize == 0 ? 1 : 0)
        while true {
            try Task.checkCancellation()
            guard let chunk = try sourceHandle.read(upToCount: Self.copyBufferSize),
                  !chunk.isEmpty else {
                break
            }
            guard copiedBytes <= Int64.max - Int64(chunk.count) else {
                throw AttachmentStoreError.fileTooLarge
            }
            copiedBytes += Int64(chunk.count)
            guard copiedBytes <= expectedSize else {
                throw AttachmentStoreError.sourceChangedDuringImport(sourceURL.lastPathComponent)
            }
            hasher.update(data: chunk)
            try destinationHandle.write(contentsOf: chunk)
            if expectedSize > 0 {
                progress(min(1, Double(copiedBytes) / Double(expectedSize)))
            }
        }
        guard copiedBytes == expectedSize,
              try fileSize(descriptor: sourceDescriptor) == expectedSize else {
            throw AttachmentStoreError.sourceChangedDuringImport(sourceURL.lastPathComponent)
        }
        try destinationHandle.synchronize()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (copiedBytes, digest)
    }

    private func inspectAndThumbnail(
        originalFilename: String,
        stagedURL: URL,
        thumbnailURL: URL
    ) throws -> (mediaType: String, width: Int?, height: Int?, isImage: Bool) {
        let extensionType = UTType(filenameExtension: (originalFilename as NSString).pathExtension)
        let fallbackType = extensionType?.identifier ?? UTType.data.identifier
        guard let source = CGImageSourceCreateWithURL(stagedURL as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return (fallbackType, nil, nil, false)
        }

        let width = widthNumber.intValue
        let height = heightNumber.intValue
        guard width > 0, height > 0,
              Int64(width) <= Self.maximumSourceImagePixelCount / Int64(height) else {
            throw AttachmentStoreError.imageDimensionsTooLarge(originalFilename)
        }
        try createThumbnail(from: source, at: thumbnailURL)
        return (sourceType as String, width, height, true)
    }

    private func createThumbnail(from originalURL: URL, at thumbnailURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil) else {
            throw AttachmentStoreError.thumbnailCreationFailed
        }
        try createThumbnail(from: source, at: thumbnailURL)
    }

    private func createThumbnail(from source: CGImageSource, at thumbnailURL: URL) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(
                  thumbnailURL as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw AttachmentStoreError.thumbnailCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentStoreError.thumbnailCreationFailed
        }
    }

    private func hashFile(at url: URL) throws -> String {
        let descriptor = try openRegularFileForReading(at: url)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.copyBufferSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func filesAreEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsDescriptor = try openRegularFileForReading(at: lhs)
        let rhsDescriptor = try openRegularFileForReading(at: rhs)
        let lhsHandle = FileHandle(fileDescriptor: lhsDescriptor, closeOnDealloc: true)
        let rhsHandle = FileHandle(fileDescriptor: rhsDescriptor, closeOnDealloc: true)
        defer {
            try? lhsHandle.close()
            try? rhsHandle.close()
        }
        guard try fileSize(descriptor: lhsDescriptor) == fileSize(descriptor: rhsDescriptor) else {
            return false
        }
        while true {
            try Task.checkCancellation()
            let lhsChunk = try lhsHandle.read(upToCount: Self.copyBufferSize) ?? Data()
            let rhsChunk = try rhsHandle.read(upToCount: Self.copyBufferSize) ?? Data()
            guard lhsChunk == rhsChunk else { return false }
            if lhsChunk.isEmpty { return true }
        }
    }

    private func copyForExport(from sourceURL: URL, to destinationURL: URL) throws {
        try Task.checkCancellation()
        let sourceDescriptor = try openRegularFileForReading(at: sourceURL)
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? sourceHandle.close() }

        let destinationDescriptor = destinationURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            throw posixError(operation: "open export destination", url: destinationURL)
        }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        defer { try? destinationHandle.close() }

        var sourceInformation = stat()
        var destinationInformation = stat()
        if fstat(sourceDescriptor, &sourceInformation) != 0
            || fstat(destinationDescriptor, &destinationInformation) != 0 {
            let error = posixError(
                operation: "inspect export destination",
                url: destinationURL
            )
            throw AttachmentStoreError.exportDestinationMayBePartial(
                destinationFilename: destinationURL.lastPathComponent,
                details: error.localizedDescription
            )
        }
        guard sourceInformation.st_dev != destinationInformation.st_dev
                || sourceInformation.st_ino != destinationInformation.st_ino else {
            throw AttachmentStoreError.exportWouldOverwriteManagedOriginal(
                attachmentName: destinationURL.lastPathComponent
            )
        }

        do {
            guard ftruncate(destinationDescriptor, 0) == 0 else {
                throw posixError(operation: "truncate export destination", url: destinationURL)
            }
            while let chunk = try sourceHandle.read(upToCount: Self.copyBufferSize),
                  !chunk.isEmpty {
                try Task.checkCancellation()
                try destinationHandle.write(contentsOf: chunk)
            }
            try destinationHandle.synchronize()
        } catch {
            throw AttachmentStoreError.exportDestinationMayBePartial(
                destinationFilename: destinationURL.lastPathComponent,
                details: error.localizedDescription
            )
        }
    }

    private func publishImmutableFile(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw AttachmentStoreError.unexpectedManagedDestination(
                    destinationURL.lastPathComponent
                )
            }
            throw posixError(operation: "publish managed attachment", url: destinationURL)
        }
        try synchronizeDirectory(destinationURL.deletingLastPathComponent())
    }

    private func openRegularFileForReading(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open attachment", url: url)
        }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw posixError(operation: "inspect attachment", url: url)
            }
            guard (information.st_mode & S_IFMT) == S_IFREG else {
                throw AttachmentStoreError.sourceIsNotRegularFile(url.lastPathComponent)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func regularFileSize(at url: URL) throws -> Int64 {
        let descriptor = try openRegularFileForReading(at: url)
        defer { Darwin.close(descriptor) }
        return try fileSize(descriptor: descriptor)
    }

    private func fileSize(descriptor: Int32) throws -> Int64 {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return information.st_size
    }

    private func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open managed directory", url: directoryURL)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError(operation: "synchronize managed directory", url: directoryURL)
        }
    }

    private func immediateFiles(at directoryURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    }

    private func removeFileIfPresent(at url: URL) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private func stagingURL(for attachment: StagedAttachment) -> URL {
        provider.stagingURL.appendingPathComponent(
            attachment.stagingFilename,
            isDirectory: false
        )
    }

    private func thumbnailStagingURL(for attachment: StagedAttachment) -> URL? {
        attachment.thumbnailStagingFilename.map {
            provider.stagingURL.appendingPathComponent($0, isDirectory: false)
        }
    }

    private func originalURL(for blob: AttachmentBlob) -> URL {
        provider.originalsURL.appendingPathComponent(blob.storedFilename, isDirectory: false)
    }

    private func thumbnailURL(for blob: AttachmentBlob) -> URL? {
        blob.thumbnailFilename.map {
            provider.thumbnailsURL.appendingPathComponent($0, isDirectory: false)
        }
    }

    private func makeStoredFilename(
        id: UUID,
        mediaType: String,
        originalFilename: String
    ) -> String {
        let fileExtension = UTType(mediaType)?.preferredFilenameExtension
            ?? (originalFilename as NSString).pathExtension
        let safeExtension = fileExtension.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        } ? fileExtension.lowercased() : "data"
        return "\(id.uuidString.lowercased()).\(safeExtension.isEmpty ? "data" : safeExtension)"
    }

    private func posixError(operation: String, url: URL) -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return AttachmentStoreError.fileOperationFailed(
            "\(operation) “\(url.lastPathComponent)”: \(POSIXError(code).localizedDescription)"
        )
    }

    private static func millisecondPrecision(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970: (
                date.timeIntervalSince1970 * 1_000
            ).rounded() / 1_000
        )
    }
}

enum AttachmentStoreError: LocalizedError, Equatable {
    case exportDestinationMayBePartial(destinationFilename: String, details: String)
    case exportWouldOverwriteManagedOriginal(attachmentName: String)
    case fileOperationFailed(String)
    case fileTooLarge
    case hashCollision
    case imageDimensionsTooLarge(String)
    case invalidStagingMetadata
    case managedFileCorrupt(String)
    case managedFileMissing(String)
    case sourceChangedDuringImport(String)
    case sourceIsNotRegularFile(String)
    case stagedFileChanged(String)
    case thumbnailCreationFailed
    case unexpectedManagedDestination(String)

    var errorDescription: String? {
        switch self {
        case let .exportDestinationMayBePartial(destinationFilename, details):
            "Export to “\(destinationFilename)” did not finish. The selected destination may contain partial data; choose Export again to replace it. The archived original is unchanged. Details: \(details)"
        case let .exportWouldOverwriteManagedOriginal(attachmentName):
            "Export destination “\(attachmentName)” aliases the managed original and was not changed. Choose another destination."
        case let .fileOperationFailed(message):
            message
        case .fileTooLarge:
            "The file is too large to represent safely."
        case .hashCollision:
            "Two different files produced the same content hash. No note was saved."
        case let .imageDimensionsTooLarge(filename):
            "“\(filename)” has image dimensions too large to thumbnail safely."
        case .invalidStagingMetadata:
            "The pending attachment metadata is incomplete or invalid."
        case let .managedFileCorrupt(filename):
            "The managed bytes for “\(filename)” do not match their stored content hash. No files were replaced."
        case let .managedFileMissing(filename):
            "The managed original for “\(filename)” is missing."
        case let .sourceChangedDuringImport(filename):
            "“\(filename)” changed while it was being copied. Retry after the source stops changing."
        case let .sourceIsNotRegularFile(filename):
            "“\(filename)” is not an ordinary file and was not attached."
        case let .stagedFileChanged(filename):
            "The staged copy of “\(filename)” changed before send. Remove it and attach the source again."
        case .thumbnailCreationFailed:
            "The image thumbnail could not be generated safely."
        case let .unexpectedManagedDestination(filename):
            "An unexpected managed file named “\(filename)” already exists. No file was overwritten."
        }
    }
}
