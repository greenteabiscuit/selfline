import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AccessibilityAnnouncement {
    static func post(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts = [
        ("Focus note composer", "Command-N"),
        ("Find notes", "Command-F"),
        ("Send note", "Command-Return"),
        ("Insert a line in the composer", "Return"),
        ("Choose attachment", "Command-Shift-A"),
        ("Create manual backup", "Command-Shift-B"),
        ("Export JSON and Markdown", "Command-Shift-E"),
        ("Show this reference", "Command-Shift-?"),
        ("Close the current transient view", "Escape"),
        ("Move forward or backward through controls", "Tab or Shift-Tab")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts")
                        .font(.title2.weight(.semibold))
                    Text("Every shortcut has a visible menu or control alternative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                        HStack(alignment: .firstTextBaseline, spacing: 20) {
                            Text(shortcut.0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(shortcut.1)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(alignment: .trailing)
                        }
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                        if index < shortcuts.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            Text("Slack-compatible composer behavior is intentional: Command-Return sends, while Return inserts a newline.")
                .font(.callout.weight(.semibold))
        }
        .padding(20)
        .frame(minWidth: 500, idealWidth: 620, minHeight: 430, idealHeight: 560)
        .accessibilityIdentifier("keyboard-shortcuts-view")
        .accessibilityElement(children: .contain)
    }
}

struct DataPrivacyGuideView: View {
    let isFirstRun: Bool
    let completion: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFirstRun ? "Welcome to Self DM Notes" : "Data and Privacy Guide")
                        .font(.title2.weight(.semibold))
                    Text("Know where your archive lives and how to protect it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isFirstRun {
                    Button("Close", action: dismiss.callAsFunction)
                        .keyboardShortcut(.cancelAction)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guideSection(
                        title: "Local-only archive",
                        symbol: "internaldrive",
                        text: "Notes, drafts, attachments, preview cache, and search data stay in this Mac user account’s Application Support folder. Self DM Notes has no account, cloud sync, or multi-device synchronization."
                    )
                    guideSection(
                        title: "Backups are essential",
                        symbol: "externaldrive.badge.timemachine",
                        text: "Local-only does not mean backed up. Choose an automatic backup folder in Settings and periodically create a manual verified backup. Portable JSON and Markdown export is for app-independent access; a verified backup is required for restore."
                    )
                    guideSection(
                        title: "Link-preview privacy",
                        symbol: "network.badge.shield.half.filled",
                        text: "Automatic link previews start off. Enabling them contacts linked websites and can reveal your IP address and destination. Fetches use no browser cookies or saved credentials, but public APIs cannot eliminate every DNS-rebinding, VPN, proxy, or network-extension risk."
                    )
                    guideSection(
                        title: "You control recovery",
                        symbol: "lock.shield",
                        text: "Restore validates and stages a backup before the next-launch switch. Health Check only reads SQLite and managed files; it never repairs, removes, or replaces data. Support Information is redacted and excludes note content, URLs, filenames, preview text, file paths, hashes, and attachment bytes."
                    )
                }
            }

            HStack {
                Spacer()
                if isFirstRun {
                    Button("Continue to My Notes") {
                        completion()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("complete-onboarding-button")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 500, idealHeight: 650)
        .interactiveDismissDisabled(isFirstRun)
        .accessibilityIdentifier(isFirstRun ? "onboarding-view" : "data-privacy-guide")
        .accessibilityElement(children: .contain)
    }

    private func guideSection(title: String, symbol: String, text: String) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AboutSupportView: View {
    let supportService: SupportService?
    @ObservedObject var model: TimelineViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var healthReport: LibraryHealthReport?
    @State private var isCheckingHealth = false
    @State private var isExportingSupport = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showKeyboardShortcuts = false
    @State private var showDataGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("About Self DM Notes")
                        .font(.title2.weight(.semibold))
                    Text(versionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }

            if let errorMessage {
                StatusBanner(
                    title: "Support action not completed",
                    message: errorMessage,
                    isError: true,
                    identifier: "support-error",
                    dismiss: { self.errorMessage = nil }
                )
            } else if let statusMessage {
                StatusBanner(
                    title: "Done",
                    message: statusMessage,
                    isError: false,
                    identifier: "support-status",
                    dismiss: { self.statusMessage = nil }
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Storage and backup") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Local-only storage; cloud sync is not available", systemImage: "internaldrive")
                            if let supportService {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Data location")
                                        .font(.caption.weight(.semibold))
                                    Text(supportService.libraryLocation.path)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .accessibilityLabel("Data location: \(supportService.libraryLocation.path)")
                                }
                                Button("Reveal Data Folder in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([
                                        supportService.libraryLocation
                                    ])
                                }
                                Text(supportService.automaticBackupStatus)
                                    .font(.callout)
                            } else {
                                Text("The data location and backup status are unavailable because the local archive did not open.")
                                    .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Library health") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Health Check reads SQLite integrity, foreign keys, migration history, and managed-file existence, type, size, and stored hashes. It never repairs or removes anything.")
                                .font(.callout)
                            if let healthReport {
                                healthSummary(healthReport)
                            } else {
                                Text("Not checked in this app session.")
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                runHealthCheck()
                            } label: {
                                if isCheckingHealth {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Run Health Check", systemImage: "checkmark.shield")
                                }
                            }
                            .disabled(
                                supportService == nil
                                    || !model.canRunLibraryHealthCheck
                                    || isCheckingHealth
                                    || isExportingSupport
                            )
                            .accessibilityIdentifier("run-health-check-button")
                            .accessibilityHint("Performs a read-only consistency check without repairing or deleting data.")
                            if !model.canRunLibraryHealthCheck {
                                Text("Finish or cancel the current library operation before checking health.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Documentation and support") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Support Information is versioned JSON containing app, build, operating-system, schema, backup, aggregate health, and typed diagnostic event data only.")
                                .font(.callout)
                            Text("It excludes note and draft bodies, URLs, original filenames, attachment bytes and hashes, preview text and images, absolute paths, and backup folder names.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Data and Privacy Guide", systemImage: "hand.raised") {
                                    showDataGuide = true
                                }
                                Button("Keyboard Shortcuts", systemImage: "keyboard") {
                                    showKeyboardShortcuts = true
                                }
                            }
                            Button("Export Redacted Support Information…", systemImage: "lifepreserver") {
                                exportSupportInformation()
                            }
                            .disabled(
                                supportService == nil
                                    || !model.canRunLibraryHealthCheck
                                    || isCheckingHealth
                                    || isExportingSupport
                            )
                            .accessibilityIdentifier("export-support-information-button")
                            .accessibilityHint("Creates a new redacted JSON file without overwriting an existing file.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 680, minHeight: 540, idealHeight: 720)
        .accessibilityIdentifier("about-support-view")
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .sheet(isPresented: $showDataGuide) {
            DataPrivacyGuideView(isFirstRun: false, completion: {})
        }
    }

    private var versionDescription: String {
        guard let supportService else { return "Version information unavailable" }
        return "Version \(supportService.applicationVersion), build \(supportService.buildVersion)"
    }

    private func healthSummary(_ report: LibraryHealthReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                healthStatusTitle(report.status),
                systemImage: report.status == .healthy
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            Text(report.summary)
                .fixedSize(horizontal: false, vertical: true)
            if report.status != .unavailable {
                LabeledContent(
                    "Notes represented",
                    value: report.noteCount.map { String($0) } ?? "Unavailable"
                )
                LabeledContent("Referenced managed files", value: "\(report.expectedManagedFileCount)")
                if report.issueCount > 0 {
                    LabeledContent("Missing referenced files", value: "\(report.missingManagedFileCount)")
                    LabeledContent("Unreadable referenced files", value: "\(report.inaccessibleManagedFileCount)")
                    LabeledContent("Size mismatches", value: "\(report.metadataMismatchCount)")
                    LabeledContent("Checksum mismatches", value: "\(report.checksumMismatchCount)")
                    LabeledContent("Unexpected managed items", value: "\(report.unexpectedManagedItemCount)")
                    LabeledContent("Unsafe managed items", value: "\(report.unsafeManagedItemCount)")
                    LabeledContent("Unreadable managed folders", value: "\(report.inaccessibleManagedDirectoryCount)")
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-health-result")
        .accessibilityLabel("Library health: \(healthStatusTitle(report.status))")
        .accessibilityValue(report.summary)
    }

    private func healthStatusTitle(_ status: LibraryHealthStatus) -> String {
        switch status {
        case .healthy: "Healthy"
        case .needsAttention: "Needs attention"
        case .unavailable: "Check unavailable"
        }
    }

    private func runHealthCheck() {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        statusMessage = nil
        errorMessage = nil
        Task {
            guard let report = await model.checkLibraryHealth() else {
                errorMessage = TimelineSupportError.operationUnavailable.localizedDescription
                isCheckingHealth = false
                return
            }
            healthReport = report
            isCheckingHealth = false
            AccessibilityAnnouncement.post("Library health check completed. \(report.summary)")
        }
    }

    private func exportSupportInformation() {
        guard supportService != nil, !isExportingSupport else { return }
        let panel = NSSavePanel()
        panel.title = "Export Redacted Support Information"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Self DM Notes Support Information.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExportingSupport = true
        statusMessage = nil
        errorMessage = nil
        let currentHealth = healthReport
        Task {
            do {
                let result = try await model.exportSupportInformation(
                    to: destinationURL,
                    latestHealthReport: currentHealth
                )
                statusMessage = "Redacted support information created: \(result.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
            }
            isExportingSupport = false
        }
    }
}
