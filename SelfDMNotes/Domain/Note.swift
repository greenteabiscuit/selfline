import Foundation

struct Note: Identifiable, Equatable, Sendable {
    let id: UUID
    let body: String
    let createdAt: Date
    let updatedAt: Date?
    let deletedAt: Date?
    let sortKey: Int64
    let threadRootID: UUID?
    let reminderAt: Date?
    let reminderCompletedAt: Date?
    let replyCount: Int
    let attachments: [Attachment]
    let linkPreviews: [LinkPreview]

    var isReply: Bool { threadRootID != nil }
    var hasPendingReminder: Bool { reminderAt != nil && reminderCompletedAt == nil }

    func isReminderDue(at date: Date) -> Bool {
        guard let reminderAt, reminderCompletedAt == nil, deletedAt == nil else { return false }
        return reminderAt <= date
    }

    init(
        id: UUID,
        body: String,
        createdAt: Date,
        updatedAt: Date?,
        deletedAt: Date?,
        sortKey: Int64,
        threadRootID: UUID? = nil,
        reminderAt: Date? = nil,
        reminderCompletedAt: Date? = nil,
        replyCount: Int = 0,
        attachments: [Attachment] = [],
        linkPreviews: [LinkPreview] = []
    ) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.sortKey = sortKey
        self.threadRootID = threadRootID
        self.reminderAt = reminderAt
        self.reminderCompletedAt = reminderCompletedAt
        self.replyCount = replyCount
        self.attachments = attachments
        self.linkPreviews = linkPreviews
    }
}

struct NoteThread: Equatable, Sendable {
    let root: Note
    let replies: [Note]
}

struct NotePage: Equatable, Sendable {
    let notes: [Note]
    let hasOlder: Bool
}

struct Draft: Equatable, Sendable {
    let body: String
    let updatedAt: Date
}
