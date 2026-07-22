import Foundation
import XCTest
@testable import SelfDMNotes

final class ApplicationSupportDirectoryProviderTests: XCTestCase {
    func testExplicitRootIsPreparedWithoutUsingProductionLibrary() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfDMNotesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            provider.databaseURL,
            rootURL.appendingPathComponent("notes.sqlite", isDirectory: false)
        )
        XCTAssertFalse(rootURL.path.contains("/Library/Application Support/"))
    }

    func testRuntimeUsesExplicitTestEnvironmentOverride() throws {
        let identifier = "SelfDMNotesUITests-\(UUID().uuidString)"
        let provider = try ApplicationSupportDirectoryProvider.runtime(
            environment: [
                ApplicationSupportDirectoryProvider.testOverrideEnvironmentKey: identifier
            ]
        )

        XCTAssertEqual(
            provider.rootURL,
            FileManager.default.temporaryDirectory.appendingPathComponent(
                identifier,
                isDirectory: true
            )
        )
        XCTAssertFalse(provider.rootURL.path.contains("/Library/Application Support/"))
    }

    func testRuntimeRejectsUnsafeTestEnvironmentOverride() {
        XCTAssertThrowsError(
            try ApplicationSupportDirectoryProvider.runtime(
                environment: [
                    ApplicationSupportDirectoryProvider.testOverrideEnvironmentKey: "../escape"
                ]
            )
        )
    }
}
