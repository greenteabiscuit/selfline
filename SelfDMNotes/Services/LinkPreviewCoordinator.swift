import Darwin
import Foundation

actor LinkPreviewCoordinator {
    static let maximumConcurrentFetches = 4

    typealias ChangeHandler = @MainActor @Sendable (Set<UUID>) -> Void
    typealias WarningHandler = @MainActor @Sendable (String) -> Void
    typealias StartupCheckpoint = @Sendable (LinkPreviewReconciliationSnapshot) async throws -> Void
    typealias PreFetchCheckpoint = @Sendable (LinkPreviewWorkItem) async throws -> Void

    private let database: AppDatabase
    private let detector: LinkDetector
    private let fetcher: any LinkPreviewMetadataFetching
    private let startupCheckpoint: StartupCheckpoint?
    private let preFetchCheckpoint: PreFetchCheckpoint?
    nonisolated private let imageStore: LinkPreviewImageStore
    private var automaticFetchingEnabled = false
    private var started = false
    private var resumed = false
    private var mutationsPaused = false
    private(set) var startupReconciliationComplete = false
    private var startupReconciliationFailed = false
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var startupReconciliationTask: Task<Void, Never>?
    private var changeHandler: ChangeHandler?
    private var warningHandler: WarningHandler?

    init(
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        detector: LinkDetector = LinkDetector(),
        fetcher: any LinkPreviewMetadataFetching = LinkPreviewMetadataFetcher(),
        startupCheckpoint: StartupCheckpoint? = nil,
        preFetchCheckpoint: PreFetchCheckpoint? = nil
    ) {
        self.database = database
        self.detector = detector
        self.fetcher = fetcher
        self.startupCheckpoint = startupCheckpoint
        self.preFetchCheckpoint = preFetchCheckpoint
        imageStore = LinkPreviewImageStore(
            provider: provider,
            database: database,
            fileManager: FileManager()
        )
    }

    func setChangeHandler(_ handler: ChangeHandler?) {
        changeHandler = handler
    }

    func setWarningHandler(_ handler: WarningHandler?) {
        warningHandler = handler
    }

    func start() -> LinkPreviewStartupResult {
        if started {
            return LinkPreviewStartupResult(
                automaticFetchingEnabled: automaticFetchingEnabled,
                warning: nil
            )
        }
        var warnings: [String] = []
        do {
            let changedNoteIDs = try imageStore.performStartupMaintenance()
            notify(changedNoteIDs)
        } catch {
            warnings.append("Preview image cleanup could not finish: \(error.localizedDescription)")
        }
        do {
            automaticFetchingEnabled = try database.automaticLinkPreviewsEnabled()
        } catch {
            automaticFetchingEnabled = false
            warnings.append(
                "The automatic-preview preference could not be read, so network fetching remains off: \(error.localizedDescription)"
            )
        }
        started = true
        return LinkPreviewStartupResult(
            automaticFetchingEnabled: automaticFetchingEnabled,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    func resumeBackgroundWork() {
        guard started, !resumed else { return }
        mutationsPaused = false
        resumed = true
        if startupReconciliationComplete {
            drainWorkQueue()
            return
        }
        guard !startupReconciliationFailed else { return }
        startupReconciliationTask = Task { [weak self] in
            await self?.runStartupReconciliation()
        }
    }

    func pauseBackgroundWork() async {
        guard started else { return }
        mutationsPaused = true
        resumed = false
        let startupTask = startupReconciliationTask
        let fetchTasks = Array(inFlight.values)
        startupTask?.cancel()
        for task in fetchTasks { task.cancel() }
        await startupTask?.value
        for task in fetchTasks { await task.value }
        startupReconciliationTask = nil
    }

    func setAutomaticFetchingEnabled(_ enabled: Bool) throws {
        guard !mutationsPaused else {
            throw LinkPreviewCoordinatorError.mutationsPausedForRestore
        }
        if !enabled {
            automaticFetchingEnabled = false
            for task in inFlight.values { task.cancel() }
            try database.setAutomaticLinkPreviewsEnabled(false)
            return
        }
        guard !automaticFetchingEnabled else { return }
        try database.setAutomaticLinkPreviewsEnabled(true)
        automaticFetchingEnabled = true
        drainWorkQueue()
    }

    func editNote(id: UUID, body: String, updatedAt: Date = Date()) throws -> Note {
        guard !mutationsPaused else {
            throw LinkPreviewCoordinatorError.mutationsPausedForRestore
        }
        _ = try database.editNote(id: id, body: body, updatedAt: updatedAt)
        do {
            try reconcileCurrentNote(id: id)
        } catch {
            // The body is already durable and its revision makes old rows
            // ineligible. Keep the visible edit truthful even if optional
            // preview reconciliation could not finish.
            cancelIneligibleWork()
            notifyWarning(
                "The note was saved, but its link previews could not be refreshed. No removed link will be fetched. Details: \(error.localizedDescription)"
            )
        }
        return try database.fetchNote(id: id)
    }

    func reconcileNote(id: UUID) {
        guard !mutationsPaused else { return }
        try? reconcileCurrentNote(id: id)
    }

    func noteBecameIneligible() {
        cancelIneligibleWork()
        drainWorkQueue()
    }

    func retry(previewID: UUID) throws {
        guard !mutationsPaused else {
            throw LinkPreviewCoordinatorError.mutationsPausedForRestore
        }
        guard automaticFetchingEnabled else {
            throw LinkPreviewCoordinatorError.automaticFetchingDisabled
        }
        let noteID = try database.retryLinkPreview(id: previewID)
        notify([noteID])
        drainWorkQueue()
    }

    func remove(previewID: UUID) throws {
        guard !mutationsPaused else {
            throw LinkPreviewCoordinatorError.mutationsPausedForRestore
        }
        let result = try database.removeLinkPreview(id: previewID)
        if let filename = result.unusedImageFilename {
            imageStore.removeImages(named: [filename])
        }
        notify([result.changedNoteID])
        cancelIneligibleWork()
        drainWorkQueue()
    }

    nonisolated func localImageURL(filename: String) -> URL? {
        imageStore.imageURL(filename: filename)
    }

    private func runStartupReconciliation() async {
        do {
            try await reconcileExistingNotes()
            guard !Task.isCancelled else { return }
            startupReconciliationComplete = true
            startupReconciliationTask = nil
            drainWorkQueue()
        } catch is CancellationError {
            startupReconciliationTask = nil
        } catch {
            startupReconciliationTask = nil
            startupReconciliationFailed = true
            notifyWarning(
                "Automatic link-preview fetching remains paused because startup URL reconciliation failed. No preview requests will be made until the app successfully reconciles notes on a later launch. Details: \(error.localizedDescription)"
            )
        }
    }

    private func reconcileExistingNotes() async throws {
        var cursor: Int64?
        while !Task.isCancelled {
            let snapshots = try database.fetchLinkReconciliationSnapshots(
                afterSortKey: cursor,
                limit: AppDatabase.maximumPageSize
            )
            guard !snapshots.isEmpty else { return }
            for initialSnapshot in snapshots {
                try Task.checkCancellation()
                var snapshot: LinkPreviewReconciliationSnapshot? = initialSnapshot
                var reconciled = false
                for _ in 0..<3 {
                    guard let currentSnapshot = snapshot else {
                        reconciled = true
                        break
                    }
                    try await startupCheckpoint?(currentSnapshot)
                    let links = detector.links(in: currentSnapshot.body)
                    let result = try database.reconcileLinkPreviews(
                        snapshot: currentSnapshot,
                        detectedLinks: links
                    )
                    if result.wasApplied {
                        imageStore.removeImages(named: result.unusedImageFilenames)
                        notify(result.changedNoteIDs)
                        reconciled = true
                        break
                    }
                    snapshot = try database.fetchLinkReconciliationSnapshot(
                        noteID: currentSnapshot.noteID
                    )
                }
                guard reconciled else {
                    throw LinkPreviewCoordinatorError.startupReconciliationChangedRepeatedly
                }
            }
            cursor = snapshots.last?.sortKey
            await Task.yield()
        }
        throw CancellationError()
    }

    private func drainWorkQueue() {
        guard started, resumed, !mutationsPaused, startupReconciliationComplete,
              automaticFetchingEnabled else { return }
        while inFlight.count < Self.maximumConcurrentFetches {
            do {
                let work = try database.fetchLinkPreviewWork(
                    fetchBefore: Date(),
                    excludingRequestKeys: Set(inFlight.keys),
                    limit: Self.maximumConcurrentFetches - inFlight.count
                )
                guard !work.isEmpty else { return }
                var startedWork = false
                for item in work where inFlight[item.requestKey] == nil {
                    startedWork = true
                    inFlight[item.requestKey] = Task { [weak self] in
                        await self?.perform(item)
                    }
                }
                guard startedWork else { return }
            } catch {
                return
            }
        }
    }

    private func perform(_ item: LinkPreviewWorkItem) async {
        defer { finish(item.requestKey) }
        do {
            guard automaticFetchingEnabled,
                  !mutationsPaused,
                  try database.automaticLinkPreviewsEnabled(),
                  try database.hasEligibleLinkPreviewWork(requestKey: item.requestKey),
                  let url = URL(string: item.requestKey) else {
                throw CancellationError()
            }
            if let preFetchCheckpoint {
                try await preFetchCheckpoint(item)
            }
            // Production body edits run on this actor, so this final persisted
            // decision and the fetch invocation are one non-suspending actor
            // segment. Tests deliberately suspend above and require this check
            // to reject an association edited away while paused.
            guard automaticFetchingEnabled,
                  !mutationsPaused,
                  try database.automaticLinkPreviewsEnabled(),
                  try database.hasEligibleLinkPreviewWork(
                      requestKey: item.requestKey
                  ) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            let metadata = try await fetcher.fetchPreview(for: url)
            try Task.checkCancellation()
            guard automaticFetchingEnabled, !mutationsPaused else { throw CancellationError() }

            let newImageFilename = try metadata.imagePNGData.map(imageStore.publishImage)
            do {
                let result = try database.commitLinkPreviewMetadata(
                    requestKey: item.requestKey,
                    metadata: metadata,
                    localImageFilename: newImageFilename
                )
                if let newImageFilename, !result.acceptedNewImage {
                    imageStore.removeImages(named: [newImageFilename])
                }
                if let oldFilename = result.replacedImageFilename {
                    imageStore.removeImages(named: [oldFilename])
                }
                notify(result.changedNoteIDs)
            } catch {
                if let newImageFilename {
                    imageStore.removeImages(named: [newImageFilename])
                }
                throw error
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  !mutationsPaused,
                  automaticFetchingEnabled,
                  (try? database.automaticLinkPreviewsEnabled()) == true,
                  (try? database.hasEligibleLinkPreviewWork(
                      requestKey: item.requestKey
                  )) == true else {
                return
            }
            do {
                let noteIDs = try database.markLinkPreviewFailure(
                    requestKey: item.requestKey,
                    reason: error.localizedDescription
                )
                notify(noteIDs)
            } catch {
                return
            }
        }
    }

    private func reconcileCurrentNote(id: UUID) throws {
        for _ in 0..<3 {
            guard let snapshot = try database.fetchLinkReconciliationSnapshot(noteID: id) else {
                cancelIneligibleWork()
                return
            }
            let links = detector.links(in: snapshot.body)
            let result = try database.reconcileLinkPreviews(
                snapshot: snapshot,
                detectedLinks: links
            )
            guard result.wasApplied else { continue }
            imageStore.removeImages(named: result.unusedImageFilenames)
            notify(result.changedNoteIDs)
            cancelIneligibleWork()
            drainWorkQueue()
            return
        }
        throw LinkPreviewCoordinatorError.noteChangedRepeatedly
    }

    private func finish(_ requestKey: String) {
        inFlight[requestKey] = nil
        drainWorkQueue()
    }

    private func cancelIneligibleWork() {
        for (requestKey, task) in inFlight {
            if (try? database.hasEligibleLinkPreviewWork(requestKey: requestKey)) != true {
                task.cancel()
            }
        }
    }

    private func notify(_ noteIDs: Set<UUID>) {
        guard !noteIDs.isEmpty, let changeHandler else { return }
        Task { @MainActor in changeHandler(noteIDs) }
    }

    private func notifyWarning(_ message: String) {
        guard let warningHandler else { return }
        Task { @MainActor in warningHandler(message) }
    }
}

final class LinkPreviewImageStore: @unchecked Sendable {
    private let provider: ApplicationSupportDirectoryProvider
    private let database: AppDatabase
    private let fileManager: FileManager

    init(
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        fileManager: FileManager
    ) {
        self.provider = provider
        self.database = database
        self.fileManager = fileManager
    }

    func performStartupMaintenance() throws -> Set<UUID> {
        let state = try database.linkPreviewMaintenanceState()
        let files = try fileManager.contentsOfDirectory(
            at: provider.previewsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let managedFiles = files.filter { url in
            Self.safeImageURL(
                filename: url.lastPathComponent,
                provider: provider,
                fileManager: fileManager
            ) != nil
        }
        let existingNames = Set(managedFiles.map(\.lastPathComponent))
        for url in managedFiles
        where !state.referencedImageFilenames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
        let missing = state.referencedImageFilenames.subtracting(existingNames)
        return try database.clearMissingLinkPreviewImages(missing)
    }

    func publishImage(_ data: Data) throws -> String {
        guard !data.isEmpty,
              data.count <= LinkPreviewMetadataFetcher.maximumImageBytes else {
            throw LinkPreviewImageStoreError.invalidImageData
        }
        let filename = "\(UUID().uuidString.lowercased()).png"
        let url = provider.previewsURL.appendingPathComponent(filename, isDirectory: false)
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw LinkPreviewImageStoreError.fileOperationFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try synchronizePreviewDirectory()
            return filename
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw LinkPreviewImageStoreError.fileOperationFailed
        }
    }

    func removeImages<S: Sequence>(named filenames: S) where S.Element == String {
        for filename in filenames {
            guard let url = imageURL(filename: filename) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func imageURL(filename: String) -> URL? {
        Self.safeImageURL(
            filename: filename,
            provider: provider,
            fileManager: fileManager
        )
    }

    static func safeImageURL(
        filename: String,
        provider: ApplicationSupportDirectoryProvider,
        fileManager: FileManager
    ) -> URL? {
        guard filename == filename.lowercased(),
              filename.hasSuffix(".png") else {
            return nil
        }
        let stem = String(filename.dropLast(4))
        guard let identifier = UUID(uuidString: stem),
              identifier.uuidString.lowercased() == stem else {
            return nil
        }
        let url = provider.previewsURL.appendingPathComponent(filename, isDirectory: false)
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isSymbolicLink != true, values.isRegularFile == true else {
            return nil
        }
        return url
    }

    private func synchronizePreviewDirectory() throws {
        let descriptor = provider.previewsURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw LinkPreviewImageStoreError.fileOperationFailed }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw LinkPreviewImageStoreError.fileOperationFailed
        }
    }
}

enum LinkPreviewCoordinatorError: LocalizedError, Equatable {
    case automaticFetchingDisabled
    case mutationsPausedForRestore
    case noteChangedRepeatedly
    case startupReconciliationChangedRepeatedly

    var errorDescription: String? {
        switch self {
        case .automaticFetchingDisabled:
            "Automatic link previews are off. Turn them on in Settings before retrying."
        case .mutationsPausedForRestore:
            "Link-preview changes are paused while restore recovery is pending."
        case .noteChangedRepeatedly:
            "The note changed repeatedly while its link previews were being refreshed."
        case .startupReconciliationChangedRepeatedly:
            "A note changed repeatedly while link-preview state was being reconciled."
        }
    }
}

enum LinkPreviewImageStoreError: LocalizedError, Equatable {
    case fileOperationFailed
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .fileOperationFailed:
            "The preview image could not be stored safely."
        case .invalidImageData:
            "The generated preview image is empty or too large."
        }
    }
}
