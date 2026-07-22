import Foundation
import XCTest
@testable import SelfDMNotes

final class DatabaseBootstrapTests: XCTestCase {
    func testFreshDatabaseMigratesClosesAndReopens() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()

        let database = try AppDatabase(databaseURL: provider.databaseURL)
        try database.verifyConnection()
        try database.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.databaseURL.path))

        let reopenedDatabase = try AppDatabase(databaseURL: provider.databaseURL)
        try reopenedDatabase.verifyConnection()
        try reopenedDatabase.close()
    }

    func testSystemSQLiteSupportsFunctionalFTS5Queries() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()

        let database = try AppDatabase(databaseURL: provider.databaseURL)
        try database.verifyFTS5Availability()
        try database.close()
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfDMNotesTests-\(UUID().uuidString)", isDirectory: true)
    }
}
