import Foundation

enum LinkPreviewStatus: String, Equatable, Sendable {
    case pending
    case ready
    case failed
    case removed
}

struct LinkPreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let noteID: UUID
    let originalURL: String
    let requestKey: String
    let status: LinkPreviewStatus
    let canonicalURL: String?
    let title: String?
    let summary: String?
    let imageURL: String?
    let localImageFilename: String?
    let siteName: String?
    let failureReason: String?
    let fetchedAt: Date?

    var displayTitle: String {
        title ?? siteName ?? URL(string: originalURL)?.host(percentEncoded: false) ?? originalURL
    }
}

struct DetectedLink: Equatable, Sendable {
    let originalURL: String
    let requestKey: String
    let url: URL
}

struct LinkPreviewMetadata: Equatable, Sendable {
    let canonicalURL: String
    let title: String
    let summary: String?
    let imageURL: String?
    let siteName: String
    let imagePNGData: Data?
}

struct LinkPreviewWorkItem: Equatable, Sendable {
    let requestKey: String
    let originalURL: String
}

struct LinkPreviewReconciliationSnapshot: Equatable, Sendable {
    let noteID: UUID
    let body: String
    let sortKey: Int64
    let revision: Int64
}

struct LinkPreviewReconciliationResult: Equatable, Sendable {
    let wasApplied: Bool
    let changedNoteIDs: Set<UUID>
    let unusedImageFilenames: [String]
}

struct LinkPreviewCacheCommitResult: Equatable, Sendable {
    let changedNoteIDs: Set<UUID>
    let replacedImageFilename: String?
    let acceptedNewImage: Bool
}

struct LinkPreviewRemovalResult: Equatable, Sendable {
    let changedNoteID: UUID
    let unusedImageFilename: String?
}

struct LinkPreviewMaintenanceState: Equatable, Sendable {
    let referencedImageFilenames: Set<String>
}

struct LinkPreviewStartupResult: Equatable, Sendable {
    let automaticFetchingEnabled: Bool
    let warning: String?
}

struct PermanentlyDeletedManagedFiles: Equatable, Sendable {
    let blobs: [AttachmentBlob]
    let previewImageFilenames: [String]
}
