import Foundation
import GRDB
import XCTest
@testable import SelfDMNotes

final class NotePerformanceFixtureTests: XCTestCase {
    func testHundredThousandNoteFixtureUsesBoundedPagesAndFastSearch() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesPerformanceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: rootURL)
        try provider.prepare()

        let setupQueue = try DatabaseQueue(path: provider.databaseURL.path)
        try DatabaseMigrations.makeMigrator().migrate(setupQueue)
        let fixtureStart = Date()
        try setupQueue.write { database in
            for index in 0..<100_000 {
                var body = "Archive timeline note \(index) project\(index % 100)"
                if index.isMultiple(of: 1_000) {
                    body += " rarequasar\(index)"
                }
                if index.isMultiple(of: 100) {
                    body += " café 東京"
                }
                if index.isMultiple(of: 250) {
                    body += " 🚀"
                }
                try database.execute(
                    sql: "INSERT INTO notes (id, body, createdAt) VALUES (?, ?, ?)",
                    arguments: [
                        String(format: "00000000-0000-0000-0000-%012d", index),
                        body,
                        Int64(1_700_000_000_000 + index)
                    ]
                )
            }
        }
        let fixtureDuration = Date().timeIntervalSince(fixtureStart)
        try setupQueue.close()

        let database = try AppDatabase(databaseURL: provider.databaseURL)
        let newestStart = Date()
        let newestPage = try database.fetchNotesPage(limit: 50)
        let newestDuration = Date().timeIntervalSince(newestStart)
        let olderStart = Date()
        let olderPage = try database.fetchNotesPage(
            beforeSortKey: try XCTUnwrap(newestPage.notes.first?.sortKey),
            limit: 50
        )
        let olderDuration = Date().timeIntervalSince(olderStart)

        XCTAssertEqual(newestPage.notes.count, 50)
        XCTAssertTrue(newestPage.notes.first?.body.hasPrefix("Archive timeline note 99950") == true)
        XCTAssertTrue(newestPage.notes.last?.body.hasPrefix("Archive timeline note 99999") == true)
        XCTAssertTrue(newestPage.hasOlder)
        XCTAssertEqual(olderPage.notes.count, 50)
        XCTAssertTrue(olderPage.notes.first?.body.hasPrefix("Archive timeline note 99900") == true)
        XCTAssertTrue(olderPage.notes.last?.body.hasPrefix("Archive timeline note 99949") == true)
        XCTAssertTrue(olderPage.hasOlder)
        XCTAssertLessThan(newestDuration, 1.0)
        XCTAssertLessThan(olderDuration, 1.0)

        let probes: [(String, NoteSearchRequest, Int)] = [
            ("common", NoteSearchRequest(text: "archive", filters: NoteSearchFilters(), sort: .relevance), 100_000),
            ("rare", NoteSearchRequest(text: "rarequasar50000", filters: NoteSearchFilters(), sort: .relevance), 1),
            ("unicode", NoteSearchRequest(text: "東京", filters: NoteSearchFilters(), sort: .newest), 1_000),
            ("emoji", NoteSearchRequest(text: "🚀", filters: NoteSearchFilters(), sort: .newest), 400)
        ]
        var measurements: [String] = []
        for (name, request, expectedCount) in probes {
            var durations: [TimeInterval] = []
            for _ in 0..<7 {
                let start = Date()
                let response = try database.searchNotes(request)
                durations.append(Date().timeIntervalSince(start))
                XCTAssertEqual(response.totalCount, expectedCount)
            }
            let sorted = durations.sorted()
            XCTAssertLessThan(try XCTUnwrap(sorted.last), 1.0)
            measurements.append(
                String(
                    format: "%@ median %.6fs worst %.6fs",
                    name,
                    sorted[sorted.count / 2],
                    try XCTUnwrap(sorted.last)
                )
            )
        }

        print(String(format: "100,000-note fixture %.3fs", fixtureDuration))
        print(String(format: "newest page %.6fs; older page %.6fs", newestDuration, olderDuration))
        print(measurements.joined(separator: "; "))
        try database.close()
    }
}
