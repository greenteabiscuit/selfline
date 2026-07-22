import Foundation

struct Attachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let noteID: UUID
    let originalFilename: String
    let mediaType: String
    let byteSize: Int64
    let width: Int?
    let height: Int?
    let contentHash: String
    let createdAt: Date
    let sortIndex: Int
    let storedFilename: String
    let thumbnailFilename: String?

    var isImage: Bool {
        width != nil && height != nil && thumbnailFilename != nil
    }
}

struct AttachmentBlob: Equatable, Sendable {
    let id: UUID
    let contentHash: String
    let storedFilename: String
    let thumbnailFilename: String?
    let mediaType: String
    let byteSize: Int64
    let width: Int?
    let height: Int?
    let createdAt: Date
}

struct AttachmentBlobReference: Equatable, Sendable {
    let blob: AttachmentBlob
    let originalFilenames: [String]
}

struct StagedAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let originalFilename: String
    let stagingFilename: String
    let thumbnailStagingFilename: String?
    let mediaType: String
    let byteSize: Int64
    let width: Int?
    let height: Int?
    let contentHash: String
    let createdAt: Date
    let sortIndex: Int

    var isImage: Bool {
        width != nil && height != nil && thumbnailStagingFilename != nil
    }
}

struct NewAttachment: Sendable {
    let id: UUID
    let originalFilename: String
    let createdAt: Date
    let sortIndex: Int
    let blob: AttachmentBlob
}

struct AttachmentMaintenanceReport: Equatable, Sendable {
    let removedAbandonedStagingItems: Int
    let removedOrphanedManagedItems: Int
    let missingManagedOriginalFilenames: [String]
    let missingThumbnailCount: Int
    let missingStagedAttachmentFilenames: [String]

    var hasIssues: Bool {
        !missingManagedOriginalFilenames.isEmpty
            || !missingStagedAttachmentFilenames.isEmpty
            || missingThumbnailCount > 0
    }

    var hasCleanup: Bool {
        removedAbandonedStagingItems > 0 || removedOrphanedManagedItems > 0
    }
}

struct RecoveredStagedAttachment: Equatable, Sendable {
    let attachment: StagedAttachment
    let isAvailable: Bool
}

struct AttachmentStartupState: Equatable, Sendable {
    let report: AttachmentMaintenanceReport
    let recoveredAttachments: [RecoveredStagedAttachment]
}

struct AttachmentCommitResult: Equatable, Sendable {
    let note: Note
    let stagingCleanupFailed: Bool
}

struct AttachmentDeletionResult: Equatable, Sendable {
    let managedFileCleanupFailed: Bool
}

enum PendingAttachmentStatus: Equatable, Sendable {
    case importing
    case ready
    case failed
}

struct PendingAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    var status: PendingAttachmentStatus
    var progress: Double
    var errorMessage: String?
    var canRetry: Bool
    var stagedAttachment: StagedAttachment?
}
