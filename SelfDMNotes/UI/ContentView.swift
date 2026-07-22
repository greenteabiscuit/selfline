import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private static let newestAnchor = "newest-note-anchor"

    private enum HeaderFocus: Hashable {
        case search
        case settings
        case trash
    }

    let launchStatus: AppLaunchStatus
    let startupRecoveryMessage: String?
    let supportService: SupportService?

    @StateObject private var model: TimelineViewModel
    @AppStorage("SelfDMNotesHasCompletedOnboardingV1") private var hasCompletedOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var headerFocus: HeaderFocus?
    @FocusState private var focusedTimelineNoteID: UUID?
    @AccessibilityFocusState private var accessibilityFocusedNoteID: UUID?
    @State private var composerFocusGeneration = 0
    @State private var searchFocusGeneration = 0
    @State private var isSearchPresented = false
    @State private var didInitialScroll = false
    @State private var isNearBottom = true
    @State private var showNewestAction = false
    @State private var timelineScrollPosition: UUID?
    @State private var showTrash = false
    @State private var showDiscardConfirmation = false
    @State private var editingNote: Note?
    @State private var isAttachmentPickerPresented = false
    @State private var isAttachmentDropTargeted = false
    @State private var showLinkPreviewSettings = false
    @State private var showAboutSupport = false
    @State private var showKeyboardShortcuts = false
    @State private var showOnboarding = false
    @State private var editingReturnNoteID: UUID?
    @State private var replySession: ReplyDraftSession?
    @State private var isReplyAttachmentPickerPresented = false
    @State private var replyAttachmentPickerOwner: ReplySessionIdentity?
    @State private var isReplyAttachmentDropTargeted = false
    @State private var threadSearchTargetID: UUID?
    @State private var searchNavigationID: UUID?

    init(
        launchStatus: AppLaunchStatus,
        database: AppDatabase?,
        attachmentStore: AttachmentStore? = nil,
        linkPreviewCoordinator: LinkPreviewCoordinator? = nil,
        archiveService: ArchiveService? = nil,
        supportService: SupportService? = nil,
        startupRecoveryMessage: String? = nil
    ) {
        self.launchStatus = launchStatus
        self.startupRecoveryMessage = startupRecoveryMessage
        self.supportService = supportService
        _model = StateObject(
            wrappedValue: TimelineViewModel(
                database: database,
                attachmentStore: attachmentStore,
                linkPreviewCoordinator: linkPreviewCoordinator,
                archiveService: archiveService,
                supportService: supportService,
                startupRecoveryMessage: startupRecoveryMessage
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                statusArea(proxy: proxy)
                if isSearchPresented {
                    SearchWorkspace(
                        model: model,
                        focusGeneration: searchFocusGeneration,
                        selectResult: { selectSearchResult($0, proxy: proxy) },
                        exitSearch: exitSearch
                    )
                } else {
                    timeline(proxy: proxy)
                }
                Divider()
                composer(proxy: proxy)
            }
            .task {
                await model.loadInitialContent()
                await Task.yield()
                if let newestID = model.notes.last?.id {
                    proxy.scrollTo(newestID, anchor: .bottom)
                }
                didInitialScroll = true
                if launchStatus.errorMessage == nil, !hasCompletedOnboarding {
                    showOnboarding = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusNoteComposer)) { _ in
                isSearchPresented = false
                composerFocusGeneration += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusNoteSearch)) { _ in
                presentSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .chooseNoteAttachment)) { _ in
                isSearchPresented = false
                isAttachmentPickerPresented = model.canAddAttachments
            }
            .onReceive(NotificationCenter.default.publisher(for: .createLibraryBackup)) { _ in
                model.createManualBackup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportPortableArchive)) { _ in
                model.exportPortableArchive()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAboutAndSupport)) { _ in
                showAboutSupport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
                showKeyboardShortcuts = true
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            ) { _ in
                model.flushDraftSynchronously()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    model.flushDraftSynchronously()
                }
            }
            .onDisappear {
                model.flushDraftSynchronously()
                discardReplyDraft()
            }
            .fileImporter(
                isPresented: $isAttachmentPickerPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    model.addFileAttachments(urls)
                case let .failure(error):
                    model.reportAttachmentCaptureError(
                        "Files were not selected. The composer was not changed. Details: \(error.localizedDescription)"
                    )
                }
                composerFocusGeneration += 1
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingNote, onDismiss: restoreEditedNoteFocus) { note in
            EditNoteView(note: note, model: model)
        }
        .sheet(isPresented: $showTrash, onDismiss: { headerFocus = .trash }) {
            TrashView(model: model)
        }
        .sheet(isPresented: $showLinkPreviewSettings, onDismiss: { headerFocus = .settings }) {
            LinkPreviewSettingsView(model: model, supportService: supportService)
        }
        .sheet(isPresented: $showAboutSupport, onDismiss: restoreComposerFocus) {
            AboutSupportView(
                supportService: supportService,
                model: model
            )
        }
        .sheet(isPresented: $showKeyboardShortcuts, onDismiss: restoreComposerFocus) {
            KeyboardShortcutsView()
        }
        .sheet(isPresented: $showOnboarding, onDismiss: restoreComposerFocus) {
            DataPrivacyGuideView(isFirstRun: true) {
                hasCompletedOnboarding = true
                showOnboarding = false
            }
        }
        .inspector(
            isPresented: Binding(
                get: { model.requestedThreadRootID != nil },
                set: { isPresented in
                    if !isPresented {
                        closeThreadPanel()
                    }
                }
            )
        ) {
            threadPanel
                .inspectorColumnWidth(min: 360, ideal: 440, max: 620)
        }
        .fileImporter(
            isPresented: $isReplyAttachmentPickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            let owner = replyAttachmentPickerOwner
            replyAttachmentPickerOwner = nil
            switch result {
            case let .success(urls):
                if let owner, replySession?.matches(owner) == true {
                    addReplyFiles(urls)
                }
            case let .failure(error):
                if let owner, replySession?.matches(owner) == true {
                    model.reportAttachmentCaptureError(
                        "Files were not selected. The reply composer was not changed. Details: \(error.localizedDescription)"
                    )
                }
            }
            if let owner {
                focusReplyComposer(rootID: owner.rootID, token: owner.token)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Self DM Notes")
                    .font(.headline)
                Text("Private, local timeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Search", systemImage: "magnifyingglass") {
                presentSearch()
            }
            .focused($headerFocus, equals: .search)
            .accessibilityIdentifier("search-button")
            .accessibilityHint("Opens note search. Command F also opens and focuses search.")
            .disabled(launchStatus.errorMessage != nil)
            Button("Settings", systemImage: "gearshape") {
                showLinkPreviewSettings = true
            }
            .focused($headerFocus, equals: .settings)
            .accessibilityIdentifier("settings-button")
            .accessibilityHint("Opens link-preview, backup, restore, and portable export settings.")
            .disabled(launchStatus.errorMessage != nil || !model.isReady)
            Button("Trash", systemImage: "trash") {
                showTrash = true
            }
            .focused($headerFocus, equals: .trash)
            .accessibilityIdentifier("trash-button")
            .accessibilityHint("Shows deleted notes that can be restored or permanently deleted.")
            .disabled(launchStatus.errorMessage != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusArea(proxy: ScrollViewProxy) -> some View {
        if model.requiresRestoreResolutionRelaunch {
            StatusBanner(
                title: "Restore recovery needs relaunch",
                message: model.restoreRelaunchMessage
                    ?? "Restore recovery must resume before more library changes. Quit and reopen now; recovery runs before SQLite opens.",
                isError: true,
                identifier: "restore-resolution-required",
                actionTitle: "Quit and Reopen",
                action: model.quitAndResolveRestore
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if model.isRestoreReadyForRelaunch {
            StatusBanner(
                title: "Verified restore ready",
                message: "The active library has not been switched. Quit and Restore applies it at next launch; Cancel Pending Restore keeps the current library.",
                isError: false,
                identifier: "restore-ready",
                actionTitle: "Quit and Restore",
                action: model.quitAndApplyRestore,
                secondaryActionTitle: "Cancel Pending Restore",
                secondaryAction: model.cancelPendingRestore
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if let progress = model.archiveProgress {
            StatusBanner(
                title: progress.kind.title,
                message: "\(progress.message) \(Int((progress.fraction * 100).rounded())) percent.",
                isError: false,
                identifier: "archive-progress",
                actionTitle: "Cancel",
                action: model.cancelArchiveOperation,
                announcesChanges: false
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if let restoreStartupStatus = model.restoreStartupStatus {
            StatusBanner(
                title: "Restore recovery in progress",
                message: restoreStartupStatus + " Library changes remain paused.",
                isError: false,
                identifier: "restore-startup-progress",
                announcesChanges: false
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if let startupError = launchStatus.errorMessage {
            StatusBanner(
                title: "Local archive unavailable",
                message: startupError,
                isError: true,
                identifier: "startup-error"
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if let errorMessage = model.errorMessage {
            StatusBanner(
                title: "Action not completed",
                message: errorMessage,
                isError: true,
                identifier: "recoverable-error",
                actionTitle: model.canRetryInitialLoad ? "Retry Load" : nil,
                action: { retryInitialLoad(proxy: proxy) },
                dismiss: { model.dismissError() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if let noticeMessage = model.noticeMessage {
            StatusBanner(
                title: "Done",
                message: noticeMessage,
                isError: false,
                identifier: "status-notice",
                dismiss: model.dismissNotice
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func timeline(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.isLoading {
                    ProgressView("Loading notes…")
                        .frame(maxWidth: .infinity)
                        .padding(32)
                        .accessibilityIdentifier("timeline-loading")
                } else if model.notes.isEmpty {
                    emptyTimeline(proxy: proxy)
                } else {
                    if model.hasOlderNotes {
                        Button {
                            loadOlderNotes()
                        } label: {
                            if model.isLoadingOlder {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Load older notes", systemImage: "arrow.up")
                            }
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .disabled(model.isLoadingOlder)
                        .accessibilityIdentifier("load-older-notes")
                        .accessibilityHint("Loads the previous bounded page.")
                        .onAppear {
                            if didInitialScroll {
                                loadOlderNotes()
                            }
                        }
                    }

                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.notes) { note in
                            VStack(alignment: .leading, spacing: 12) {
                                if dateSeparatorIDs.contains(note.id) {
                                    DateSeparator(date: note.createdAt)
                                }
                                if model.searchTargetNoteID == note.id {
                                    Label("Selected search result", systemImage: "scope")
                                        .font(.caption.weight(.semibold))
                                        .accessibilityIdentifier("selected-search-result")
                                }
                                NoteRow(
                                    note: note,
                                    model: model,
                                    copy: { model.copyNote(note) },
                                    edit: {
                                        editingReturnNoteID = note.id
                                        editingNote = note
                                    },
                                    moveToTrash: {
                                        Task { await model.moveNoteToTrash(note) }
                                    },
                                    openThread: {
                                        presentThread(rootID: note.id)
                                    }
                                )
                            }
                            .id(note.id)
                            .focusable()
                            .focused($focusedTimelineNoteID, equals: note.id)
                            .accessibilityFocused($accessibilityFocusedNoteID, equals: note.id)
                        }
                    }
                    .scrollTargetLayout()
                }

                Color.clear
                    .frame(height: 1)
                    .id(Self.newestAnchor)
                    .onAppear {
                        isNearBottom = true
                        if !model.isShowingTimelineContext {
                            showNewestAction = false
                        }
                    }
                    .onDisappear {
                        isNearBottom = false
                    }
            }
            .padding(16)
        }
        .scrollPosition(id: $timelineScrollPosition)
        .defaultScrollAnchor(.bottom)
        .overlay(alignment: .bottomTrailing) {
            if (showNewestAction || model.isShowingTimelineContext), !model.notes.isEmpty {
                Button("Newest note", systemImage: "arrow.down") {
                    scrollToNewest(proxy: proxy)
                }
                .buttonStyle(.borderedProminent)
                .padding(16)
                .accessibilityIdentifier("newest-note-button")
                .accessibilityHint("Moves to the newest note in the timeline.")
            }
        }
        .accessibilityIdentifier("notes-timeline")
        .accessibilityLabel("Notes timeline")
        .accessibilityValue(model.notes.isEmpty ? "No notes" : "\(model.notes.count) loaded notes")
    }

    private func emptyTimeline(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No notes yet")
                .font(.title2.weight(.semibold))
            Text("Write a private note below and send it to start your timeline.")
                .foregroundStyle(.secondary)
            if model.canRetryInitialLoad {
                Button("Retry Load", systemImage: "arrow.clockwise") {
                    retryInitialLoad(proxy: proxy)
                }
                .accessibilityHint("Attempts to load the local timeline and recoverable draft again.")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .contain)
    }

    private func retryInitialLoad(proxy: ScrollViewProxy) {
        Task {
            await model.retryInitialLoad()
            await Task.yield()
            if let newestID = model.notes.last?.id {
                proxy.scrollTo(newestID, anchor: .bottom)
            }
        }
    }

    private func composer(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PendingAttachmentsView(model: model)

            HStack(alignment: .bottom, spacing: 10) {
                Menu("Add attachment", systemImage: "paperclip") {
                    Button("Choose Files…", systemImage: "folder") {
                        isAttachmentPickerPresented = true
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("Paste Clipboard Image", systemImage: "photo.on.rectangle") {
                        pasteClipboardImage()
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.canAddAttachments)
                .accessibilityIdentifier("add-attachment-button")
                .accessibilityLabel("Add attachment")
                .accessibilityHint(
                    "Choose files or paste a clipboard image. Command Shift A opens the file picker."
                )

                ComposerTextView(
                    text: Binding(
                        get: { model.draftText },
                        set: { newValue in model.setDraft(newValue) }
                    ),
                    focusGeneration: composerFocusGeneration,
                    isEditable: launchStatus.errorMessage == nil
                        && model.canMutateLibrary
                        && !model.isSending
                        && !model.isDiscardingDraft,
                    onSend: { sendDraft(proxy: proxy) },
                    onPasteImage: { data, filename, mediaType in
                        model.addClipboardImage(
                            data: data,
                            filename: filename,
                            mediaType: mediaType
                        )
                    }
                )
                .frame(minHeight: 48, maxHeight: 120)

                if model.hasDraftContent {
                    Button("Discard", systemImage: "xmark") {
                        showDiscardConfirmation = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Discard draft")
                    .accessibilityHint("Asks for confirmation before clearing the composer.")
                    .disabled(
                        !model.canMutateLibrary || model.isSending || model.isDiscardingDraft
                    )
                }

                Button("Send", systemImage: "arrow.up") {
                    sendDraft(proxy: proxy)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityIdentifier("send-button")
                .accessibilityLabel("Send note")
                .accessibilityHint("Saves the note. Command Return also sends; Return inserts a new line.")
            }

            Text("Command-Return sends  •  Return adds a line  •  Command-Shift-A attaches files  •  Drop files or paste an image")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Keyboard help: Command Return sends. Return adds a line. Command Shift A attaches files. Files can be dropped and clipboard images can be pasted."
                )
        }
        .padding(16)
        .background(.bar)
        .overlay {
            if isAttachmentDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [7]))
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAddAttachments else { return false }
            model.addFileAttachments(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted in
            isAttachmentDropTargeted = isTargeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note composer")
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                Task { await model.discardDraft() }
            }
            .disabled(!model.canMutateLibrary || model.isSending || model.isDiscardingDraft)
            Button("Keep Draft", role: .cancel) { }
        } message: {
            Text("This removes the recoverable text draft and all pending attachments. It cannot be undone.")
        }
    }

    private func pasteClipboardImage() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
            model.addClipboardImage(
                data: data,
                filename: "Pasted Image.png",
                mediaType: UTType.png.identifier
            )
        } else if let data = pasteboard.data(forType: .tiff) {
            model.addClipboardImage(
                data: data,
                filename: "Pasted Image.tiff",
                mediaType: UTType.tiff.identifier
            )
        } else {
            model.reportAttachmentCaptureError(
                "The clipboard does not contain an image. Copy an image, then choose Paste Clipboard Image again."
            )
        }
    }

    private var threadPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thread")
                        .font(.headline)
                    if let root = model.threadRoot {
                        Text(
                            root.replyCount == 1
                                ? "1 reply"
                                : "\(root.replyCount) replies"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Close Thread", systemImage: "xmark") {
                    closeThreadPanel()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Close thread panel")
            }
            .padding(16)

            Divider()

            if model.isLoadingThread, model.threadRoot == nil {
                ProgressView("Loading thread…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root = model.threadRoot {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ThreadPanelNoteRow(
                                note: root,
                                heading: "Root note",
                                isSearchTarget: false,
                                model: model,
                                copy: { model.copyNote(root) },
                                edit: {
                                    editingReturnNoteID = root.id
                                    editingNote = root
                                },
                                moveToTrash: {
                                    Task { await model.moveNoteToTrash(root) }
                                }
                            )

                            if !model.threadReplies.isEmpty {
                                Divider()
                                Text("Replies")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(model.threadReplies) { reply in
                                ThreadPanelNoteRow(
                                    note: reply,
                                    heading: "Reply",
                                    isSearchTarget: threadSearchTargetID == reply.id,
                                    model: model,
                                    copy: { model.copyNote(reply) },
                                    edit: {
                                        editingReturnNoteID = reply.id
                                        editingNote = reply
                                    },
                                    moveToTrash: {
                                        Task { await model.moveNoteToTrash(reply) }
                                    }
                                )
                                .id(reply.id)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear {
                        if let threadSearchTargetID {
                            proxy.scrollTo(threadSearchTargetID, anchor: .center)
                        }
                    }
                    .onChange(of: threadSearchTargetID) { _, target in
                        if let target {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }

                Divider()
                replyComposer(root: root)
            } else {
                ContentUnavailableView(
                    "Thread unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("Close the panel and open the thread again.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-panel")
        .accessibilityLabel("Thread panel")
        .onDisappear {
            discardReplyDraft()
        }
    }

    private func replyComposer(root: Note) -> some View {
        let session = replySession?.rootID == root.id ? replySession : nil
        let attachments = session?.attachments ?? []
        let isSending = session?.sendOperationID != nil
        let isComposerReady = session != nil && model.isReplyComposerReady

        return VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reply attachments")
                        .font(.caption.weight(.semibold))
                    ForEach(attachments) { attachment in
                        ReplyPendingAttachmentRow(
                            attachment: attachment,
                            canRemove: model.canMutateLibrary && !isSending,
                            remove: { removeReplyAttachment(id: attachment.id) }
                        )
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu("Add reply attachment", systemImage: "paperclip") {
                    Button("Choose Files…", systemImage: "folder") {
                        replyAttachmentPickerOwner = session?.identity
                        isReplyAttachmentPickerPresented = true
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("Paste Clipboard Image", systemImage: "photo.on.rectangle") {
                        pasteReplyClipboardImage()
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.canAddAttachments || !isComposerReady || isSending)
                .accessibilityLabel("Add reply attachment")

                ComposerTextView(
                    text: replyDraftBinding(rootID: root.id),
                    focusGeneration: session?.focusGeneration ?? 0,
                    isEditable: model.canMutateLibrary
                        && isComposerReady
                        && !isSending,
                    onSend: { sendReply(to: root) },
                    onPasteImage: { data, filename, mediaType in
                        addReplyAttachment(
                            source: .clipboard(
                                data: data,
                                filename: filename,
                                mediaType: mediaType
                            )
                        )
                    },
                    accessibilityIdentifier: "reply-composer-field",
                    accessibilityLabel: "Write a reply",
                    accessibilityHelp: "Command Return sends the reply. Return inserts a new line. A greater-than sign at the start of a line previews a quote block. Single and triple backticks preview code formatting. Pasting a clipboard image adds it to this reply."
                )
                .frame(minHeight: 48, maxHeight: 110)

                Button("Send Reply", systemImage: "arrow.up") {
                    sendReply(to: root)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(!canSendReply(to: root.id))
                .accessibilityIdentifier("send-reply-button")
                .accessibilityLabel("Send reply")
                .accessibilityHint("Command Return also sends; Return inserts a new line.")
            }
        }
        .padding(12)
        .background(.bar)
        .overlay {
            if isReplyAttachmentDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [7]))
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAddAttachments,
                  model.isReplyComposerReady,
                  replySession?.rootID == root.id,
                  replySession?.sendOperationID == nil else { return false }
            addReplyFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isReplyAttachmentDropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply-composer")
        .accessibilityLabel("Reply composer")
    }

    private func canSendReply(to rootID: UUID) -> Bool {
        guard let session = replySession,
              session.rootID == rootID,
              model.threadRoot?.id == rootID,
              model.requestedThreadRootID == rootID,
              model.isReplyComposerReady,
              model.canMutateLibrary,
              session.sendOperationID == nil,
              session.attachments.allSatisfy({ $0.status == .ready }) else {
            return false
        }
        return session.text.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        } || !session.attachments.isEmpty
    }

    private func presentThread(rootID: UUID) {
        prepareReplySession(for: rootID)
        let token = replySession?.token
        threadSearchTargetID = nil
        Task {
            if await model.openThread(rootID: rootID),
               model.isReplyComposerReady {
                focusReplyComposer(rootID: rootID, token: token)
            }
        }
    }

    private func closeThreadPanel() {
        discardReplyDraft()
        isReplyAttachmentPickerPresented = false
        replyAttachmentPickerOwner = nil
        threadSearchTargetID = nil
        model.closeThread()
    }

    private func addReplyFiles(_ urls: [URL]) {
        for url in urls {
            addReplyAttachment(source: .file(url))
        }
    }

    private func addReplyAttachment(source: ReplyAttachmentSource) {
        guard model.canAddAttachments,
              model.isReplyComposerReady,
              var session = replySession,
              session.rootID == model.requestedThreadRootID,
              session.sendOperationID == nil else { return }
        let rootID = session.rootID
        let token = session.token
        let id = UUID()
        let sortIndex = (session.attachments.map(\.sortIndex).max() ?? -1) + 1
        session.attachments.append(
            ReplyPendingAttachment(
                id: id,
                displayName: source.displayName,
                sortIndex: sortIndex,
                status: .importing,
                stagedAttachment: nil,
                errorMessage: nil
            )
        )
        replySession = session

        let importTask = Task {
            do {
                let staged: StagedAttachment
                switch source {
                case let .file(url):
                    staged = try await model.stageReplyFile(
                        at: url,
                        id: id,
                        sortIndex: sortIndex
                    )
                case let .clipboard(data, filename, mediaType):
                    staged = try await model.stageReplyClipboardImage(
                        data: data,
                        filename: filename,
                        mediaType: mediaType,
                        id: id,
                        sortIndex: sortIndex
                    )
                }
                guard var current = replySession,
                      current.matches(rootID: rootID, token: token),
                      let index = current.attachments.firstIndex(where: { $0.id == id }) else {
                    model.discardReplyAttachment(staged)
                    return
                }
                current.importTasks[id] = nil
                current.attachments[index].status = .ready
                current.attachments[index].stagedAttachment = staged
                replySession = current
            } catch {
                guard var current = replySession,
                      current.matches(rootID: rootID, token: token),
                      let index = current.attachments.firstIndex(where: { $0.id == id }) else {
                    return
                }
                current.importTasks[id] = nil
                current.attachments[index].status = .failed
                current.attachments[index].errorMessage = error.localizedDescription
                replySession = current
            }
        }
        guard var current = replySession,
              current.matches(rootID: rootID, token: token) else {
            importTask.cancel()
            return
        }
        current.importTasks[id] = importTask
        replySession = current
    }

    private func removeReplyAttachment(id: UUID) {
        guard var session = replySession,
              session.sendOperationID == nil,
              let index = session.attachments.firstIndex(where: { $0.id == id }) else {
            return
        }
        session.importTasks.removeValue(forKey: id)?.cancel()
        let removed = session.attachments.remove(at: index)
        replySession = session
        if let staged = removed.stagedAttachment {
            model.discardReplyAttachment(staged)
        }
    }

    private func pasteReplyClipboardImage() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
            addReplyAttachment(
                source: .clipboard(
                    data: data,
                    filename: "Pasted Image.png",
                    mediaType: UTType.png.identifier
                )
            )
        } else if let data = pasteboard.data(forType: .tiff) {
            addReplyAttachment(
                source: .clipboard(
                    data: data,
                    filename: "Pasted Image.tiff",
                    mediaType: UTType.tiff.identifier
                )
            )
        } else {
            model.reportAttachmentCaptureError(
                "The clipboard does not contain an image. Copy an image, then choose Paste Clipboard Image again."
            )
        }
    }

    private func sendReply(to root: Note) {
        guard canSendReply(to: root.id),
              var session = replySession else { return }
        let token = session.token
        let operationID = UUID()
        let body = session.text
        let pendingAttachments = session.attachments
        let stagedAttachments = pendingAttachments
            .compactMap(\.stagedAttachment)
            .sorted { $0.sortIndex < $1.sortIndex }
        session.text = ""
        session.attachments = []
        session.importTasks = [:]
        session.sendOperationID = operationID
        replySession = session

        Task {
            let reply = await model.sendReply(
                to: root,
                body: body,
                stagedAttachments: stagedAttachments
            )
            guard var current = replySession,
                  current.matches(rootID: root.id, token: token),
                  current.sendOperationID == operationID else {
                if reply == nil {
                    for staged in stagedAttachments {
                        model.discardReplyAttachment(staged)
                    }
                }
                return
            }
            current.sendOperationID = nil
            if reply == nil {
                current.text = body
                current.attachments = pendingAttachments
                replySession = current
                return
            }
            current.focusGeneration += 1
            replySession = current
            threadSearchTargetID = nil
        }
    }

    private func discardReplyDraft() {
        guard let session = replySession else { return }
        for task in session.importTasks.values {
            task.cancel()
        }
        for staged in session.attachments.compactMap(\.stagedAttachment) {
            model.discardReplyAttachment(staged)
        }
        replySession = nil
    }

    private func prepareReplySession(for rootID: UUID) {
        guard replySession?.rootID != rootID else { return }
        discardReplyDraft()
        replySession = ReplyDraftSession(rootID: rootID)
    }

    private func replyDraftBinding(rootID: UUID) -> Binding<String> {
        Binding(
            get: {
                guard replySession?.rootID == rootID else { return "" }
                return replySession?.text ?? ""
            },
            set: { text in
                guard var session = replySession,
                      session.rootID == rootID,
                      model.isReplyComposerReady else { return }
                session.text = text
                replySession = session
            }
        )
    }

    private func focusReplyComposer(rootID: UUID, token: UUID?) {
        guard let token,
              var session = replySession,
              session.matches(rootID: rootID, token: token),
              model.requestedThreadRootID == rootID,
              model.isReplyComposerReady else { return }
        session.focusGeneration += 1
        replySession = session
    }

    private var dateSeparatorIDs: Set<UUID> {
        var result = Set<UUID>()
        var previousDay: Date?
        let calendar = Calendar.autoupdatingCurrent
        for note in model.notes {
            if previousDay.map({ !calendar.isDate($0, inSameDayAs: note.createdAt) }) ?? true {
                result.insert(note.id)
            }
            previousDay = note.createdAt
        }
        return result
    }

    private func loadOlderNotes() {
        guard !model.isLoadingOlder else { return }
        Task {
            await model.loadOlderNotes()
        }
    }

    private func sendDraft(proxy: ScrollViewProxy) {
        guard model.canSend else { return }
        let shouldScroll = isNearBottom || model.notes.isEmpty
        Task {
            guard let note = await model.sendDraft() else { return }
            if shouldScroll {
                if reduceMotion {
                    proxy.scrollTo(note.id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(note.id, anchor: .bottom)
                    }
                }
                showNewestAction = false
            } else {
                showNewestAction = true
            }
        }
    }

    private func presentSearch() {
        isSearchPresented = true
        searchFocusGeneration += 1
    }

    private func exitSearch() {
        isSearchPresented = false
        composerFocusGeneration += 1
    }

    private func selectSearchResult(_ result: NoteSearchResult, proxy: ScrollViewProxy) {
        let navigationID = UUID()
        searchNavigationID = navigationID
        let destinationRootID = result.navigationNoteID
        let initialRequestedRootID = model.requestedThreadRootID
        let previousThreadSearchTargetID = threadSearchTargetID
        let destinationSession: ReplySessionIdentity?

        if result.opensThread, let rootID = result.threadRootID {
            if replySession?.rootID != rootID {
                replyAttachmentPickerOwner = nil
                isReplyAttachmentPickerPresented = false
            }
            prepareReplySession(for: rootID)
            destinationSession = replySession?.identity
            threadSearchTargetID = result.note.id
        } else {
            destinationSession = nil
        }

        if Self.requiresThreadClosure(
            requestedRootID: initialRequestedRootID,
            destinationRootID: destinationRootID,
            destinationOpensThread: destinationSession != nil
        ) {
            closeThreadPanel()
        }

        Task {
            defer {
                if searchNavigationID == navigationID {
                    searchNavigationID = nil
                }
            }
            guard let note = await model.revealSearchResult(result) else {
                guard searchNavigationID == navigationID,
                      let destinationSession,
                      replySession?.matches(destinationSession) == true else { return }
                if initialRequestedRootID == destinationSession.rootID {
                    if threadSearchTargetID == result.note.id {
                        threadSearchTargetID = previousThreadSearchTargetID
                    }
                } else {
                    closeThreadPanel()
                }
                return
            }
            guard searchNavigationID == navigationID else { return }
            isSearchPresented = false
            await Task.yield()
            guard searchNavigationID == navigationID else { return }
            proxy.scrollTo(note.id, anchor: .center)
            focusedTimelineNoteID = note.id
            accessibilityFocusedNoteID = note.id
            showNewestAction = model.isShowingTimelineContext
            if let destinationSession {
                guard replySession?.matches(destinationSession) == true else { return }
                if await model.openThread(rootID: destinationSession.rootID),
                   searchNavigationID == navigationID,
                   replySession?.matches(destinationSession) == true,
                   model.requestedThreadRootID == destinationSession.rootID,
                   threadSearchTargetID == result.note.id {
                    focusReplyComposer(
                        rootID: destinationSession.rootID,
                        token: destinationSession.token
                    )
                }
            } else if Self.requiresThreadClosure(
                requestedRootID: model.requestedThreadRootID,
                destinationRootID: destinationRootID,
                destinationOpensThread: false
            ) {
                closeThreadPanel()
            }
        }
    }

    nonisolated static func requiresThreadClosure(
        requestedRootID: UUID?,
        destinationRootID: UUID,
        destinationOpensThread: Bool
    ) -> Bool {
        guard !destinationOpensThread else { return false }
        return requestedRootID.map { $0 != destinationRootID } ?? false
    }

    private func scrollToNewest(proxy: ScrollViewProxy) {
        if model.isShowingTimelineContext {
            Task {
                guard let newestNote = await model.returnToNewest() else { return }
                await Task.yield()
                scroll(to: newestNote.id, proxy: proxy)
                focusedTimelineNoteID = newestNote.id
                accessibilityFocusedNoteID = newestNote.id
                showNewestAction = false
            }
            return
        }
        scroll(to: Self.newestAnchor, proxy: proxy)
        showNewestAction = false
    }

    private func scroll<ID: Hashable>(to id: ID, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func restoreComposerFocus() {
        composerFocusGeneration += 1
    }

    private func restoreEditedNoteFocus() {
        guard let editingReturnNoteID else {
            restoreComposerFocus()
            return
        }
        if model.threadReplies.contains(where: { $0.id == editingReturnNoteID }),
           let identity = replySession?.identity,
           model.threadRoot?.id == identity.rootID,
           model.isReplyComposerReady {
            self.editingReturnNoteID = nil
            focusReplyComposer(rootID: identity.rootID, token: identity.token)
            return
        }
        guard model.notes.contains(where: { $0.id == editingReturnNoteID }) else {
            self.editingReturnNoteID = nil
            restoreComposerFocus()
            return
        }
        focusedTimelineNoteID = editingReturnNoteID
        accessibilityFocusedNoteID = editingReturnNoteID
        self.editingReturnNoteID = nil
    }
}

private enum ReplyAttachmentSource {
    case file(URL)
    case clipboard(data: Data, filename: String, mediaType: String)

    var displayName: String {
        switch self {
        case let .file(url):
            url.lastPathComponent
        case let .clipboard(_, filename, _):
            filename
        }
    }
}

enum ReplyPendingAttachmentStatus: Equatable {
    case importing
    case ready
    case failed
}

struct ReplyPendingAttachment: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let sortIndex: Int
    var status: ReplyPendingAttachmentStatus
    var stagedAttachment: StagedAttachment?
    var errorMessage: String?
}

struct ReplySessionIdentity: Equatable {
    let rootID: UUID
    let token: UUID
}

struct ReplyDraftSession {
    let rootID: UUID
    let token: UUID
    var text = ""
    var attachments: [ReplyPendingAttachment] = []
    var importTasks: [UUID: Task<Void, Never>] = [:]
    var sendOperationID: UUID?
    var focusGeneration = 0

    init(rootID: UUID, token: UUID = UUID()) {
        self.rootID = rootID
        self.token = token
    }

    var identity: ReplySessionIdentity {
        ReplySessionIdentity(rootID: rootID, token: token)
    }

    func matches(rootID: UUID, token: UUID) -> Bool {
        self.rootID == rootID && self.token == token
    }

    func matches(_ identity: ReplySessionIdentity) -> Bool {
        matches(rootID: identity.rootID, token: identity.token)
    }
}

private struct ReplyPendingAttachmentRow: View {
    let attachment: ReplyPendingAttachment
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Remove", systemImage: "xmark.circle", action: remove)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Remove reply attachment \(attachment.displayName)")
                .disabled(!canRemove)
        }
        .padding(7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.displayName)
        .accessibilityValue(statusDescription)
    }

    private var statusSymbol: String {
        switch attachment.status {
        case .importing: "arrow.down.circle"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch attachment.status {
        case .importing: .secondary
        case .ready: .green
        case .failed: .orange
        }
    }

    private var statusDescription: String {
        switch attachment.status {
        case .importing:
            "Importing…"
        case .ready:
            if let staged = attachment.stagedAttachment {
                "Ready to send • \(ByteCountFormatter.string(fromByteCount: staged.byteSize, countStyle: .file))"
            } else {
                "Ready to send"
            }
        case .failed:
            "Import failed. \(attachment.errorMessage ?? "Remove the item and try again.")"
        }
    }
}

private struct ThreadPanelNoteRow: View {
    let note: Note
    let heading: String
    let isSearchTarget: Bool
    @ObservedObject var model: TimelineViewModel
    let copy: () -> Void
    let edit: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isSearchTarget {
                    Label("Selected search result", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("selected-thread-search-result")
                }
                Spacer()
                Text(note.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Created \(note.createdAt.formatted(date: .complete, time: .complete))"
                    )
            }

            if !note.body.isEmpty {
                LinkedNoteBodyText(
                    text: note.body,
                    accessibilityLabel: note.isReply ? "Reply text" : "Root note text"
                )
            }

            if !note.attachments.isEmpty {
                NoteAttachmentsView(attachments: note.attachments, model: model)
            }

            if note.linkPreviews.contains(where: { $0.status != .removed }) {
                NoteLinkPreviewsView(previews: note.linkPreviews, model: model)
            }

            HStack {
                if let updatedAt = note.updatedAt {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Edited \(updatedAt.formatted(date: .complete, time: .complete))"
                        )
                }
                Spacer()
                Menu("Note actions", systemImage: "ellipsis") {
                    if !note.body.isEmpty {
                        Button("Copy Text", systemImage: "doc.on.doc", action: copy)
                    }
                    Button("Edit", systemImage: "pencil", action: edit)
                        .disabled(!model.canMutateLibrary)
                    Divider()
                    Button(
                        note.isReply ? "Move Reply to Trash" : "Move Thread to Trash",
                        systemImage: "trash",
                        role: .destructive,
                        action: moveToTrash
                    )
                    .disabled(!model.canMutateLibrary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(note.isReply ? "Reply actions" : "Root note actions")
                .accessibilityHint(
                    note.isReply
                        ? "Copy text, edit, or move this reply to Trash."
                        : "Copy text, edit, or move this root and its active replies to Trash."
                )
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}
