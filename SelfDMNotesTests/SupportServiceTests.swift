import Foundation
import XCTest
@testable import SelfDMNotes

final class SupportServiceTests: XCTestCase {
    @MainActor
    func testHealthCheckDoesNotPersistPendingDraftAndReschedulesItsSave() async throws {
        let fixture = try SupportFixture.make()
        defer { fixture.cleanUp() }
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.database.saveDraft(body: "Persisted draft", updatedAt: originalDate)
        let model = TimelineViewModel(
            database: fixture.database,
            supportService: fixture.supportService
        )
        await model.loadInitialContent()
        model.setDraft("Pending draft edit")

        let report = await model.checkLibraryHealth()

        XCTAssertEqual(report?.status, .healthy)
        XCTAssertEqual(
            try fixture.database.loadDraft(),
            Draft(body: "Persisted draft", updatedAt: originalDate)
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try fixture.database.loadDraft()?.body, "Pending draft edit")
    }

    @MainActor
    func testHealthCheckDoesNotRewriteSettledDraft() async throws {
        let fixture = try SupportFixture.make()
        defer { fixture.cleanUp() }
        let model = TimelineViewModel(
            database: fixture.database,
            supportService: fixture.supportService
        )
        await model.loadInitialContent()
        model.setDraft("Settled draft")
        try await Task.sleep(nanoseconds: 500_000_000)
        let persistedDraft = try XCTUnwrap(fixture.database.loadDraft())

        let report = await model.checkLibraryHealth()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(report?.status, .healthy)
        XCTAssertEqual(try fixture.database.loadDraft(), persistedDraft)
    }

