import AppKit
import Foundation
import SwiftUI

@MainActor
final class TimelineViewModel: ObservableObject {
    nonisolated static let pageSize = 50

    nonisolated static func isRestoreAdmissionQuiescent(
        canMutateLibrary: Bool,
        isArchiveOperationRunning: Bool,
        isSending: Bool,
        isDiscardingDraft: Bool,
        activeLibraryMutationCount: Int,
        attachmentWorkIsEmpty: Bool
    ) -> Bool {
        canMutateLibrary
            && !isArchiveOperationRunning
            && !isSending
            && !isDiscardingDraft
            && activeLibraryMutationCount == 0
            && attachmentWorkIsEmpty
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var trashNotes: [Note] = []
    @Published private(set) var hasOlderNotes = false
    @Published private(set) var hasOlderTrash = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var isLoadingTrash = false
    @Published private(set) var isSending = false
    @Published private(set) var isDiscardingDraft = false
    @Published private(set) var isReady = false
    @Published private(set) var canRetryInitialLoad = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var draftText = ""
    @Published private(set) var searchText = ""
    @Published private(set) var searchFilters = NoteSearchFilters()
    @Published private(set) var searchSort = NoteSearchSort.relevance
    @Published private(set) var searchResults: [NoteSearchResult] = []
    @Published private(set) var searchResultCount = 0
    @Published private(set) var isSearching = false
    @Published private(set) var searchErrorMessage: String?
    @Published private(set) var isShowingTimelineContext = false
    @Published private(set) var searchTargetNoteID: UUID?
    @Published private(set) var requestedThreadRootID: UUID?
    @Published private(set) var threadRoot: Note?
    @Published private(set) var threadReplies: [Note] = []
    @Published private(set) var isLoadingThread = false
    @Published private(set) var pendingAttachments: [PendingAttachment] = []
    @Published private(set) var automaticLinkPreviewsEnabled = false
    @Published private(set) var isUpdatingLinkPreviewSetting = false
    @Published private(set) var linkPreviewOffSettingNeedsRetry = false
    @Published private(set) var archiveProgress: ArchiveOperationProgress?
    @Published private(set) var isArchiveOperationRunning = false
    @Published private(set) var isRestoreReadyForRelaunch = false
    @Published private(set) var requiresRestoreResolutionRelaunch = false
    @Published private(set) var restoreRelaunchMessage: String?
    @Published private(set) var restoreStartupStatus: String?
    @Published private(set) var automaticBackupDirectoryName: String?
    @Published private var isLibraryMutationPaused = false

    private let database: AppDatabase?
    private let attachmentStore: AttachmentStore?
    private let linkPreviewCoordinator: LinkPreviewCoordinator?
    private let archiveService: ArchiveService?
    private let supportService: SupportService?
    private let startupRecoveryMessage: String?
    private let diagnostics: RedactedDiagnosticLog
    private var didLoad = false
    private var didLoadTrash = false
    private var draftSaveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var timelineNavigationGeneration = 0
    private var threadGeneration = 0
    private var timelineGeneration = 0
    private var trashGeneration = 0
    private var timelinePagingCursor: Int64?
    private var trashPagingCursor: Int64?
    private var timelinePageRequestID: UUID?
    private var trashPageRequestID: UUID?
    private var pendingAttachmentSources: [UUID: PendingAttachmentSource] = [:]
    private var attachmentImportTasks: [UUID: Task<Void, Never>] = [:]
    private var attachmentImportAttempts: [UUID: UUID] = [:]
    private var linkPreviewRefreshGenerations: [UUID: Int] = [:]
    private var archiveOperationTask: Task<Void, Never>?
    private var archiveOperationID: UUID?
    private var activeLibraryMutationCount = 0

    nonisolated static func isReplyComposerReady(
        displayedRootID: UUID?,
        requestedRootID: UUID?,
        isLoading: Bool
    ) -> Bool {
        !isLoading
            && requestedRootID != nil
            && displayedRootID == requestedRootID
    }

    var isReplyComposerReady: Bool {
        Self.isReplyComposerReady(
            displayedRootID: threadRoot?.id,
            requestedRootID: requestedThreadRootID,
            isLoading: isLoadingThread
        )
    }
    private var shouldResumeDraftSaveAfterSupportOperation = false

    init(
        database: AppDatabase?,
        attachmentStore: AttachmentStore? = nil,
        linkPreviewCoordinator: LinkPreviewCoordinator? = nil,
        archiveService: ArchiveService? = nil,
        supportService: SupportService? = nil,
        startupRecoveryMessage: String? = nil,
        diagnostics: RedactedDiagnosticLog = .shared
    ) {
        self.database = database
        self.attachmentStore = attachmentStore
        self.linkPreviewCoordinator = linkPreviewCoordinator
        self.archiveService = archiveService
        self.supportService = supportService
        self.startupRecoveryMessage = startupRecoveryMessage
        self.diagnostics = diagnostics
        automaticBackupDirectoryName = archiveService?.automaticBackupDirectoryName
    }

    var canSend: Bool {
        let hasContent = hasVisibleText(draftText)
            || pendingAttachments.contains { $0.status == .ready }
        let allAttachmentsReady = pendingAttachments.allSatisfy { $0.status == .ready }
        return database != nil
            && canMutateLibrary
            && !isSending
            && !isDiscardingDraft
            && attachmentImportTasks.isEmpty
            && hasContent
            && allAttachmentsReady
    }

    var canAddAttachments: Bool {
        attachmentStore != nil
            && canMutateLibrary
            && !isSending
            && !isDiscardingDraft
    }

    var canMutateLibrary: Bool {
        isReady
            && !isLibraryMutationPaused
            && !isRestoreReadyForRelaunch
            && !requiresRestoreResolutionRelaunch
    }

    var canRunLibraryHealthCheck: Bool {
        supportService != nil
            && canMutateLibrary
            && !isArchiveOperationRunning
            && !isSending
            && !isDiscardingDraft
            && activeLibraryMutationCount == 0
            && attachmentImportTasks.isEmpty
    }

    func checkLibraryHealth() async -> LibraryHealthReport? {
        guard let supportService, await beginSupportOperation() else { return nil }
        let report = await Task.detached(priority: .userInitiated) {
            supportService.checkLibrary()
        }.value
        await finishSupportOperation()
        return report
    }

    func exportSupportInformation(
        to destinationURL: URL,
        latestHealthReport: LibraryHealthReport?
    ) async throws -> URL {
        guard let supportService, await beginSupportOperation() else {
            throw TimelineSupportError.operationUnavailable
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try supportService.exportSupportInformation(
                    to: destinationURL,
                    latestHealthReport: latestHealthReport
                )
            }.value
            await finishSupportOperation()
            return result
        } catch {
            await finishSupportOperation()
            throw error
        }
    }

    private var isRestoreAdmissionQuiescent: Bool {
        Self.isRestoreAdmissionQuiescent(
            canMutateLibrary: canMutateLibrary,
            isArchiveOperationRunning: isArchiveOperationRunning,
            isSending: isSending,
            isDiscardingDraft: isDiscardingDraft,
            activeLibraryMutationCount: activeLibraryMutationCount,
            attachmentWorkIsEmpty: attachmentImportTasks.isEmpty
        )
    }

    var hasDraftContent: Bool {
        !draftText.isEmpty || !pendingAttachments.isEmpty
    }

    var hasSearchCriteria: Bool {
        currentSearchRequest.hasCriteria
    }

