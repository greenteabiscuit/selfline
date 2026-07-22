import Foundation

enum ArchiveOperationKind: String, Sendable {
    case backup
    case export
    case restore

    var title: String {
        switch self {
        case .backup: "Creating backup"
        case .export: "Exporting portable archive"
        case .restore: "Validating restore"
        }
    }
}

struct ArchiveOperationProgress: Equatable, Sendable {
    let kind: ArchiveOperationKind
    let fraction: Double
    let message: String
}

struct BackupCreationResult: Equatable, Sendable {
    let packageURL: URL
    let rotationWarning: String?
}

struct RestoreStagingResult: Equatable, Sendable {
    let backupCreatedAtMilliseconds: Int64
    let noteCount: Int
}

enum RestoreStartupMode: Equatable, Sendable {
    case none
    case trial
    case recoveredOriginal(String)
    case committedCleanupPending
    case cancellationCleanupPending
    case unarmedCleanupPending
}
