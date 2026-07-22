import AppKit
import ImageIO
import SwiftUI

struct NoteLinkPreviewsView: View {
    let previews: [LinkPreview]
    @ObservedObject var model: TimelineViewModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(previews.filter { $0.status != .removed }) { preview in
                LinkPreviewCard(preview: preview, model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link previews")
    }
}

private struct LinkPreviewCard: View {
    let preview: LinkPreview
    @ObservedObject var model: TimelineViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 88, height: 88)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                stateContent
                Spacer(minLength: 2)
                HStack(spacing: 8) {
                    Button("Open", systemImage: "arrow.up.forward.app") {
                        model.openLinkPreview(preview)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens the original URL in the default browser.")

                    Menu("Preview actions", systemImage: "ellipsis") {
                        Button("Copy URL", systemImage: "doc.on.doc") {
                            model.copyLinkPreview(preview)
                        }
                        if preview.status == .failed {
                            Button("Retry Preview", systemImage: "arrow.clockwise") {
                                Task { await model.retryLinkPreview(preview) }
                            }
                            .disabled(
                                !model.canMutateLibrary || !model.automaticLinkPreviewsEnabled
                            )
                        }
                        Divider()
                        Button("Remove Preview", systemImage: "xmark", role: .destructive) {
                            Task { await model.removeLinkPreview(preview) }
                        }
                        .disabled(!model.canMutateLibrary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("link-preview-actions")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-preview-card")
        .accessibilityLabel("Link preview card")
        .accessibilityValue(accessibilitySummary)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = model.linkPreviewImageURL(for: preview) {
            LinkPreviewThumbnail(url: url)
        } else {
            Image(systemName: stateIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch preview.status {
        case .pending:
            HStack(spacing: 8) {
                if model.automaticLinkPreviewsEnabled {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "pause.circle")
                        .accessibilityHidden(true)
                }
                Text(model.automaticLinkPreviewsEnabled
                    ? "Fetching link preview…"
                    : "Preview waiting — automatic fetching is off")
                    .font(.callout.weight(.semibold))
            }
            originalURLLink
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        case .ready:
            Text(preview.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(preview.siteName ?? preview.originalURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            originalURLLink
                .font(.caption2)
                .lineLimit(1)
            if let summary = preview.summary {
                Text(summary)
                    .font(.caption)
                    .lineLimit(2)
            }
        case .failed:
            Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text(preview.failureReason ?? "The linked website could not be previewed safely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            originalURLLink
                .font(.caption2)
                .lineLimit(1)
        case .removed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var originalURLLink: some View {
        if let url = URL(string: preview.originalURL) {
            Link(preview.originalURL, destination: url)
                .foregroundStyle(Color(nsColor: .linkColor))
                .accessibilityHint("Opens in the default browser.")
        } else {
            Text(preview.originalURL)
                .foregroundStyle(.secondary)
        }
    }

    private var stateIcon: String {
        switch preview.status {
        case .pending: "clock"
        case .ready: "link"
        case .failed: "exclamationmark.triangle"
        case .removed: "xmark"
        }
    }

    private var accessibilitySummary: String {
        switch preview.status {
        case .pending:
            "Pending preview for \(preview.originalURL). \(model.automaticLinkPreviewsEnabled ? "Fetching." : "Automatic fetching is off.")"
        case .ready:
            "\(preview.displayTitle). \(preview.siteName ?? "Site unavailable"). Destination: \(preview.originalURL)."
        case .failed:
            "Preview unavailable for \(preview.originalURL). \(preview.failureReason ?? "The website could not be previewed safely.")"
        case .removed:
            "Removed preview for \(preview.originalURL)."
        }
    }

}

private struct LinkPreviewThumbnail: View {
    let url: URL

    @State private var image: LoadedLinkPreviewImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(image.value, scale: 1, label: Text("Link preview image"))
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else if didFail {
                Image(systemName: "link")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = nil
            didFail = false
            let result = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                ),
                let value = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                ) else {
                    return LoadedLinkPreviewImage?.none
                }
                return LoadedLinkPreviewImage(value: value)
            }.value
            guard !Task.isCancelled else { return }
            image = result
            didFail = result == nil
        }
    }
}

private struct LoadedLinkPreviewImage: @unchecked Sendable {
    let value: CGImage
}

struct LinkPreviewSettingsView: View {
    @ObservedObject var model: TimelineViewModel
    let supportService: SupportService?

    @Environment(\.dismiss) private var dismiss
    @State private var showRestoreConfirmation = false
    @State private var showAboutSupport = false
    @State private var showKeyboardShortcuts = false
    @State private var showDataGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Link previews") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(
                                "Automatically fetch link previews",
                                isOn: Binding(
                                    get: { model.automaticLinkPreviewsEnabled },
                                    set: { enabled in
                                        Task { await model.setAutomaticLinkPreviewsEnabled(enabled) }
                                    }
                                )
                            )
                            .disabled(
                                !model.canMutateLibrary || model.isUpdatingLinkPreviewSetting
                            )
                            .accessibilityIdentifier("automatic-link-previews-toggle")

                            if model.linkPreviewOffSettingNeedsRetry {
                                Button("Retry Saving Off Setting", systemImage: "arrow.clockwise") {
                                    Task { await model.setAutomaticLinkPreviewsEnabled(false) }
                                }
                                .disabled(
                                    !model.canMutateLibrary || model.isUpdatingLinkPreviewSetting
                                )
                                .accessibilityHint(
                                    "Retries saving the disabled preference. Network fetching is already off for this session."
                                )
                            }

                            Text(
                                "Generating a preview contacts the linked website and can reveal your IP address. "
                                    + "Self DM Notes sends no browser cookies or saved credentials, does not run JavaScript, "
                                    + "and blocks local, private, link-local, multicast, and reserved destinations."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            Text(
                                "Automatic fetching starts off. When it is off, links remain searchable and readable, "
                                    + "but Self DM Notes makes no preview DNS or web requests. Successful previews are reused "
                                    + "for seven days before a background refresh."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Backup and recovery") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Backups use a consistent SQLite snapshot, include referenced managed files, and are not successful until inventory checksums and SQLite integrity pass."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            HStack {
                                Button("Back Up Now…", systemImage: "externaldrive.badge.plus") {
                                    model.createManualBackup()
                                }
                                .keyboardShortcut("b", modifiers: [.command, .shift])
                                .accessibilityIdentifier("backup-now-button")
                                .accessibilityHint("Chooses a folder and creates a new verified backup without overwriting an existing package.")

                                Button("Choose Automatic Folder…", systemImage: "folder.badge.plus") {
                                    model.chooseAutomaticBackupDirectory()
                                }
                                .accessibilityIdentifier("automatic-backup-folder-button")
                            }
                            .disabled(
                                !model.canMutateLibrary
                                    || model.isArchiveOperationRunning
                                    || model.isRestoreReadyForRelaunch
                                    || model.requiresRestoreResolutionRelaunch
                            )

                            if let directoryName = model.automaticBackupDirectoryName {
                                HStack {
                                    Text("Automatic daily backup folder: \(directoryName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Disable Automatic Backups", role: .destructive) {
                                        model.removeAutomaticBackupDirectory()
                                    }
                                    .disabled(
                                        !model.canMutateLibrary
                                            || model.isArchiveOperationRunning
                                            || model.requiresRestoreResolutionRelaunch
                                    )
                                }
                                .accessibilityElement(children: .contain)
                            } else {
                                Text("Automatic backups are off until you choose a folder.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(
                                "Automatic backups run at most once every 24 hours and retain the seven newest verified automatic packages. Rotation runs only after a new verified backup exists; manual, invalid, and partial packages are never rotated."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Divider()

                            Button("Restore Verified Backup…", systemImage: "arrow.counterclockwise") {
                                showRestoreConfirmation = true
                            }
                            .disabled(
                                !model.canMutateLibrary
                                    || model.isArchiveOperationRunning
                                    || model.isRestoreReadyForRelaunch
                                    || model.requiresRestoreResolutionRelaunch
                            )
                            .accessibilityIdentifier("restore-backup-button")
                            .accessibilityHint("Confirms the replacement, then validates and stages a backup before any library switch.")

                            if model.isRestoreReadyForRelaunch {
                                HStack {
                                    Button("Quit and Restore", action: model.quitAndApplyRestore)
                                        .buttonStyle(.borderedProminent)
                                    Button("Cancel Pending Restore", action: model.cancelPendingRestore)
                                }
                            } else if model.requiresRestoreResolutionRelaunch {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Both library copies were preserved, but recovery bookkeeping needs to be resolved before more archive or note changes.")
                                        .font(.callout)
                                        .foregroundStyle(.red)
                                    Button("Quit and Reopen", action: model.quitAndResolveRestore)
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Portable export") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Export creates app-independent versioned JSON, chronological Markdown, and uniquely named original attachments with relative links. It includes active and trashed note state plus link-preview metadata."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Button("Export JSON and Markdown…", systemImage: "square.and.arrow.up") {
                                model.exportPortableArchive()
                            }
                            .keyboardShortcut("e", modifiers: [.command, .shift])
                            .disabled(
                                !model.canMutateLibrary
                                    || model.isArchiveOperationRunning
                                    || model.isRestoreReadyForRelaunch
                                    || model.requiresRestoreResolutionRelaunch
                            )
                            .accessibilityIdentifier("portable-export-button")
                            .accessibilityHint("Chooses a folder and creates a verified portable export without overwriting existing files.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("About and help") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Review local storage, automatic-backup status, library health, privacy, and redacted support export.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                Button("About, Health, and Support…", systemImage: "info.circle") {
                                    showAboutSupport = true
                                }
                                Button("Keyboard Shortcuts", systemImage: "keyboard") {
                                    showKeyboardShortcuts = true
                                }
                                Button("Data and Privacy Guide", systemImage: "hand.raised") {
                                    showDataGuide = true
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let progress = model.archiveProgress {
                        GroupBox(progress.kind.title) {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: progress.fraction) {
                                    Text(progress.message)
                                }
                                .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
                                Button("Cancel at Safe Boundary", action: model.cancelArchiveOperation)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("archive-settings-progress")
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 660, minHeight: 520, idealHeight: 680)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showAboutSupport) {
            AboutSupportView(
                supportService: supportService,
                model: model
            )
        }
        .sheet(isPresented: $showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .sheet(isPresented: $showDataGuide) {
            DataPrivacyGuideView(isFirstRun: false, completion: {})
        }
        .confirmationDialog(
            "Replace the current library from a backup?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Choose and Validate Backup", role: .destructive) {
                model.chooseAndStageRestore()
            }
            .disabled(
                !model.canMutateLibrary
                    || model.isArchiveOperationRunning
                    || model.isRestoreReadyForRelaunch
                    || model.requiresRestoreResolutionRelaunch
            )
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                "The selected backup will be copied into protected staging and fully validated first. The current library is not switched until you quit and relaunch, and a rollback copy is retained until restored startup succeeds. Notes newer than the backup will not appear in the restored library."
            )
        }
    }
}