    func loadInitialContent() async {
        guard !didLoad, let database else { return }
        didLoad = true
        isLoading = true
        isReady = false
        canRetryInitialLoad = false
        errorMessage = nil
        defer { isLoading = false }

        let generation = timelineGeneration
        do {
            if archiveService?.startupMode != RestoreStartupMode.none {
                restoreStartupStatus = "Validating the restored library before accepting changes…"
            }
            var linkPreviewStartupWarning: String?
            if let linkPreviewCoordinator {
                await linkPreviewCoordinator.setChangeHandler { [weak self] noteIDs in
                    self?.linkPreviewsDidChange(noteIDs)
                }
                await linkPreviewCoordinator.setWarningHandler { [weak self] warning in
                    self?.presentError(warning)
                }
                let startup = await linkPreviewCoordinator.start()
                automaticLinkPreviewsEnabled = startup.automaticFetchingEnabled
                linkPreviewStartupWarning = startup.warning
            }
            let store = attachmentStore
            let verifyRestoredDatabase = archiveService?.startupMode == .trial
            let result = try await Task.detached(priority: .userInitiated) {
                if verifyRestoredDatabase {
                    try database.verifyIntegrityAndForeignKeys()
                }
                let page = try database.fetchNotesPage(limit: Self.pageSize)
                let draft = try database.loadDraft()
                guard let store else {
                    return TimelineInitialLoadResult(
                        page: page,
                        draft: draft,
                        recoveredAttachments: [],
                        maintenanceReport: nil,
                        maintenanceError: nil
                    )
                }
                let recoveredAttachments = try store.loadStagedAttachmentManifest()
                do {
                    return TimelineInitialLoadResult(
                        page: page,
                        draft: draft,
                        recoveredAttachments: recoveredAttachments,
                        maintenanceReport: try store.performStartupMaintenance(
                            recoveredAttachments: recoveredAttachments
                        ),
                        maintenanceError: nil
                    )
                } catch {
                    return TimelineInitialLoadResult(
                        page: page,
                        draft: draft,
                        recoveredAttachments: recoveredAttachments,
                        maintenanceReport: nil,
                        maintenanceError: error.localizedDescription
                    )
                }
            }.value
            guard generation == timelineGeneration else {
                didLoad = false
                await loadInitialContent()
                return
            }
            notes = result.page.notes
            hasOlderNotes = result.page.hasOlder
            timelinePagingCursor = result.page.notes.first?.sortKey
            draftText = result.draft?.body ?? ""
            restorePendingAttachments(result.recoveredAttachments)
            let restoreTrialIssue: String? = {
                guard archiveService?.startupMode == .trial else { return nil }
                if let maintenanceError = result.maintenanceError {
                    return "Attachment maintenance failed: \(maintenanceError)"
                }
                if let report = result.maintenanceReport, report.hasIssues {
                    return "Attachment maintenance found missing restored files."
                }
                if let linkPreviewStartupWarning {
                    return "Preview-file maintenance failed: \(linkPreviewStartupWarning)"
                }
                return nil
            }()
            if let restoreTrialIssue, let archiveService {
                try? archiveService.requestRestoreRollback(restoreTrialIssue)
                await requireRestoreRecoveryRelaunch(
                    "The restored library did not pass startup confirmation. Quit and reopen Self DM Notes; the original library will be restored before SQLite opens. \(restoreTrialIssue)"
                )
                return
            }

            if let maintenanceReport = result.maintenanceReport {
                presentMaintenanceReport(maintenanceReport)
            } else if let maintenanceError = result.maintenanceError {
                presentError(
                    "Attachment startup cleanup could not finish. Recoverable attachment drafts remain visible and no manifest rows were removed; retry cleanup at the next launch. Details: \(maintenanceError)"
                )
            }
            do {
                let service = archiveService
                if service?.startupMode != RestoreStartupMode.none {
                    restoreStartupStatus = "Finalizing durable restore recovery and retained-library cleanup…"
                }
                try await Task.detached(priority: .utility) {
                    try service?.confirmSuccessfulStartup()
                }.value
            } catch let ArchiveServiceError.restoreCancellationCleanupPending(details) {
                await requireRestoreRecoveryRelaunch(
                    "The original library remains active and the restore remains canceled. Staged-library cleanup did not finish; quit and reopen Self DM Notes to resume it. Details: \(details)"
                )
                return
            } catch let ArchiveServiceError.restoreCommittedCleanupPending(details) {
                await requireRestoreRecoveryRelaunch(
                    "The current active library is durably accepted. Retained-library cleanup did not finish; quit and reopen Self DM Notes to resume cleanup. The retained counterpart is no longer a rollback candidate. Details: \(details)"
                )
                return
            } catch let ArchiveServiceError.restoreUnarmedCleanupPending(details) {
                await requireRestoreRecoveryRelaunch(
                    "The active library was never switched, but unarmed restore staging cleanup did not finish. Quit and reopen Self DM Notes to resume cleanup before making changes. Details: \(details)"
                )
                return
            } catch {
                if error as? ArchiveServiceError == .restoreResolutionRequired {
                    await requireRestoreRecoveryRelaunch(
                        "Restore startup confirmation reached an uncertain durability boundary. Both library copies were preserved. Quit and reopen Self DM Notes now so recovery can resolve state before more changes."
                    )
                    return
                }
                if archiveService?.startupMode == .trial {
                    try? archiveService?.requestRestoreRollback(error.localizedDescription)
                    await requireRestoreRecoveryRelaunch(
                        "The restored library could not be confirmed. Quit and reopen Self DM Notes to recover the original library. Details: \(error.localizedDescription)"
                    )
                    return
                }
                if archiveService?.hasPendingRestore == true {
                    await requireRestoreRecoveryRelaunch(
                        "The current active library remains selected, but durable recovery bookkeeping did not finish. Quit and reopen Self DM Notes to resume recovery before making changes. Details: \(error.localizedDescription)"
                    )
                    return
                }
                presentError(
                    "Restore cleanup could not finish, but the current library remains open. Reopen the app before starting another restore. Details: \(error.localizedDescription)"
                )
            }
            restoreStartupStatus = nil
            isReady = true
            if let linkPreviewCoordinator {
                await linkPreviewCoordinator.resumeBackgroundWork()
            }
            if let linkPreviewStartupWarning {
                presentError(
                    "Notes loaded, but link-preview maintenance needs attention. \(linkPreviewStartupWarning)"
                )
            } else if let startupRecoveryMessage {
                presentNotice(startupRecoveryMessage)
            }
            startAutomaticBackupIfDue()
        } catch {
            if archiveService?.startupMode == .trial {
                let reason = "The restored library failed startup validation: \(error.localizedDescription)"
                try? archiveService?.requestRestoreRollback(reason)
                canRetryInitialLoad = false
                await requireRestoreRecoveryRelaunch(
                    "The restored library did not pass startup validation. Quit and reopen Self DM Notes; the original library will be restored before SQLite opens. Details: \(error.localizedDescription)"
                )
                return
            }
            restoreStartupStatus = nil
            didLoad = false
            canRetryInitialLoad = true
            presentError(
                "Notes could not be loaded. Retry the load; no stored notes were changed. Details: \(error.localizedDescription)"
            )
        }
    }

    func retryInitialLoad() async {
        didLoad = false
        await loadInitialContent()
    }

    func loadOlderNotes() async {
        await loadOlderNotes(replacingStaleRequest: false)
    }

    private func loadOlderNotes(replacingStaleRequest: Bool) async {
        guard hasOlderNotes,
              let database,
              let pagingCursor = timelinePagingCursor,
              replacingStaleRequest || !isLoadingOlder else {
            return
        }

        let generation = timelineGeneration
        let requestID = UUID()
        timelinePageRequestID = requestID
        isLoadingOlder = true
        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try database.fetchNotesPage(
                    beforeSortKey: pagingCursor,
                    limit: Self.pageSize
                )
            }.value

            guard requestID == timelinePageRequestID else { return }
            guard generation == timelineGeneration else {
                finishTimelinePageRequest(requestID)
                await refillTimelineIfNeeded()
                return
            }