    func testHealthCheckIsReadOnlyAndFindsMissingCorruptAndUnexpectedFiles() throws {
        let fixture = try SupportFixture.make()
        defer { fixture.cleanUp() }
        let seeded = try fixture.seedPrivateContent()

        let originalBefore = try Data(contentsOf: seeded.managedOriginalURL)
        let originalNamesBefore = try FileManager.default.contentsOfDirectory(
            atPath: fixture.provider.originalsURL.path
        )
        let healthy = fixture.supportService.checkLibrary(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(healthy.status, .healthy)
        XCTAssertEqual(healthy.noteCount, 1)
        XCTAssertEqual(healthy.expectedManagedFileCount, 1)
        XCTAssertEqual(healthy.issueCount, 0)
        XCTAssertEqual(try Data(contentsOf: seeded.managedOriginalURL), originalBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.provider.originalsURL.path),
            originalNamesBefore
        )
        XCTAssertEqual(try fixture.database.fetchNote(id: seeded.note.id), seeded.note)

        let changedBytes = Data(repeating: 0x58, count: originalBefore.count)
        try changedBytes.write(to: seeded.managedOriginalURL)
        let corrupt = fixture.supportService.checkLibrary()
        XCTAssertEqual(corrupt.status, .needsAttention)
        XCTAssertEqual(corrupt.checksumMismatchCount, 1)
        XCTAssertEqual(try Data(contentsOf: seeded.managedOriginalURL), changedBytes)

        try FileManager.default.removeItem(at: seeded.managedOriginalURL)
        let orphanURL = fixture.provider.originalsURL.appendingPathComponent("unreferenced.data")
        try Data("unreferenced fixture".utf8).write(to: orphanURL)
        let inconsistent = fixture.supportService.checkLibrary()
        XCTAssertEqual(inconsistent.status, .needsAttention)
        XCTAssertEqual(inconsistent.missingManagedFileCount, 1)
        XCTAssertEqual(inconsistent.unexpectedManagedItemCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertEqual(try fixture.database.fetchNote(id: seeded.note.id), seeded.note)
    }

    func testMalformedDatabaseReturnsUnavailableWithoutChangingBytes() throws {
        let fixture = try SupportFixture.make()
        defer { fixture.cleanUp() }
        try fixture.database.close()
        let malformed = Data("not a SQLite database — private fixture marker".utf8)
        try malformed.write(to: fixture.provider.databaseURL)

        let report = fixture.supportService.checkLibrary()

        XCTAssertEqual(report.status, .unavailable)
        XCTAssertNil(report.noteCount)
        XCTAssertEqual(try Data(contentsOf: fixture.provider.databaseURL), malformed)
    }

    func testHealthCheckRejectsManagedDirectorySymlinksWithoutReadingExternalTree() throws {
        for replaceAttachmentsAncestor in [false, true] {
            let fixture = try SupportFixture.make()
            defer { fixture.cleanUp() }
            let seeded = try fixture.seedPrivateContent()
            let originalBytes = try Data(contentsOf: seeded.managedOriginalURL)
            let externalRoot = fixture.parentURL.appendingPathComponent(
                replaceAttachmentsAncestor ? "ExternalAttachments" : "ExternalOriginals",
                isDirectory: true
            )
            let externalOriginals = replaceAttachmentsAncestor
                ? externalRoot.appendingPathComponent("originals", isDirectory: true)
                : externalRoot
            try FileManager.default.createDirectory(
                at: externalOriginals,
                withIntermediateDirectories: true
            )
            if replaceAttachmentsAncestor {
                try FileManager.default.createDirectory(
                    at: externalRoot.appendingPathComponent("thumbnails", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            let externalOriginal = externalOriginals.appendingPathComponent(
                seeded.managedOriginalURL.lastPathComponent
            )
            try originalBytes.write(to: externalOriginal)

            let replacedURL = replaceAttachmentsAncestor
                ? fixture.provider.attachmentsURL
                : fixture.provider.originalsURL
            try FileManager.default.removeItem(at: replacedURL)
            try FileManager.default.createSymbolicLink(
                at: replacedURL,
                withDestinationURL: externalRoot
            )

            let report = fixture.supportService.checkLibrary()

            XCTAssertEqual(report.status, .needsAttention)
            XCTAssertGreaterThan(report.inaccessibleManagedDirectoryCount, 0)
            XCTAssertGreaterThan(report.inaccessibleManagedFileCount, 0)
            XCTAssertEqual(try Data(contentsOf: externalOriginal), originalBytes)
        }
    }

    func testHealthCheckRejectsSubstitutedDatabasePathWithoutChangingReplacement() throws {
        let fixture = try SupportFixture.make()
        defer { fixture.cleanUp() }
        let replacementURL = fixture.parentURL.appendingPathComponent("External.sqlite")
        let replacementBytes = Data("external private database marker".utf8)
        try replacementBytes.write(to: replacementURL)
        try FileManager.default.removeItem(at: fixture.provider.databaseURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.provider.databaseURL,
            withDestinationURL: replacementURL
        )

        let report = fixture.supportService.checkLibrary()

        XCTAssertEqual(report.status, .unavailable)
        XCTAssertEqual(try Data(contentsOf: replacementURL), replacementBytes)
    }

    func testSupportExportExcludesPrivateContentAndFaultsLeaveNoOutput() throws {
        let fixture = try SupportFixture.make()
        defer { fixture.cleanUp() }
        let seeded = try fixture.seedPrivateContent()
        let health = fixture.supportService.checkLibrary()
        let outputURL = fixture.outputURL.appendingPathComponent("support.json")

        XCTAssertEqual(
            try fixture.supportService.exportSupportInformation(
                to: outputURL,
                latestHealthReport: health,
                now: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            outputURL
        )
        let exportedData = try Data(contentsOf: outputURL)
        let exportedText = try XCTUnwrap(String(data: exportedData, encoding: .utf8))
        for privateValue in seeded.privateValues + [fixture.provider.rootURL.path] {
            XCTAssertFalse(exportedText.contains(privateValue), "Leaked private value: \(privateValue)")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exportedData) as? [String: Any]
        )
        XCTAssertEqual(object["formatIdentifier"] as? String, SupportService.formatIdentifier)
        let storage = try XCTUnwrap(object["storage"] as? [String: Any])
        XCTAssertEqual(storage["absolutePathIncluded"] as? Bool, false)
        XCTAssertEqual(storage["cloudSyncEnabled"] as? Bool, false)

        let existingURL = fixture.outputURL.appendingPathComponent("existing.json")
        let existingData = Data("existing user data".utf8)
        try existingData.write(to: existingURL)
        XCTAssertThrowsError(
            try fixture.supportService.exportSupportInformation(to: existingURL)
        ) { error in
            XCTAssertEqual(error as? SupportServiceError, .destinationAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: existingURL), existingData)

        for code in [POSIXErrorCode.ENOSPC, .EROFS, .EACCES] {
            let diagnostics = RedactedDiagnosticLog()
            let faulted = SupportService(
                provider: fixture.provider,
                database: fixture.database,
                archiveService: fixture.archiveService,
                diagnostics: diagnostics,
                applicationVersion: "test",
                buildVersion: "test",
                exportFault: .failBeforePublication(code)
            )
            let failedURL = fixture.failureOutputURL.appendingPathComponent("\(code.rawValue).json")
            XCTAssertThrowsError(try faulted.exportSupportInformation(to: failedURL))
            XCTAssertFalse(FileManager.default.fileExists(atPath: failedURL.path))
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: fixture.failureOutputURL.path)
                    .isEmpty
            )
        }

        let libraryDestination = fixture.provider.rootURL.appendingPathComponent("support.json")
        XCTAssertThrowsError(
            try fixture.supportService.exportSupportInformation(to: libraryDestination)
        ) { error in
            XCTAssertEqual(error as? SupportServiceError, .destinationOverlapsLibrary)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryDestination.path))
    }
}

private final class SupportFixture {
    let parentURL: URL
    let provider: ApplicationSupportDirectoryProvider
    let database: AppDatabase
    let store: AttachmentStore
    let archiveService: ArchiveService
    let supportService: SupportService
    let outputURL: URL
    let failureOutputURL: URL
    let defaultsSuiteName: String

