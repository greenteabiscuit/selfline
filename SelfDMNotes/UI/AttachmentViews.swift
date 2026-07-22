import AppKit
import ImageIO
import QuickLook
@preconcurrency import QuickLookUI
import SwiftUI

@MainActor
final class AttachmentQuickLookController: NSObject, @MainActor QLPreviewPanelDataSource {
    static let shared = AttachmentQuickLookController()

    private var item: AttachmentPreviewItem?

    func preview(url: URL, title: String) {
        item = AttachmentPreviewItem(url: url, title: title)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        item
    }
}

private final class AttachmentPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

struct PendingAttachmentsView: View {
    @ObservedObject var model: TimelineViewModel

    var body: some View {
        if !model.pendingAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pending attachments")
                    .font(.caption.weight(.semibold))
                ForEach(model.pendingAttachments) { attachment in
                    PendingAttachmentRow(attachment: attachment, model: model)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pending attachments")
        }
    }
}

private struct PendingAttachmentRow: View {
    let attachment: PendingAttachment
    @ObservedObject var model: TimelineViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                switch attachment.status {
                case .importing:
                    ProgressView(value: attachment.progress) {
                        Text("Copying \(Int(attachment.progress * 100)) percent")
                    }
                    .progressViewStyle(.linear)
                case .ready:
                    Text(readyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text(attachment.errorMessage ?? "Import failed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            switch attachment.status {
            case .importing:
                Button("Cancel import", systemImage: "stop.circle") {
                    model.cancelPendingAttachment(id: attachment.id)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Cancel import of \(attachment.displayName)")
                .disabled(
                    !model.canMutateLibrary || model.isSending || model.isDiscardingDraft
                )
            case .failed where attachment.canRetry:
                Button("Retry", systemImage: "arrow.clockwise") {
                    model.retryPendingAttachment(id: attachment.id)
                }
                .accessibilityLabel("Retry importing \(attachment.displayName)")
                .disabled(
                    !model.canMutateLibrary || model.isSending || model.isDiscardingDraft
                )
            default:
                EmptyView()
            }
            Button("Remove", systemImage: "xmark.circle") {
                model.removePendingAttachment(id: attachment.id)
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Remove pending attachment \(attachment.displayName)")
            .disabled(!model.canMutateLibrary || model.isSending || model.isDiscardingDraft)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-attachment")
        .accessibilityLabel(attachment.displayName)
        .accessibilityValue(accessibilityStatus)
        .onChange(of: attachment.status) { previousStatus, status in
            guard previousStatus != status else { return }
            AccessibilityAnnouncement.post(
                "\(attachment.displayName). \(accessibilityStatus)",
                priority: status == .failed ? .high : .medium
            )
        }
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

    private var readyDescription: String {
        guard let staged = attachment.stagedAttachment else { return "Ready to send" }
        return "Ready to send • \(ByteCountFormatter.string(fromByteCount: staged.byteSize, countStyle: .file))"
    }

    private var accessibilityStatus: String {
        switch attachment.status {
        case .importing:
            "Importing, \(Int(attachment.progress * 100)) percent"
        case .ready:
            readyDescription
        case .failed:
            "Import failed. \(attachment.errorMessage ?? "Remove the item and try again.")"
        }
    }
}

struct NoteAttachmentsView: View {
    let attachments: [Attachment]
    @ObservedObject var model: TimelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentCard(attachment: attachment, model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }
}

private struct AttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var model: TimelineViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if attachment.isImage, let thumbnailURL = model.thumbnailURL(for: attachment) {
                AttachmentThumbnail(
                    url: thumbnailURL,
                    accessibilityLabel: "Image attachment \(attachment.originalFilename)"
                )
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.originalFilename)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(fileDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview", systemImage: "eye") {
                    model.previewAttachment(attachment)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Preview \(attachment.originalFilename)")
            }
            Spacer()
            Menu("Attachment actions", systemImage: "ellipsis.circle") {
                Button("Preview", systemImage: "eye") {
                    model.previewAttachment(attachment)
                }
                Button("Open", systemImage: "arrow.up.forward.app") {
                    model.openAttachment(attachment)
                }
                Button("Reveal in Finder", systemImage: "folder") {
                    model.revealAttachment(attachment)
                }
                Button("Export…", systemImage: "square.and.arrow.up") {
                    Task { await model.exportAttachment(attachment) }
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    model.copyAttachment(attachment)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("attachment-actions")
            .accessibilityLabel("Actions for \(attachment.originalFilename)")
            .accessibilityHint("Preview, open, reveal, export, or copy this attachment.")
        }
        .padding(8)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment-card")
        .accessibilityLabel(attachment.isImage ? "Image attachment" : "File attachment")
        .accessibilityValue("\(attachment.originalFilename), \(fileDescription)")
    }

    private var fileDescription: String {
        var components = [
            ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file)
        ]
        if let width = attachment.width, let height = attachment.height {
            components.append("\(width) by \(height) pixels")
        }
        return components.joined(separator: " • ")
    }
}

private struct AttachmentThumbnail: View {
    let url: URL
    let accessibilityLabel: String

    @State private var loadedImage: LoadedAttachmentThumbnail?
    @State private var didFail = false

    var body: some View {
        Group {
            if let loadedImage {
                Image(
                    loadedImage.image,
                    scale: 1,
                    label: Text(accessibilityLabel)
                )
                .resizable()
                .scaledToFill()
            } else if didFail {
                Image(systemName: "photo.badge.exclamationmark")
                    .accessibilityLabel("Thumbnail unavailable for \(accessibilityLabel)")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading \(accessibilityLabel)")
            }
        }
        .frame(width: 92, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: url) {
            let result = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                ),
                let image = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                ) else {
                    return LoadedAttachmentThumbnail?.none
                }
                return LoadedAttachmentThumbnail(image: image)
            }.value
            loadedImage = result
            didFail = result == nil
        }
    }
}

private struct LoadedAttachmentThumbnail: @unchecked Sendable {
    let image: CGImage
}