            let loadedIDs = Set(notes.map(\.id))
            notes.insert(contentsOf: page.notes.filter { !loadedIDs.contains($0.id) }, at: 0)
            hasOlderNotes = page.hasOlder
            if let oldestSortKey = page.notes.first?.sortKey {
                timelinePagingCursor = oldestSortKey
            }
            finishTimelinePageRequest(requestID)
        } catch {
            guard requestID == timelinePageRequestID else { return }
            finishTimelinePageRequest(requestID)
            guard generation == timelineGeneration else {
                await refillTimelineIfNeeded()
                return
            }
            presentError(
                "Older notes could not be loaded. Scroll up to retry. Details: \(error.localizedDescription)"
            )
        }
    }

    func setDraft(_ text: String) {
        guard canMutateLibrary,
              !isSending,
              !isDiscardingDraft else { return }
        draftText = text
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self else { return }
                self.draftSaveTask = nil
                self.persistDraft()
            } catch {
                return
            }
        }
    }

    func flushDraftSynchronously() {
        // sendDraft persists the captured body before its first suspension. Once
        // sending starts, a lifecycle callback must not write that body back after
        // createNote transactionally clears the draft row.
        guard canMutateLibrary, !isSending, !isDiscardingDraft else { return }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        persistDraft()
    }

    func discardDraft() async {
        guard canMutateLibrary,
              !isSending,
              !isDiscardingDraft,
              hasDraftContent,
              let database else { return }
        isDiscardingDraft = true
        defer { isDiscardingDraft = false }

        draftSaveTask?.cancel()
        draftSaveTask = nil
        let importTasks = Array(attachmentImportTasks.values)
        attachmentImportAttempts.removeAll()
        for task in importTasks {
            task.cancel()
        }
        for task in importTasks {
            await task.value
        }
        attachmentImportTasks.removeAll()

        do {
            let discardedAttachments = try await Task.detached(priority: .userInitiated) {
                try database.discardDraft()
            }.value
            draftText = ""
            pendingAttachments = []
            pendingAttachmentSources = [:]
            attachmentImportAttempts = [:]

            let cleanupFailed: Bool
            if let attachmentStore {
                cleanupFailed = await Task.detached(priority: .utility) {
                    attachmentStore.removeDiscardedDraftFiles(discardedAttachments)
                }.value
            } else {
                cleanupFailed = false
            }
            if cleanupFailed {
                presentNotice(
                    "Draft discarded. Leftover unreferenced staging files will be removed by startup cleanup."
                )
            } else {
                presentNotice("Draft and pending attachments discarded.")
            }
        } catch {
            for index in pendingAttachments.indices
            where pendingAttachments[index].status == .importing {
                pendingAttachments[index].status = .failed
                pendingAttachments[index].progress = 0
                pendingAttachments[index].errorMessage =
                    "Discard did not finish. The import was canceled; retry or remove it."
                pendingAttachments[index].canRetry =
                    pendingAttachmentSources[pendingAttachments[index].id] != nil
                pendingAttachments[index].stagedAttachment = nil
            }
            do {
                try database.saveDraft(body: draftText)
                presentError(
                    "The draft could not be discarded. Its visible text and persisted attachment manifest remain recoverable; canceled imports can be retried or removed. Details: \(error.localizedDescription)"
                )
            } catch let draftSaveError {
                presentError(
                    "The draft could not be discarded, and its visible text could not be made durable. Copy the text before closing the app. Persisted attachment metadata was not intentionally cleared. Discard details: \(error.localizedDescription) Draft-save details: \(draftSaveError.localizedDescription)"
                )
            }
        }
    }

    func sendDraft() async -> Note? {
        guard canSend, let database else { return nil }
        let body = draftText
        let stagedAttachments = pendingAttachments.compactMap(\.stagedAttachment)
            .sorted { $0.sortIndex < $1.sortIndex }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        isSending = true
        defer { isSending = false }

        do {
            // Persist the latest editor state before attempting note insertion. A
            // successful insertion clears this row in the same database transaction.
            try database.saveDraft(body: body)
            let store = attachmentStore
            let result = try await Task.detached(priority: .userInitiated) {
                if let store, !stagedAttachments.isEmpty {
                    return try store.commitNote(
                        body: body,
                        stagedAttachments: stagedAttachments
                    )
                }
                return AttachmentCommitResult(
                    note: try database.createNote(body: body),
                    stagingCleanupFailed: false
                )
            }.value
            let note = result.note
            invalidateTimelinePages()
            draftText = ""
            pendingAttachments = []
            pendingAttachmentSources = [:]
            attachmentImportTasks = [:]
            attachmentImportAttempts = [:]
            notes.append(note)
            if let linkPreviewCoordinator {
                Task { await linkPreviewCoordinator.reconcileNote(id: note.id) }
            }
            refreshSearchIfNeeded()
            if result.stagingCleanupFailed {
                presentNotice(
                    "Note sent. A leftover staging file will be removed automatically at next launch."
                )
            } else {
                presentNotice("Note sent.")
            }
            return note
        } catch {
            presentError(
                "The note was not saved. Its text and completed attachment copies remain together in the recoverable draft. Fix any failed attachment, retry Send, or remove attachments explicitly. Details: \(error.localizedDescription)"
            )
            return nil
        }
    }

    func editNote(_ note: Note, body: String) async -> Bool {
        guard canMutateLibrary,
              hasVisibleText(body) || !note.attachments.isEmpty,
              let database else { return false }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            let updatedNote: Note
            if let linkPreviewCoordinator {
                updatedNote = try await linkPreviewCoordinator.editNote(
                    id: note.id,
                    body: body
                )
            } else {
                updatedNote = try await Task.detached(priority: .userInitiated) {
                    try database.editNote(id: note.id, body: body)
                }.value
            }
            invalidateTimelinePages()
            Self.replaceNote(updatedNote, in: &notes)
            if threadRoot?.id == updatedNote.id {
                threadRoot = updatedNote
            }
            Self.replaceNote(updatedNote, in: &threadReplies)
            refreshSearchIfNeeded()
            presentNotice("Note updated.")
            return true
        } catch {
            presentError(
                "The edit was not saved. The edit window remains open so you can retry or copy the text. Details: \(error.localizedDescription)"
            )
            return false
        }
    }

    func copyNote(_ note: Note) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(note.body, forType: .string) {
            presentNotice("Note copied.")
        } else {
            presentError("The note could not be copied. Select its text and copy it manually.")
        }
    }

    func openThread(rootID: UUID) async -> Bool {
        guard let database else { return false }
        threadGeneration += 1
        let generation = threadGeneration
        requestedThreadRootID = rootID
        if threadRoot?.id != rootID {
            threadRoot = nil
            threadReplies = []
        }
        isLoadingThread = true
        do {
            let thread = try await Task.detached(priority: .userInitiated) {
                try database.fetchThread(rootID: rootID)
            }.value
            guard generation == threadGeneration,
                  requestedThreadRootID == rootID else { return false }
            threadRoot = thread.root
            threadReplies = thread.replies
            Self.replaceNote(thread.root, in: &notes)
            isLoadingThread = false
            return true
        } catch {
            guard generation == threadGeneration,
                  requestedThreadRootID == rootID else { return false }
            isLoadingThread = false
            threadRoot = nil
            threadReplies = []
            presentError(
                "The thread could not be opened. It may have been deleted. Details: \(error.localizedDescription)"
            )
            return false
        }
    }

    func closeThread() {
        threadGeneration += 1
        isLoadingThread = false
        requestedThreadRootID = nil
        threadRoot = nil
        threadReplies = []
    }

    func stageReplyFile(at url: URL, id: UUID, sortIndex: Int) async throws -> StagedAttachment {
        guard canMutateLibrary, let attachmentStore else {
            throw TimelineSupportError.operationUnavailable
        }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        return try await Task.detached(priority: .userInitiated) {
            try attachmentStore.stageSelectedFile(
                at: url,
                id: id,
                sortIndex: sortIndex,
                persistDraft: false
            )
        }.value
    }

    func stageReplyClipboardImage(
        data: Data,
        filename: String,
        mediaType: String,
        id: UUID,
        sortIndex: Int
    ) async throws -> StagedAttachment {
        guard canMutateLibrary, let attachmentStore else {
            throw TimelineSupportError.operationUnavailable
        }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        return try await Task.detached(priority: .userInitiated) {
            try attachmentStore.stageClipboardImage(
                data: data,
                originalFilename: filename,
                mediaType: mediaType,
                id: id,
                sortIndex: sortIndex,
                persistDraft: false
            )
        }.value
    }

    func discardReplyAttachment(_ attachment: StagedAttachment) {
        guard let attachmentStore else { return }
        Task.detached(priority: .utility) {
            try? attachmentStore.discardStagedAttachment(attachment)
        }
    }

    func sendReply(
        to root: Note,
        body: String,
        stagedAttachments: [StagedAttachment]
    ) async -> Note? {
        guard canMutateLibrary,
              !root.isReply,
              requestedThreadRootID == root.id,
              threadRoot?.id == root.id,
              !isLoadingThread,
              hasVisibleText(body) || !stagedAttachments.isEmpty,
              let database else { return nil }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            let store = attachmentStore
            let result = try await Task.detached(priority: .userInitiated) {
                if let store, !stagedAttachments.isEmpty {
                    return try store.commitReply(
                        rootID: root.id,
                        body: body,
                        stagedAttachments: stagedAttachments
                    )
                }
                return AttachmentCommitResult(
                    note: try database.createReply(rootID: root.id, body: body),
                    stagingCleanupFailed: false
                )
            }.value
            let reply = result.note
            if threadRoot?.id == root.id {
                Self.insertInOrder(reply, into: &threadReplies)
            }
            if let refreshedRoot = try? database.fetchNote(id: root.id) {
                threadRoot = threadRoot?.id == root.id ? refreshedRoot : threadRoot
                Self.replaceNote(refreshedRoot, in: &notes)
            }
            if let linkPreviewCoordinator {
                Task { await linkPreviewCoordinator.reconcileNote(id: reply.id) }
            }
            refreshSearchIfNeeded()
            presentNotice(
                result.stagingCleanupFailed
                    ? "Reply sent. A leftover staging file will be removed automatically at next launch."
                    : "Reply sent."
            )
            return reply
        } catch {
            presentError(
                "The reply was not saved. Its text remains in the thread composer so you can retry or copy it. Details: \(error.localizedDescription)"
            )
            return nil
        }
    }

    func previewAttachment(_ attachment: Attachment) {
        guard let url = availableOriginalURL(for: attachment) else { return }
        AttachmentQuickLookController.shared.preview(
            url: url,
            title: attachment.originalFilename
        )
    }

    func openAttachment(_ attachment: Attachment) {
        guard let store = attachmentStore,
              availableOriginalURL(for: attachment) != nil else { return }
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try store.makeExternalPresentation(for: attachment)
                }.value
                if !NSWorkspace.shared.open(url) {
                    presentError(
                        "No application could open “\(attachment.originalFilename)”. Use Export to save a copy or Reveal in Finder to inspect it."
                    )
                }
            } catch {
                presentError(
                    "“\(attachment.originalFilename)” could not be prepared for opening. The archived original was not changed. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func revealAttachment(_ attachment: Attachment) {
        guard let store = attachmentStore,
              availableOriginalURL(for: attachment) != nil else { return }
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try store.makeExternalPresentation(for: attachment)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                presentError(
                    "“\(attachment.originalFilename)” could not be prepared for Finder. The archived original was not changed. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func copyAttachment(_ attachment: Attachment) {
        guard let store = attachmentStore,
              availableOriginalURL(for: attachment) != nil else {
            return
        }
        Task {
            do {
                let presentationURL = try await Task.detached(priority: .userInitiated) {
                    try store.makeExternalPresentation(for: attachment)
                }.value
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.writeObjects([presentationURL as NSURL]) else {
                    throw AttachmentStoreError.fileOperationFailed(
                        "The clipboard rejected the file reference."
                    )
                }
                presentNotice("Attachment copied. Its archived original remains unchanged.")
            } catch {
                presentError(
                    "“\(attachment.originalFilename)” could not be copied to the clipboard. Use Export instead. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func exportAttachment(_ attachment: Attachment) async {
        guard let store = attachmentStore,
              availableOriginalURL(for: attachment) != nil else {
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Attachment"
        panel.prompt = "Export"
        panel.nameFieldStringValue = attachment.originalFilename
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.exportAttachment(attachment, to: destinationURL)
            }.value
            presentNotice("“\(attachment.originalFilename)” exported.")
        } catch {
            presentError(
                "“\(attachment.originalFilename)” could not be exported. The archived original was not changed. Details: \(error.localizedDescription)"
            )
        }
    }

    func chooseAutomaticBackupDirectory() {
        guard canMutateLibrary,
              !isArchiveOperationRunning,
              let archiveService else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Automatic Backup Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        do {
            try archiveService.configureAutomaticBackupDirectory(directoryURL)
            automaticBackupDirectoryName = archiveService.automaticBackupDirectoryName
            presentNotice(
                "Automatic daily backups will be stored in “\(directoryURL.lastPathComponent)”."
            )
            startAutomaticBackupIfDue()
        } catch {
            presentError(
                "The automatic backup folder could not be saved. Details: \(error.localizedDescription)"
            )
        }
    }

    func removeAutomaticBackupDirectory() {
        guard canMutateLibrary,
              !isArchiveOperationRunning,
              let archiveService else { return }
        archiveService.removeAutomaticBackupDirectory()
        automaticBackupDirectoryName = nil
        presentNotice("Automatic backups disabled. Existing backup packages were not changed.")
    }

    func createManualBackup() {
        guard let archiveService,
              let destinationURL = chooseArchiveDirectory(
                title: "Choose Backup Folder",
                prompt: "Back Up Here"
              ),
              let operationID = beginArchiveOperation(kind: .backup) else { return }
        diagnostics.record(.backup, outcome: .started)
        let diagnostics = diagnostics
        let model = self
        archiveOperationTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try archiveService.createManualBackup(
                    in: destinationURL,
                    progress: { progress in
                        Task { @MainActor in model.updateArchiveProgress(progress, id: operationID) }
                    }
                )
                var message = "Verified backup created: \(result.packageURL.lastPathComponent)."
                if let warning = result.rotationWarning { message += " \(warning)" }
                diagnostics.record(.backup, outcome: .succeeded)
                await model.finishArchiveOperation(id: operationID, notice: message)
            } catch is CancellationError {
                diagnostics.record(.backup, outcome: .canceled)
                await model.finishArchiveOperation(
                    id: operationID,
                    notice: "Backup canceled before publication. Existing backups were not changed."
                )
            } catch {
                diagnostics.record(.backup, outcome: .failed)
                await model.finishArchiveOperation(
                    id: operationID,
                    error: "The backup was not completed or reported successful. Existing backups were not changed. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func exportPortableArchive() {
        guard let archiveService,
              let destinationURL = chooseArchiveDirectory(
                title: "Choose Portable Export Folder",
                prompt: "Export Here"
              ),
              let operationID = beginArchiveOperation(kind: .export) else { return }
        diagnostics.record(.portableExport, outcome: .started)
        let diagnostics = diagnostics
        let model = self
        archiveOperationTask = Task.detached(priority: .userInitiated) {
            do {
                let url = try archiveService.exportPortableArchive(
                    in: destinationURL,
                    progress: { progress in
                        Task { @MainActor in model.updateArchiveProgress(progress, id: operationID) }
                    }
                )
                diagnostics.record(.portableExport, outcome: .succeeded)
                await model.finishArchiveOperation(
                    id: operationID,
                    notice: "Portable JSON and Markdown export created: \(url.lastPathComponent)."
                )
            } catch is CancellationError {
                diagnostics.record(.portableExport, outcome: .canceled)
                await model.finishArchiveOperation(
                    id: operationID,
                    notice: "Portable export canceled before publication."
                )
            } catch {
                diagnostics.record(.portableExport, outcome: .failed)
                await model.finishArchiveOperation(
                    id: operationID,
                    error: "The portable export was not completed. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func chooseAndStageRestore() {
        guard let archiveService,
              isRestoreAdmissionQuiescent else { return }
        flushDraftSynchronously()
        let panel = NSOpenPanel()
        panel.title = "Choose a Self DM Notes Backup"
        panel.prompt = "Validate Backup"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let packageURL = panel.url else { return }
        let operationID = UUID()
        guard isRestoreAdmissionQuiescent else { return }
        archiveOperationID = operationID
        isArchiveOperationRunning = true
        isLibraryMutationPaused = true
        archiveProgress = ArchiveOperationProgress(
            kind: .restore,
            fraction: 0,
            message: "Preparing…"
        )
        diagnostics.record(.restore, outcome: .started)
        let diagnostics = diagnostics
        let model = self
        let previewCoordinator = linkPreviewCoordinator
        archiveOperationTask = Task.detached(priority: .userInitiated) {
            await previewCoordinator?.pauseBackgroundWork()
            do {
                try Task.checkCancellation()
                let result = try archiveService.stageRestore(
                    from: packageURL,
                    progress: { progress in
                        Task { @MainActor in model.updateArchiveProgress(progress, id: operationID) }
                    }
                )
                diagnostics.record(.restore, outcome: .succeeded)
                await model.finishStagedRestore(id: operationID, result: result)
            } catch is CancellationError {
                diagnostics.record(.restore, outcome: .canceled)
                await model.finishRestoreStagingFailure(
                    id: operationID,
                    notice: "Restore validation canceled before the durable switch was armed. The active library was not changed."
                )
            } catch ArchiveServiceError.restoreResolutionRequired,
                    ArchiveServiceError.restoreAlreadyPending,
                    ArchiveServiceError.restoreStateAmbiguous,
                    ArchiveServiceError.restoreCancellationUnsafe {
                diagnostics.record(.restore, outcome: .failed)
                await model.finishRestoreResolutionRequired(
                    id: operationID,
                    message: "Restore state requires startup recovery before more changes. The current and staged library data were preserved. Quit and reopen Self DM Notes now so recovery runs before SQLite opens."
                )
            } catch {
                diagnostics.record(.restore, outcome: .failed)
                await model.finishRestoreStagingFailure(
                    id: operationID,
                    error: "The backup was rejected before any library switch. The active library remains usable. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func cancelArchiveOperation() {
        guard isArchiveOperationRunning else { return }
        archiveOperationTask?.cancel()
        if let progress = archiveProgress {
            archiveProgress = ArchiveOperationProgress(
                kind: progress.kind,
                fraction: progress.fraction,
                message: "Canceling at the next safe boundary…"
            )
        }
    }

    func cancelPendingRestore() {
        guard isRestoreReadyForRelaunch,
              !isArchiveOperationRunning,
              let archiveService else { return }
        let operationID = UUID()
        archiveOperationID = operationID
        isArchiveOperationRunning = true
        isRestoreReadyForRelaunch = false
        archiveProgress = ArchiveOperationProgress(
            kind: .restore,
            fraction: 0.5,
            message: "Canceling the staged restore…"
        )
        let model = self
        archiveOperationTask = Task.detached(priority: .utility) {
            do {
                try archiveService.cancelPendingRestore()
                await model.finishPendingRestoreCancellation(id: operationID)
            } catch {
                await model.finishRestoreResolutionRequired(
                    id: operationID,
                    message: "The pending restore could not be canceled safely. Both library copies were preserved. Quit and reopen Self DM Notes to resolve it before making changes. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    func quitAndApplyRestore() {
        guard isRestoreReadyForRelaunch else { return }
        flushDraftSynchronously()
        NSApplication.shared.terminate(nil)
    }

    func quitAndResolveRestore() {
        guard requiresRestoreResolutionRelaunch else { return }
        flushDraftSynchronously()
        NSApplication.shared.terminate(nil)
    }

    func thumbnailURL(for attachment: Attachment) -> URL? {
        attachmentStore?.thumbnailURL(for: attachment)
    }

    func linkPreviewImageURL(for preview: LinkPreview) -> URL? {
        guard let filename = preview.localImageFilename else { return nil }
        return linkPreviewCoordinator?.localImageURL(filename: filename)
    }

    func openLinkPreview(_ preview: LinkPreview) {
        guard let url = URL(string: preview.originalURL), NSWorkspace.shared.open(url) else {
            presentError(
                "The link could not be opened. Copy its destination and open it manually."
            )
            return
        }
        presentNotice("Link opened in the default browser.")
    }

    func copyLinkPreview(_ preview: LinkPreview) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(preview.originalURL, forType: .string) {
            presentNotice("Link destination copied.")
        } else {
            presentError("The link could not be copied. Select the URL in the note instead.")
        }
    }

    func retryLinkPreview(_ preview: LinkPreview) async {
        guard canMutateLibrary, let linkPreviewCoordinator else { return }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            try await linkPreviewCoordinator.retry(previewID: preview.id)
            presentNotice("Link preview retry started.")
        } catch {
            presentError(
                "The link preview could not be retried. Details: \(error.localizedDescription)"
            )
        }
    }

    func removeLinkPreview(_ preview: LinkPreview) async {
        guard canMutateLibrary, let linkPreviewCoordinator else { return }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            try await linkPreviewCoordinator.remove(previewID: preview.id)
            presentNotice("Link preview removed. The note text and URL were not changed.")
        } catch {
            presentError(
                "The link preview could not be removed. The note was not changed. Details: \(error.localizedDescription)"
            )
        }
    }

    func setAutomaticLinkPreviewsEnabled(_ enabled: Bool) async {
        guard canMutateLibrary,
              !isUpdatingLinkPreviewSetting,
              let linkPreviewCoordinator else { return }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        isUpdatingLinkPreviewSetting = true
        defer { isUpdatingLinkPreviewSetting = false }
        do {
            try await linkPreviewCoordinator.setAutomaticFetchingEnabled(enabled)
            automaticLinkPreviewsEnabled = enabled
            linkPreviewOffSettingNeedsRetry = false
            presentNotice(
                enabled
                    ? "Automatic link previews enabled. Pending links will be fetched in the background."
                    : "Automatic link previews disabled. In-flight preview requests were canceled."
            )
        } catch {
            if !enabled {
                automaticLinkPreviewsEnabled = false
                linkPreviewOffSettingNeedsRetry = true
                presentError(
                    "Automatic link previews are off for this session, and in-flight requests were canceled, but the durable Off setting could not be saved. Use “Retry Saving Off Setting” before quitting. Details: \(error.localizedDescription)"
                )
                return
            }
            presentError(
                "The link preview setting could not be saved. Details: \(error.localizedDescription)"
            )
        }
    }

    func moveNoteToTrash(_ note: Note) async {
        guard canMutateLibrary, let database else { return }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            let deletedNote = try await Task.detached(priority: .userInitiated) {
                try database.moveNoteToTrash(id: note.id)
            }.value
            invalidateTimelinePages()
            invalidateTrashPages()
            if let rootID = deletedNote.threadRootID {
                threadReplies.removeAll { $0.id == deletedNote.id }
                if let refreshedRoot = try? database.fetchNote(id: rootID) {
                    threadRoot = threadRoot?.id == rootID ? refreshedRoot : threadRoot
                    Self.replaceNote(refreshedRoot, in: &notes)
                }
            } else {
                notes.removeAll { $0.id == note.id }
                if threadRoot?.id == note.id {
                    closeThread()
                }
            }
            if let linkPreviewCoordinator {
                await linkPreviewCoordinator.noteBecameIneligible()
            }
            if searchTargetNoteID == note.id {
                searchTargetNoteID = nil
            }
            if didLoadTrash,
               Self.belongsInLoadedWindow(
                   deletedNote,
                   hasOlder: hasOlderTrash,
                   pagingCursor: trashPagingCursor
               ) {
                Self.insertInOrder(deletedNote, into: &trashNotes)
            }
            refreshSearchIfNeeded()
            presentNotice("Note moved to Trash.")
            await refillTimelineIfNeeded()
        } catch {
            presentError(
                "The note could not be moved to Trash and remains in the timeline. Retry the action. Details: \(error.localizedDescription)"
            )
        }
    }

    func loadTrash() async {
        guard !isLoadingTrash, let database else { return }
        let generation = trashGeneration
        let requestID = UUID()
        trashPageRequestID = requestID
        isLoadingTrash = true
        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try database.fetchTrashPage(limit: Self.pageSize)
            }.value

            guard requestID == trashPageRequestID else { return }
            guard generation == trashGeneration else {
                finishTrashPageRequest(requestID)
                await loadTrash()
                return
            }

            trashNotes = page.notes
            hasOlderTrash = page.hasOlder
            trashPagingCursor = page.notes.first?.sortKey
            didLoadTrash = true
            finishTrashPageRequest(requestID)
        } catch {
            guard requestID == trashPageRequestID else { return }
            finishTrashPageRequest(requestID)
            guard generation == trashGeneration else {
                await loadTrash()
                return
            }
            presentError(
                "Trash could not be loaded. Close and reopen Trash to retry. Details: \(error.localizedDescription)"
            )
        }
    }

    func loadOlderTrash() async {
        await loadOlderTrash(replacingStaleRequest: false)
    }

    private func loadOlderTrash(replacingStaleRequest: Bool) async {
        guard hasOlderTrash,
              let database,
              let pagingCursor = trashPagingCursor,
              replacingStaleRequest || !isLoadingTrash else {
            return
        }

        let generation = trashGeneration
        let requestID = UUID()
        trashPageRequestID = requestID
        isLoadingTrash = true
        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try database.fetchTrashPage(
                    beforeSortKey: pagingCursor,
                    limit: Self.pageSize
                )
            }.value

            guard requestID == trashPageRequestID else { return }
            guard generation == trashGeneration else {
                finishTrashPageRequest(requestID)
                await refillTrashIfNeeded()
                return
            }

            let loadedIDs = Set(trashNotes.map(\.id))
            trashNotes.insert(contentsOf: page.notes.filter { !loadedIDs.contains($0.id) }, at: 0)
            hasOlderTrash = page.hasOlder
            if let oldestSortKey = page.notes.first?.sortKey {
                trashPagingCursor = oldestSortKey
            }
            finishTrashPageRequest(requestID)
        } catch {
            guard requestID == trashPageRequestID else { return }
            finishTrashPageRequest(requestID)
            guard generation == trashGeneration else {
                await refillTrashIfNeeded()
                return
            }
            presentError(
                "Older Trash items could not be loaded. Retry the action. Details: \(error.localizedDescription)"
            )
        }
    }

    func restoreNote(_ note: Note) async {
        guard canMutateLibrary, let database else { return }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            let restoredNote = try await Task.detached(priority: .userInitiated) {
                try database.restoreNote(id: note.id)
            }.value
            invalidateTimelinePages()
            invalidateTrashPages()
            trashNotes.removeAll { $0.id == note.id }
            if let rootID = restoredNote.threadRootID {
                if threadRoot?.id == rootID {
                    Self.insertInOrder(restoredNote, into: &threadReplies)
                }
                if let refreshedRoot = try? database.fetchNote(id: rootID) {
                    threadRoot = threadRoot?.id == rootID ? refreshedRoot : threadRoot
                    Self.replaceNote(refreshedRoot, in: &notes)
                }
            } else if Self.belongsInLoadedWindow(
                restoredNote,
                hasOlder: hasOlderNotes,
                pagingCursor: timelinePagingCursor
            ) {
                Self.insertInOrder(restoredNote, into: &notes)
            }
            if let linkPreviewCoordinator {
                await linkPreviewCoordinator.reconcileNote(id: restoredNote.id)
                if !restoredNote.isReply,
                   let restoredThread = try? database.fetchThread(rootID: restoredNote.id) {
                    for reply in restoredThread.replies {
                        await linkPreviewCoordinator.reconcileNote(id: reply.id)
                    }
                }
            }
            refreshSearchIfNeeded()
            presentNotice("Note restored.")
            await refillTrashIfNeeded()
        } catch {
            presentError(
                "The note could not be restored and remains in Trash. Retry the action. Details: \(error.localizedDescription)"
            )
        }
    }

    func permanentlyDeleteNote(_ note: Note) async {
        guard canMutateLibrary, let database else { return }
        activeLibraryMutationCount += 1
        defer { activeLibraryMutationCount -= 1 }
        do {
            let store = attachmentStore
            let deletionResult = try await Task.detached(priority: .userInitiated) {
                if let store {
                    return try store.permanentlyDeleteNote(id: note.id)
                }
                _ = try database.permanentlyDeleteNote(id: note.id)
                return AttachmentDeletionResult(managedFileCleanupFailed: false)
            }.value
            invalidateTrashPages()
            trashNotes.removeAll { $0.id == note.id }
            if let rootID = note.threadRootID,
               let refreshedRoot = try? database.fetchNote(id: rootID) {
                threadRoot = threadRoot?.id == rootID ? refreshedRoot : threadRoot
                threadReplies.removeAll { $0.id == note.id }
                Self.replaceNote(refreshedRoot, in: &notes)
            }
            if let linkPreviewCoordinator {
                await linkPreviewCoordinator.noteBecameIneligible()
            }
            refreshSearchIfNeeded()
            if deletionResult.managedFileCleanupFailed {
                presentNotice(
                    "Note permanently deleted. An unreferenced managed file will be removed automatically at next launch."
                )
            } else {
                presentNotice("Note permanently deleted.")
            }
            await refillTrashIfNeeded()
        } catch {
            presentError(
                "The note was not permanently deleted and remains in Trash. Retry the action. Details: \(error.localizedDescription)"
            )
        }
    }

    func addFileAttachments(_ urls: [URL]) {
        guard canAddAttachments else { return }
        for url in urls {
            let id = UUID()
            let source = PendingAttachmentSource.file(url)
            pendingAttachmentSources[id] = source
            pendingAttachments.append(
                PendingAttachment(
                    id: id,
                    displayName: url.lastPathComponent,
                    status: .importing,
                    progress: 0,
                    errorMessage: nil,
                    canRetry: true,
                    stagedAttachment: nil
                )
            )
            startAttachmentImport(id: id, source: source)
        }
    }

    func addClipboardImage(data: Data, filename: String, mediaType: String) {
        guard canAddAttachments else { return }
        let id = UUID()
        let source = PendingAttachmentSource.clipboard(
            data: data,
            filename: filename,
            mediaType: mediaType
        )
        pendingAttachmentSources[id] = source
        pendingAttachments.append(
            PendingAttachment(
                id: id,
                displayName: filename,
                status: .importing,
                progress: 0,
                errorMessage: nil,
                canRetry: true,
                stagedAttachment: nil
            )
        )
        startAttachmentImport(id: id, source: source)
    }

    func reportAttachmentCaptureError(_ message: String) {
        presentError(message)
    }

    func retryPendingAttachment(id: UUID) {
        guard canMutateLibrary,
              !isSending,
              !isDiscardingDraft,
              let source = pendingAttachmentSources[id],
              attachmentImportTasks[id] == nil,
              let attachment = pendingAttachments.first(where: { $0.id == id }),
              attachment.status == .failed,
              attachment.canRetry else {
            return
        }
        startAttachmentImport(id: id, source: source)
    }

    func cancelPendingAttachment(id: UUID) {
        guard canMutateLibrary,
              !isSending,
              !isDiscardingDraft,
              let task = attachmentImportTasks[id],
              let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        task.cancel()
        pendingAttachments[index].status = .failed
        pendingAttachments[index].errorMessage = "Canceling import…"
        pendingAttachments[index].canRetry = false
    }

    func removePendingAttachment(id: UUID) {
        guard canMutateLibrary, !isSending, !isDiscardingDraft else { return }
        attachmentImportAttempts[id] = nil
        pendingAttachmentSources[id] = nil
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAttachments.remove(at: index)
        guard let store = attachmentStore else { return }
        if let importTask = attachmentImportTasks[id] {
            importTask.cancel()
            attachmentImportTasks[id] = Task { [weak self] in
                await importTask.value
                await Task.detached(priority: .utility) {
                    store.discardStagingFiles(id: id)
                }.value
                self?.attachmentImportTasks[id] = nil
            }
            return
        }
        attachmentImportTasks[id] = Task { [weak self] in
            await Task.detached(priority: .utility) {
                if let staged = pending.stagedAttachment {
                    try? store.discardStagedAttachment(staged)
                } else {
                    store.discardStagingFiles(id: id)
                }
            }.value
            self?.attachmentImportTasks[id] = nil
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissNotice() {
        noticeMessage = nil
    }

    func setSearchText(_ text: String) {
        searchText = text
        scheduleSearch()
    }

    func setSearchSort(_ sort: NoteSearchSort) {
        searchSort = sort
        scheduleSearch()
    }

    func setSearchDateRange(start: Date?, endExclusive: Date?) {
        searchFilters.startDate = start
        searchFilters.endDateExclusive = endExclusive
        scheduleSearch()
    }

    func setSearchHasAttachment(_ enabled: Bool) {
        searchFilters.hasAttachment = enabled
        scheduleSearch()
    }

    func setSearchHasImage(_ enabled: Bool) {
        searchFilters.hasImage = enabled
        scheduleSearch()
    }

    func setSearchHasLink(_ enabled: Bool) {
        searchFilters.hasLink = enabled
        scheduleSearch()
    }

    func clearSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        searchText = ""
        searchFilters = NoteSearchFilters()
        searchSort = .relevance
        searchResults = []
        searchResultCount = 0
        searchErrorMessage = nil
        isSearching = false
    }

    func revealSearchResult(_ result: NoteSearchResult) async -> Note? {
        timelineNavigationGeneration += 1
        let navigationGeneration = timelineNavigationGeneration
        let navigationNoteID = result.navigationNoteID
        if let loadedNote = notes.first(where: { $0.id == navigationNoteID }) {
            isShowingTimelineContext = isShowingTimelineContext || loadedNote.id != notes.last?.id
            searchTargetNoteID = loadedNote.id
            return loadedNote
        }
        guard let database else { return nil }
        let pageGeneration = timelineGeneration

        do {
            let context = try await Task.detached(priority: .userInitiated) {
                try database.fetchTimelineContext(around: navigationNoteID)
            }.value
            guard navigationGeneration == timelineNavigationGeneration,
                  pageGeneration == timelineGeneration else {
                return nil
            }
            invalidateTimelinePages()
            notes = context.notes
            hasOlderNotes = context.hasOlder
            timelinePagingCursor = context.notes.first?.sortKey
            isShowingTimelineContext = context.hasNewer
            searchTargetNoteID = context.selectedNoteID
            return context.notes.first { $0.id == context.selectedNoteID }
        } catch {
            guard navigationGeneration == timelineNavigationGeneration,
                  pageGeneration == timelineGeneration else {
                return nil
            }
            presentError(
                "That search result could not be loaded in the timeline. It may have been deleted. Retry the search. Details: \(error.localizedDescription)"
            )
            refreshSearchIfNeeded()
            return nil
        }
    }

    func returnToNewest() async -> Note? {
        guard let database else { return nil }
        timelineNavigationGeneration += 1
        let navigationGeneration = timelineNavigationGeneration
        let pageGeneration = timelineGeneration
        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try database.fetchNotesPage(limit: Self.pageSize)
            }.value
            guard navigationGeneration == timelineNavigationGeneration,
                  pageGeneration == timelineGeneration else {
                return nil
            }
            invalidateTimelinePages()
            notes = page.notes
            hasOlderNotes = page.hasOlder
            timelinePagingCursor = page.notes.first?.sortKey
            isShowingTimelineContext = false
            searchTargetNoteID = nil
            return page.notes.last
        } catch {
            guard navigationGeneration == timelineNavigationGeneration,
                  pageGeneration == timelineGeneration else {
                return nil
            }
            presentError(
                "The newest notes could not be loaded. Retry the action. Details: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func persistDraft() {
        guard canMutateLibrary, let database else { return }
        do {
            try database.saveDraft(body: draftText)
        } catch {
            presentError(
                "The draft could not be saved yet. Keep the app open and retry by typing another character, or copy the text before closing. Details: \(error.localizedDescription)"
            )
        }
    }

    private func availableOriginalURL(for attachment: Attachment) -> URL? {
        guard let store = attachmentStore,
              store.attachmentIsAvailable(attachment) else {
            presentError(
                "The managed original for “\(attachment.originalFilename)” is missing. The note and metadata were preserved; restore the library from a backup before retrying this action."
            )
            return nil
        }
        return store.originalURL(for: attachment)
    }

    private func linkPreviewsDidChange(_ noteIDs: Set<UUID>) {
        guard let database, !noteIDs.isEmpty else { return }
        let generations = Dictionary(uniqueKeysWithValues: noteIDs.map { noteID in
            let generation = (linkPreviewRefreshGenerations[noteID] ?? 0) + 1
            linkPreviewRefreshGenerations[noteID] = generation
            return (noteID, generation)
        })
        Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: noteIDs.compactMap { noteID in
                    (try? database.fetchNote(id: noteID)).map { (noteID, $0.linkPreviews) }
                })
            }.value
            guard let self else { return }
            for (noteID, linkPreviews) in refreshed
            where self.linkPreviewRefreshGenerations[noteID] == generations[noteID] {
                Self.replaceLinkPreviews(linkPreviews, noteID: noteID, in: &self.notes)
                Self.replaceLinkPreviews(linkPreviews, noteID: noteID, in: &self.trashNotes)
                if self.threadRoot?.id == noteID {
                    self.threadRoot = self.threadRoot.map {
                        Self.replacingLinkPreviews(linkPreviews, in: $0)
                    }
                }
                Self.replaceLinkPreviews(linkPreviews, noteID: noteID, in: &self.threadReplies)
                self.linkPreviewRefreshGenerations[noteID] = nil
            }
            self.refreshSearchIfNeeded()
        }
    }

    private func startAttachmentImport(id: UUID, source: PendingAttachmentSource) {
        guard canMutateLibrary,
              let store = attachmentStore,
              attachmentImportTasks[id] == nil,
              let index = pendingAttachments.firstIndex(where: { $0.id == id }) else {
            return
        }
        pendingAttachments[index].status = .importing
        pendingAttachments[index].progress = 0
        pendingAttachments[index].errorMessage = nil
        pendingAttachments[index].canRetry = false
        pendingAttachments[index].stagedAttachment = nil
        let sortIndex = pendingAttachments[index].stagedAttachment?.sortIndex
            ?? nextPendingAttachmentSortIndex(excluding: id)
        let attemptID = UUID()
        attachmentImportAttempts[id] = attemptID

        let model = self
        attachmentImportTasks[id] = Task.detached(priority: .userInitiated) {
            let reportProgress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    model.updateAttachmentProgress(
                        id: id,
                        attemptID: attemptID,
                        progress: value
                    )
                }
            }
            do {
                let staged: StagedAttachment
                switch source {
                case let .file(url):
                    staged = try store.stageSelectedFile(
                        at: url,
                        id: id,
                        sortIndex: sortIndex,
                        progress: reportProgress
                    )
                case let .clipboard(data, filename, mediaType):
                    staged = try store.stageClipboardImage(
                        data: data,
                        originalFilename: filename,
                        mediaType: mediaType,
                        id: id,
                        sortIndex: sortIndex,
                        progress: reportProgress
                    )
                }
                try Task.checkCancellation()
                await model.finishAttachmentImport(
                    id: id,
                    attemptID: attemptID,
                    staged: staged
                )
            } catch is CancellationError {
                store.discardStagingFiles(id: id)
                await model.finishAttachmentImportFailure(
                    id: id,
                    attemptID: attemptID,
                    message: "Import canceled. Retry or remove this attachment."
                )
            } catch {
                await model.finishAttachmentImportFailure(
                    id: id,
                    attemptID: attemptID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func updateAttachmentProgress(id: UUID, attemptID: UUID, progress: Double) {
        guard attachmentImportAttempts[id] == attemptID,
              let index = pendingAttachments.firstIndex(where: { $0.id == id }),
              pendingAttachments[index].status == .importing else {
            return
        }
        pendingAttachments[index].progress = min(max(progress, 0), 1)
    }

    private func finishAttachmentImport(
        id: UUID,
        attemptID: UUID,
        staged: StagedAttachment
    ) {
        guard attachmentImportAttempts[id] == attemptID else {
            Task.detached(priority: .utility) { [attachmentStore] in
                try? attachmentStore?.discardStagedAttachment(staged)
            }
            return
        }
        attachmentImportTasks[id] = nil
        attachmentImportAttempts[id] = nil
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else {
            Task.detached(priority: .utility) { [attachmentStore] in
                try? attachmentStore?.discardStagedAttachment(staged)
            }
            return
        }
        pendingAttachments[index].status = .ready
        pendingAttachments[index].progress = 1
        pendingAttachments[index].errorMessage = nil
        pendingAttachments[index].canRetry = false
        pendingAttachments[index].stagedAttachment = staged
        pendingAttachmentSources[id] = nil
    }

    private func finishAttachmentImportFailure(id: UUID, attemptID: UUID, message: String) {
        guard attachmentImportAttempts[id] == attemptID else { return }
        attachmentImportTasks[id] = nil
        attachmentImportAttempts[id] = nil
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingAttachments[index].status = .failed
        pendingAttachments[index].progress = 0
        pendingAttachments[index].errorMessage = message
        pendingAttachments[index].canRetry = pendingAttachmentSources[id] != nil
        pendingAttachments[index].stagedAttachment = nil
    }

    private func nextPendingAttachmentSortIndex(excluding id: UUID) -> Int {
        let largest = pendingAttachments
            .filter { $0.id != id }
            .compactMap(\.stagedAttachment?.sortIndex)
            .max() ?? -1
        let position = pendingAttachments.firstIndex(where: { $0.id == id }) ?? 0
        return max(largest + 1, position)
    }

    private func restorePendingAttachments(_ recovered: [RecoveredStagedAttachment]) {
        pendingAttachments = recovered.map { recoveredAttachment in
            let attachment = recoveredAttachment.attachment
            return PendingAttachment(
                id: attachment.id,
                displayName: attachment.originalFilename,
                status: recoveredAttachment.isAvailable ? .ready : .failed,
                progress: recoveredAttachment.isAvailable ? 1 : 0,
                errorMessage: recoveredAttachment.isAvailable
                    ? nil
                    : "The completed staging copy is missing. Remove this item and choose the source again.",
                canRetry: false,
                stagedAttachment: recoveredAttachment.isAvailable ? attachment : attachment
            )
        }
    }

    private func presentMaintenanceReport(_ report: AttachmentMaintenanceReport) {
        if report.hasIssues {
            var details: [String] = []
            if !report.missingManagedOriginalFilenames.isEmpty {
                details.append(
                    "Missing managed originals: \(report.missingManagedOriginalFilenames.joined(separator: ", "))."
                )
            }
            if !report.missingStagedAttachmentFilenames.isEmpty {
                details.append(
                    "Missing recoverable staging copies: \(report.missingStagedAttachmentFilenames.joined(separator: ", "))."
                )
            }
            if report.missingThumbnailCount > 0 {
                details.append("\(report.missingThumbnailCount) thumbnail files are missing.")
            }
            presentError(
                "Attachment maintenance found missing files. Metadata and notes were preserved; affected actions remain recoverable. \(details.joined(separator: " "))"
            )
        } else if report.hasCleanup {
            presentNotice(
                "Attachment maintenance removed \(report.removedAbandonedStagingItems) abandoned staging item(s) and \(report.removedOrphanedManagedItems) unreferenced managed item(s)."
            )
        }
    }

    private var currentSearchRequest: NoteSearchRequest {
        NoteSearchRequest(
            text: searchText,
            filters: searchFilters,
            sort: searchSort
        )
    }

    private func scheduleSearch(debounced: Bool = true) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let request = currentSearchRequest
        guard request.hasCriteria, let database else {
            searchResults = []
            searchResultCount = 0
            searchErrorMessage = nil
            isSearching = false
            return
        }

        searchResults = []
        searchResultCount = 0
        isSearching = true
        searchErrorMessage = nil
        searchTask = Task { [weak self] in
            do {
                if debounced {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                try Task.checkCancellation()
                let response = try await Task.detached(priority: .userInitiated) {
                    try database.searchNotes(request)
                }.value
                try Task.checkCancellation()
                guard let self, generation == self.searchGeneration else { return }
                self.searchResults = response.results
                self.searchResultCount = response.totalCount
                self.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.searchGeneration else { return }
                self.searchResults = []
                self.searchResultCount = 0
                self.searchErrorMessage = "Search could not be completed. Change the filters or retry. Details: \(error.localizedDescription)"
                self.isSearching = false
            }
        }
    }

    private func refreshSearchIfNeeded() {
        guard hasSearchCriteria else { return }
        scheduleSearch(debounced: false)
    }

    private func chooseArchiveDirectory(title: String, prompt: String) -> URL? {
        guard canMutateLibrary, !isArchiveOperationRunning else { return nil }
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func beginSupportOperation() async -> Bool {
        guard canRunLibraryHealthCheck else { return false }
        shouldResumeDraftSaveAfterSupportOperation = draftSaveTask != nil
        isLibraryMutationPaused = true
        draftSaveTask?.cancel()
        draftSaveTask = nil
        await linkPreviewCoordinator?.pauseBackgroundWork()
        return true
    }

    private func finishSupportOperation() async {
        await linkPreviewCoordinator?.resumeBackgroundWork()
        isLibraryMutationPaused = false
        if shouldResumeDraftSaveAfterSupportOperation {
            shouldResumeDraftSaveAfterSupportOperation = false
            scheduleDraftSave()
        }
    }

    private func beginArchiveOperation(
        kind: ArchiveOperationKind,
        showsInitialProgress: Bool = true
    ) -> UUID? {
        guard canMutateLibrary, !isArchiveOperationRunning else { return nil }
        let id = UUID()
        archiveOperationID = id
        isArchiveOperationRunning = true
        if showsInitialProgress {
            archiveProgress = ArchiveOperationProgress(
                kind: kind,
                fraction: 0,
                message: "Preparing…"
            )
        }
        return id
    }

    private func updateArchiveProgress(_ progress: ArchiveOperationProgress, id: UUID) {
        guard archiveOperationID == id else { return }
        archiveProgress = progress
    }

    private func finishArchiveOperation(
        id: UUID,
        notice: String? = nil,
        error: String? = nil
    ) {
        guard archiveOperationID == id else { return }
        archiveOperationID = nil
        archiveOperationTask = nil
        isArchiveOperationRunning = false
        archiveProgress = nil
        if let error {
            presentError(error)
        } else if let notice {
            presentNotice(notice)
        }
    }

    private func finishStagedRestore(id: UUID, result: RestoreStagingResult) {
        guard archiveOperationID == id else { return }
        archiveOperationID = nil
        archiveOperationTask = nil
        isArchiveOperationRunning = false
        archiveProgress = nil
        isRestoreReadyForRelaunch = true
        presentNotice(
            "Verified restore staged with \(result.noteCount) note(s). Choose Quit and Restore to atomically switch at next launch, or cancel before quitting."
        )
    }

    private func finishRestoreStagingFailure(
        id: UUID,
        notice: String? = nil,
        error: String? = nil
    ) async {
        guard archiveOperationID == id else { return }
        if archiveService?.hasPendingRestore == true {
            await finishRestoreResolutionRequired(
                id: id,
                message: "Restore validation stopped, but durable restore state remains pending. Both library copies were preserved. Quit and reopen Self DM Notes before making changes."
            )
            return
        }
        archiveOperationID = nil
        archiveOperationTask = nil
        isArchiveOperationRunning = false
        archiveProgress = nil
        await linkPreviewCoordinator?.resumeBackgroundWork()
        isLibraryMutationPaused = false
        if let error {
            presentError(error)
        } else if let notice {
            presentNotice(notice)
        }
    }

    private func finishPendingRestoreCancellation(id: UUID) async {
        guard archiveOperationID == id else { return }
        guard archiveService?.hasPendingRestore != true else {
            await finishRestoreResolutionRequired(
                id: id,
                message: "Restore cancellation did not clear durable pending state. Both library copies were preserved. Quit and reopen Self DM Notes before making changes."
            )
            return
        }
        archiveOperationID = nil
        archiveOperationTask = nil
        isArchiveOperationRunning = false
        archiveProgress = nil
        await linkPreviewCoordinator?.resumeBackgroundWork()
        isLibraryMutationPaused = false
        presentNotice("Pending restore canceled. The active library was not switched.")
    }

    private func finishRestoreResolutionRequired(
        id: UUID,
        message: String = "Restore bookkeeping could not be durably classified. Both the current and staged libraries were preserved. Quit and reopen Self DM Notes now; startup recovery will resolve the durable state before SQLite opens."
    ) async {
        guard archiveOperationID == id else { return }
        archiveOperationID = nil
        archiveOperationTask = nil
        isArchiveOperationRunning = false
        archiveProgress = nil
        isRestoreReadyForRelaunch = false
        await requireRestoreRecoveryRelaunch(message)
    }

    private func requireRestoreRecoveryRelaunch(_ message: String) async {
        isReady = false
        isLibraryMutationPaused = true
        requiresRestoreResolutionRelaunch = true
        restoreRelaunchMessage = message
        restoreStartupStatus = nil
        draftSaveTask?.cancel()
        draftSaveTask = nil
        await linkPreviewCoordinator?.pauseBackgroundWork()
        presentError(message)
    }

    private func startAutomaticBackupIfDue() {
        guard canMutateLibrary,
              !isArchiveOperationRunning,
              let archiveService,
              archiveService.hasAutomaticBackupDirectory,
              let operationID = beginArchiveOperation(
                kind: .backup,
                showsInitialProgress: false
              ) else { return }
        let model = self
        archiveOperationTask = Task.detached(priority: .utility) {
            do {
                let result = try archiveService.createAutomaticBackupIfDue { progress in
                    Task { @MainActor in model.updateArchiveProgress(progress, id: operationID) }
                }
                guard let result else {
                    await model.finishArchiveOperation(id: operationID)
                    return
                }
                var message = "Automatic verified backup created: \(result.packageURL.lastPathComponent)."
                if let warning = result.rotationWarning { message += " \(warning)" }
                await model.finishArchiveOperation(id: operationID, notice: message)
            } catch is CancellationError {
                await model.finishArchiveOperation(id: operationID)
            } catch {
                await model.finishArchiveOperation(
                    id: operationID,
                    error: "Automatic backup did not complete. The last known-good backup was retained. Choose Back Up Now or update the automatic folder in Settings. Details: \(error.localizedDescription)"
                )
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        noticeMessage = nil
    }

    private func presentNotice(_ message: String) {
        noticeMessage = message
        errorMessage = nil
    }

    private func hasVisibleText(_ text: String) -> Bool {
        text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func invalidateTimelinePages() {
        timelineGeneration += 1
    }

    private func invalidateTrashPages() {
        trashGeneration += 1
    }

    private func finishTimelinePageRequest(_ requestID: UUID) {
        guard requestID == timelinePageRequestID else { return }
        timelinePageRequestID = nil
        isLoadingOlder = false
    }

    private func finishTrashPageRequest(_ requestID: UUID) {
        guard requestID == trashPageRequestID else { return }
        trashPageRequestID = nil
        isLoadingTrash = false
    }

    private func refillTimelineIfNeeded() async {
        guard notes.isEmpty, hasOlderNotes else { return }
        await loadOlderNotes(replacingStaleRequest: true)
    }

    private func refillTrashIfNeeded() async {
        guard trashNotes.isEmpty, hasOlderTrash else { return }
        await loadOlderTrash(replacingStaleRequest: true)
    }

    private static func replaceNote(_ note: Note, in notes: inout [Note]) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
    }

    private static func replaceLinkPreviews(
        _ linkPreviews: [LinkPreview],
        noteID: UUID,
        in notes: inout [Note]
    ) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let note = notes[index]
        notes[index] = Note(
            id: note.id,
            body: note.body,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt,
            sortKey: note.sortKey,
            threadRootID: note.threadRootID,
            replyCount: note.replyCount,
            attachments: note.attachments,
            linkPreviews: linkPreviews
        )
    }

    private static func replacingLinkPreviews(
        _ linkPreviews: [LinkPreview],
        in note: Note
    ) -> Note {
        Note(
            id: note.id,
            body: note.body,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt,
            sortKey: note.sortKey,
            threadRootID: note.threadRootID,
            replyCount: note.replyCount,
            attachments: note.attachments,
            linkPreviews: linkPreviews
        )
    }

    private static func insertInOrder(_ note: Note, into notes: inout [Note]) {
        guard !notes.contains(where: { $0.id == note.id }) else { return }
        let insertionIndex = notes.firstIndex { $0.sortKey > note.sortKey } ?? notes.endIndex
        notes.insert(note, at: insertionIndex)
    }

    private static func belongsInLoadedWindow(
        _ note: Note,
        hasOlder: Bool,
        pagingCursor: Int64?
    ) -> Bool {
        guard hasOlder else { return true }
        guard let pagingCursor else { return false }
        return note.sortKey >= pagingCursor
    }
}

enum TimelineSupportError: LocalizedError {
    case operationUnavailable

    var errorDescription: String? {
        "Finish or cancel the current library operation, then try the support action again."
    }
}

private enum PendingAttachmentSource: Sendable {
    case file(URL)
    case clipboard(data: Data, filename: String, mediaType: String)
}

private struct TimelineInitialLoadResult: Sendable {
    let page: NotePage
    let draft: Draft?
    let recoveredAttachments: [RecoveredStagedAttachment]
    let maintenanceReport: AttachmentMaintenanceReport?
    let maintenanceError: String?
}