    private init(
        parentURL: URL,
        provider: ApplicationSupportDirectoryProvider,
        database: AppDatabase,
        store: AttachmentStore,
        archiveService: ArchiveService,
        supportService: SupportService,
        outputURL: URL,
        failureOutputURL: URL,
        defaultsSuiteName: String
    ) {
        self.parentURL = parentURL
        self.provider = provider
        self.database = database
        self.store = store
        self.archiveService = archiveService
        self.supportService = supportService
        self.outputURL = outputURL
        self.failureOutputURL = failureOutputURL
        self.defaultsSuiteName = defaultsSuiteName
    }

    static func make() throws -> SupportFixture {
        let identifier = UUID().uuidString
        let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesSupportTests-\(identifier)",
            isDirectory: true
        )
        let provider = ApplicationSupportDirectoryProvider(
            rootURL: parentURL.appendingPathComponent("Library", isDirectory: true)
        )
        let outputURL = parentURL.appendingPathComponent("Output", isDirectory: true)
        let failureOutputURL = parentURL.appendingPathComponent("Faults", isDirectory: true)
        try provider.prepare()
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: failureOutputURL,
            withIntermediateDirectories: false
        )

        let database = try AppDatabase(databaseURL: provider.databaseURL)
        let store = AttachmentStore(provider: provider, database: database)
        let defaultsSuiteName = "SelfDMNotesSupportTests.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let archiveService = ArchiveService(
            provider: provider,
            database: database,
            recoveryCoordinator: RestoreRecoveryCoordinator(provider: provider),
            defaults: defaults,
            applicationVersion: "test",
            buildVersion: "test"
        )
        let diagnostics = RedactedDiagnosticLog()
        let supportService = SupportService(
            provider: provider,
            database: database,
            archiveService: archiveService,
            diagnostics: diagnostics,
            applicationVersion: "test",
            buildVersion: "test"
        )
        return SupportFixture(
            parentURL: parentURL,
            provider: provider,
            database: database,
            store: store,
            archiveService: archiveService,
            supportService: supportService,
            outputURL: outputURL,
            failureOutputURL: failureOutputURL,
            defaultsSuiteName: defaultsSuiteName
        )
    }

    func seedPrivateContent() throws -> SeededSupportContent {
        let noteBody = "PRIVATE-NOTE-BODY https://private.example/secret-path"
        let originalFilename = "Private Original Filename.txt"
        let attachmentBytes = Data("PRIVATE-ATTACHMENT-BYTES".utf8)
        let sourceURL = parentURL.appendingPathComponent(originalFilename)
        try attachmentBytes.write(to: sourceURL)
        let staged = try store.stageSelectedFile(
            at: sourceURL,
            id: UUID(),
            sortIndex: 0
        )
        let note = try store.commitNote(
            body: noteBody,
            stagedAttachments: [staged]
        ).note

        let snapshot = try XCTUnwrap(database.fetchLinkReconciliationSnapshot(noteID: note.id))
        _ = try database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        try database.setAutomaticLinkPreviewsEnabled(true)
        let pending = try XCTUnwrap(database.fetchNote(id: note.id).linkPreviews.first)
        _ = try database.commitLinkPreviewMetadata(
            requestKey: pending.requestKey,
            metadata: LinkPreviewMetadata(
                canonicalURL: "https://private.example/canonical-secret",
                title: "PRIVATE PREVIEW TITLE",
                summary: "PRIVATE PREVIEW SUMMARY",
                imageURL: "https://private.example/private-image.png",
                siteName: "PRIVATE SITE NAME",
                imagePNGData: nil
            ),
            localImageFilename: nil
        )

        let persistedNote = try database.fetchNote(id: note.id)
        let attachment = try XCTUnwrap(persistedNote.attachments.first)
        return SeededSupportContent(
            note: persistedNote,
            managedOriginalURL: provider.originalsURL.appendingPathComponent(
                attachment.storedFilename
            ),
            privateValues: [
                noteBody,
                "https://private.example/secret-path",
                originalFilename,
                "PRIVATE-ATTACHMENT-BYTES",
                "https://private.example/canonical-secret",
                "PRIVATE PREVIEW TITLE",
                "PRIVATE PREVIEW SUMMARY",
                "https://private.example/private-image.png",
                "PRIVATE SITE NAME"
            ]
        )
    }

    func cleanUp() {
        try? database.close()
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(
            forName: defaultsSuiteName
        )
        try? FileManager.default.removeItem(at: parentURL)
    }
}

private struct SeededSupportContent {
    let note: Note
    let managedOriginalURL: URL
    let privateValues: [String]
}
