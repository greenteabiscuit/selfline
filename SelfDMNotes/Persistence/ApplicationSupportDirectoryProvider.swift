import Foundation

struct ApplicationSupportDirectoryProvider {
    static let directoryName = "SelfDMNotes"
    static let databaseFilename = "notes.sqlite"
    static let testOverrideEnvironmentKey = "SELF_DM_NOTES_TEST_APPLICATION_SUPPORT_DIRECTORY"

    let rootURL: URL

    var databaseURL: URL {
        rootURL.appendingPathComponent(Self.databaseFilename, isDirectory: false)
    }

    var attachmentsURL: URL {
        rootURL.appendingPathComponent("attachments", isDirectory: true)
    }

    var originalsURL: URL {
        attachmentsURL.appendingPathComponent("originals", isDirectory: true)
    }

    var thumbnailsURL: URL {
        attachmentsURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    var stagingURL: URL {
        rootURL.appendingPathComponent("staging", isDirectory: true)
    }

    var previewsURL: URL {
        rootURL.appendingPathComponent("previews", isDirectory: true)
    }

    static func production(fileManager: FileManager = .default) throws -> Self {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationSupportDirectoryError.applicationSupportUnavailable
        }

        return Self(
            rootURL: applicationSupportURL.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
        )
    }

    static func runtime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Self {
        if let testIdentifier = environment[testOverrideEnvironmentKey] {
            let allowedCharacters = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-_")
            )
            guard !testIdentifier.isEmpty,
                  testIdentifier.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
                throw ApplicationSupportDirectoryError.invalidTestOverride
            }
            return Self(
                rootURL: fileManager.temporaryDirectory.appendingPathComponent(
                    testIdentifier,
                    isDirectory: true
                )
            )
        }
        return try production(fileManager: fileManager)
    }

    func prepare(fileManager: FileManager = .default) throws {
        for directoryURL in [rootURL, originalsURL, thumbnailsURL, previewsURL, stagingURL] {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
    }
}

enum ApplicationSupportDirectoryError: LocalizedError {
    case applicationSupportUnavailable
    case invalidTestOverride

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support directory is unavailable."
        case .invalidTestOverride:
            "The test Application Support identifier is invalid."
        }
    }
}
