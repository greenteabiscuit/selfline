import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import SelfDMNotes

final class LinkPreviewTests: XCTestCase {
    func testNoteBodyLinkFormattingPreservesTextAndStylesExplicitWebLinks() throws {
        let body = "Before 🚀 https://example.com/path?q=One and HTTP://example.org. Not ftp://example.net or www.example.com."
        let attributed = NoteBodyLinkFormatter.attributedString(for: body)
        let linkedRuns = attributed.runs.compactMap { run -> (URL, Color?, Text.LineStyle?)? in
            guard let link = run.link else { return nil }
            return (link, run.foregroundColor, run.underlineStyle)
        }

        XCTAssertEqual(String(attributed.characters), body)
        XCTAssertEqual(
            linkedRuns.map(\.0),
            [
                try XCTUnwrap(URL(string: "https://example.com/path?q=One")),
                try XCTUnwrap(URL(string: "HTTP://example.org"))
            ]
        )
        for (_, foregroundColor, underlineStyle) in linkedRuns {
            XCTAssertEqual(foregroundColor, Color(nsColor: .linkColor))
            XCTAssertNotNil(underlineStyle)
        }
    }

    func testNoteBodyMarkupParsesInlineCodeAndLeavesUnclosedDelimiterLiteral() {
        XCTAssertEqual(
            NoteBodyMarkupParser.inlineSegments(in: "Run `swift test` now"),
            [.prose("Run "), .code("swift test"), .prose(" now")]
        )
        XCTAssertEqual(
            NoteBodyMarkupParser.inlineSegments(in: "Keep `unfinished text"),
            [.prose("Keep `unfinished text")]
        )
    }

    func testNoteBodyMarkupParsesFencedCodeAndOptionalLanguage() {
        let body = "Before\n```swift\nlet greeting = \"こんにちは 👋\"\n  print(greeting)\n```\nAfter"

        XCTAssertEqual(
            NoteBodyMarkupParser.blocks(in: body),
            [
                .prose("Before"),
                .code(
                    language: "swift",
                    text: "let greeting = \"こんにちは 👋\"\n  print(greeting)"
                ),
                .prose("After")
            ]
        )
    }

    func testNoteBodyMarkupLeavesUnclosedFenceLiteral() {
        let body = "Before\n```swift\nlet unfinished = true"

        XCTAssertEqual(NoteBodyMarkupParser.blocks(in: body), [.prose(body)])
    }

    func testNoteBodyFormattingLinksOnlyOutsideCode() throws {
        let body = "Visit https://example.com and run `curl https://inside.example`"
        let attributed = NoteBodyLinkFormatter.attributedString(for: body)
        let linkedRuns = attributed.runs.compactMap(\.link)
        let codeRuns = attributed.runs.filter { $0.font != nil && $0.backgroundColor != nil }

        XCTAssertEqual(
            String(attributed.characters),
            "Visit https://example.com and run curl https://inside.example"
        )
        XCTAssertEqual(linkedRuns, [try XCTUnwrap(URL(string: "https://example.com"))])
        XCTAssertEqual(codeRuns.count, 1)
        XCTAssertNil(codeRuns[0].link)
        XCTAssertEqual(codeRuns[0].foregroundColor, Color(nsColor: .systemRed))
    }

    func testNoteBodyMarkupPreservesFencedWhitespaceAndDoesNotLinkCodeBlock() {
        let body = "```\n  first\n\nhttps://inside.example\n```"

        XCTAssertEqual(
            NoteBodyMarkupParser.blocks(in: body),
            [.code(language: nil, text: "  first\n\nhttps://inside.example")]
        )
    }

    func testNoteBodyMarkupGroupsQuoteLinesAndLeavesQuotesInsideCodeLiteral() {
        let body = "Before\n> First `value`\n  > https://example.com\nAfter\n```\n> literal code\n```"

        XCTAssertEqual(
            NoteBodyMarkupParser.blocks(in: body),
            [
                .prose("Before"),
                .quote("First `value`\nhttps://example.com"),
                .prose("After"),
                .code(language: nil, text: "> literal code")
            ]
        )
    }

    func testComposerCodeSyntaxFindsInlineAndFencedRegions() {
        let body = "Use `value` here\n```swift\nlet value = `literal`\n```\nDone"
        let source = body as NSString

        XCTAssertEqual(
            ComposerCodeSyntaxParser.regions(in: body),
            [
                ComposerCodeRegion(
                    kind: .inline,
                    range: source.range(of: "`value`")
                ),
                ComposerCodeRegion(
                    kind: .fenced(isClosed: true),
                    range: source.range(of: "```swift\nlet value = `literal`\n```"),
                    markerRanges: [
                        source.range(of: "```swift"),
                        source.range(of: "```", options: [], range: NSRange(
                            location: source.range(of: "let value = `literal`").upperBound,
                            length: source.length
                                - source.range(of: "let value = `literal`").upperBound
                        ))
                    ]
                )
            ]
        )
    }

    func testComposerCodeSyntaxTreatsOpenFenceAsLiveCodeBlock() {
        let body = "Before\n```\nlet value = 1"
        let source = body as NSString

        XCTAssertEqual(
            ComposerCodeSyntaxParser.regions(in: body),
            [
                ComposerCodeRegion(
                    kind: .fenced(isClosed: false),
                    range: source.range(of: "```\nlet value = 1"),
                    markerRanges: [source.range(of: "```")]
                )
            ]
        )
    }

    func testComposerQuoteSyntaxGroupsLinesAndExcludesFencedCode() {
        let body = "> First\n  > Second\nPlain\n```\n> literal code\n```"
        let source = body as NSString
        let fencedRanges = ComposerCodeSyntaxParser.regions(in: body).compactMap { region in
            guard case .fenced = region.kind else { return nil }
            return region.range
        }

        XCTAssertEqual(
            ComposerQuoteSyntaxParser.regions(in: body, excluding: fencedRanges),
            [
                ComposerQuoteRegion(
                    range: source.range(of: "> First\n  > Second"),
                    markerRanges: [
                        source.range(of: "> "),
                        source.range(of: "  > ")
                    ]
                )
            ]
        )
    }

    func testComposerPasteRestoresStandardSlackEmojiFromHTML() {
        let html = """
        <span>Done <img alt=":white_check_mark:" data-stringify-emoji=":white_check_mark:" src="https://a.slack-edge.com/production-standard-emoji-assets/16.0/apple-medium/2705@2x.png"> <img data-stringify-emoji=":woman_technologist:" src="https://a.slack-edge.com/production-standard-emoji-assets/16.0/apple-medium/1f469-200d-1f4bb@2x.png"></span>
        """

        XCTAssertEqual(
            ComposerPasteboardText.emojiPreservingString(
                plainText: "Done :white_check_mark: :woman_technologist:",
                html: html
            ),
            "Done ✅ 👩‍💻"
        )
    }

    func testComposerPasteLeavesLiteralAndCustomShortcodesUnchanged() {
        XCTAssertEqual(
            ComposerPasteboardText.emojiPreservingString(
                plainText: ":white_check_mark:",
                html: "<span>:white_check_mark:</span>"
            ),
            ":white_check_mark:"
        )
        XCTAssertEqual(
            ComposerPasteboardText.emojiPreservingString(
                plainText: ":custom_party:",
                html: "<img data-stringify-emoji=\":custom_party:\" src=\"https://emoji.slack-edge.com/custom.png\">"
            ),
            ":custom_party:"
        )
    }

    func testComposerPasteContinuesQuoteAcrossIndentedAndBlankLines() {
        XCTAssertEqual(
            ComposerPasteboardText.continuingQuoteString(
                for: "First line\n    indented detail\n\nLast line"
            ),
            "First line\n>     indented detail\n> \n> Last line"
        )
        XCTAssertEqual(
            ComposerPasteboardText.continuingQuoteString(
                for: "First line\n> Already quoted"
            ),
            "First line\n> Already quoted"
        )
    }

    @MainActor
    func testComposerMarkupHighlighterAppliesLiveQuoteBlockAndCodeStyles() throws {
        let textView = NSTextView()
        textView.string = "> Quoted text\nUse `value`\n```\nlet value = 1"

        ComposerMarkupHighlighter.apply(to: textView)

        let source = textView.string as NSString
        let quoteLocation = source.range(of: "Quoted text").location
        let quoteMarkerLocation = source.range(of: "> ").location
        let inlineLocation = source.range(of: "`value`").location
        let blockLocation = source.range(of: "```\nlet value = 1").location
        let markerLocation = source.range(of: "```").location
        let quoteAttributes = try XCTUnwrap(textView.textStorage?.attributes(
            at: quoteLocation,
            effectiveRange: nil
        ))
        let quoteMarkerAttributes = try XCTUnwrap(textView.textStorage?.attributes(
            at: quoteMarkerLocation,
            effectiveRange: nil
        ))
        let inlineAttributes = try XCTUnwrap(textView.textStorage?.attributes(
            at: inlineLocation,
            effectiveRange: nil
        ))
        let blockAttributes = try XCTUnwrap(textView.textStorage?.attributes(
            at: blockLocation,
            effectiveRange: nil
        ))
        let markerAttributes = try XCTUnwrap(textView.textStorage?.attributes(
            at: markerLocation,
            effectiveRange: nil
        ))

        XCTAssertEqual(
            (quoteAttributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent,
            14
        )
        XCTAssertEqual(quoteMarkerAttributes[.foregroundColor] as? NSColor, .clear)
        XCTAssertEqual(inlineAttributes[.foregroundColor] as? NSColor, .systemRed)
        XCTAssertNotNil(blockAttributes[.font] as? NSFont)
        XCTAssertEqual(markerAttributes[.foregroundColor] as? NSColor, .clear)
        XCTAssertLessThan(try XCTUnwrap(markerAttributes[.font] as? NSFont).pointSize, 1)
    }

    @MainActor
    func testComposerQuoteMarkerKeepsAVisibleBodyLineHeight() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = "> "

        ComposerMarkupHighlighter.apply(to: textView)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 2),
            actualCharacterRange: nil
        )
        var lineHeight: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, _, _, _ in
            lineHeight = max(lineHeight, lineRect.height)
        }

        XCTAssertGreaterThanOrEqual(
            lineHeight,
            layoutManager.defaultLineHeight(for: .preferredFont(forTextStyle: .body))
        )
    }

    func testDetectionPreservesTextAndNormalizesOnlyRequestIdentity() throws {
        let body = "Keep HTTPS://Example.COM:443/a/../page?q=One#section exactly. Not ftp://example.com."
        let links = LinkDetector().links(in: body)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(
            links[0].originalURL,
            "HTTPS://Example.COM:443/a/../page?q=One#section"
        )
        XCTAssertEqual(links[0].requestKey, "https://example.com/page?q=One")
        XCTAssertEqual(body, "Keep HTTPS://Example.COM:443/a/../page?q=One#section exactly. Not ftp://example.com.")
    }

    func testAddressPolicyRejectsPrivateReservedMappedAndTransitionAddresses() {
        let unsafe: [ResolvedIPAddress] = [
            ipv4(127, 0, 0, 1),
            ipv4(10, 1, 2, 3),
            ipv4(100, 64, 0, 1),
            ipv4(169, 254, 1, 1),
            ipv4(172, 16, 0, 1),
            ipv4(192, 168, 1, 1),
            ipv4(198, 18, 0, 1),
            ipv4(224, 0, 0, 1),
            ipv6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1]),
            ipv6([0xfe, 0x80] + Array(repeating: 0, count: 14)),
            ipv6([0xfc] + Array(repeating: 0, count: 15)),
            ipv6([0xff] + Array(repeating: 0, count: 15)),
            ipv6([0x20, 0x01, 0x00, 0x02] + Array(repeating: 0, count: 12)),
            ipv6([0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 12)),
            ipv6([0x20, 0x02] + Array(repeating: 0, count: 14)),
            ipv6([0x3f, 0xff] + Array(repeating: 0, count: 14))
        ]
        for address in unsafe {
            XCTAssertFalse(LinkTargetValidator.isGloballyRoutable(address), "Unexpectedly allowed \(address)")
        }
        XCTAssertTrue(LinkTargetValidator.isGloballyRoutable(ipv4(8, 8, 8, 8)))
        XCTAssertTrue(LinkTargetValidator.isGloballyRoutable(
            ipv6([0x26, 0x06, 0x47, 0x00] + Array(repeating: 0, count: 12))
        ))
    }

    func testMixedSafeAndUnsafeDNSAnswersRejectEntireTarget() async throws {
        let resolver = StubResolver(addresses: [ipv4(8, 8, 8, 8), ipv4(10, 0, 0, 1)])
        let validator = LinkTargetValidator(resolver: resolver)

        do {
            try await validator.validate(try XCTUnwrap(URL(string: "https://public.example.net")), timeout: 1)
            XCTFail("Expected mixed DNS answers to be rejected")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .unsafeDestination)
        }
        XCTAssertEqual(resolver.requestCount, 1)
    }

    func testLocalHostnameIsRejectedBeforeDNS() async throws {
        let resolver = StubResolver(addresses: [ipv4(8, 8, 8, 8)])
        let validator = LinkTargetValidator(resolver: resolver)

        do {
            try await validator.validate(try XCTUnwrap(URL(string: "http://printer.local/status")), timeout: 1)
            XCTFail("Expected local hostname to be rejected")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .unsafeDestination)
        }
        XCTAssertEqual(resolver.requestCount, 0)

        do {
            try await validator.validate(try XCTUnwrap(URL(string: "https://home.arpa")), timeout: 1)
            XCTFail("Expected home.arpa to be rejected")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .unsafeDestination)
        }
        XCTAssertEqual(resolver.requestCount, 0)
    }

    func testParserUsesOpenGraphAndSanitizesMetadata() throws {
        let html = """
            <html><head>
            <meta property="og:title" content="Launch &amp; Learn">
            <meta property='og:description' content='A   useful\n description'>
            <meta property="og:site_name" content="Example&#33;">
            <meta property="og:image" content="/card.png">
            <link rel="icon" href="/favicon.png">
            <title>Ignored fallback</title>
            </head></html>
            """
        let parsed = HTMLLinkPreviewParser().parse(
            data: Data(html.utf8),
            baseURL: try XCTUnwrap(URL(string: "https://example.com/articles/one"))
        )

        XCTAssertEqual(parsed.title, "Launch & Learn")
        XCTAssertEqual(parsed.summary, "A useful description")
        XCTAssertEqual(parsed.siteName, "Example!")
        XCTAssertEqual(
            parsed.imageCandidates.map(\.absoluteString),
            ["https://example.com/card.png", "https://example.com/favicon.png"]
        )
    }

    func testParserFallsBackToTitleDescriptionHostAndFavicon() throws {
        let html = "<title>Fallback &lt;Title&gt;</title><meta name=description content='Plain summary'>"
        let parsed = HTMLLinkPreviewParser().parse(
            data: Data(html.utf8),
            baseURL: try XCTUnwrap(URL(string: "https://fallback.example.org/path"))
        )

        XCTAssertEqual(parsed.title, "Fallback")
        XCTAssertEqual(parsed.summary, "Plain summary")
        XCTAssertEqual(parsed.siteName, "fallback.example.org")
        XCTAssertEqual(parsed.imageCandidates.map(\.absoluteString), ["https://fallback.example.org/favicon.ico"])
    }

    func testMalformedHTMLFallsBackWithoutThrowingOrExecutingContent() throws {
        let html = "<script>document.title='unsafe'</script><title>Safe < broken<meta name=description content='Fallback'>"
        let parsed = HTMLLinkPreviewParser().parse(
            data: Data(html.utf8),
            baseURL: try XCTUnwrap(URL(string: "https://malformed.example.org/path"))
        )

        XCTAssertEqual(parsed.title, "malformed.example.org")
        XCTAssertEqual(parsed.siteName, "malformed.example.org")
        XCTAssertEqual(parsed.imageCandidates.map(\.absoluteString), ["https://malformed.example.org/favicon.ico"])
    }

    func testMigrationDefaultsOffAndPersistsPreviewStatusSearchAndRemoval() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(try fixture.database.automaticLinkPreviewsEnabled())

        let body = "Exact note https://example.net/path?keep=Yes"
        let note = try fixture.database.createNote(body: body)
        let snapshot = try XCTUnwrap(
            fixture.database.fetchLinkReconciliationSnapshot(noteID: note.id)
        )
        let result = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        XCTAssertTrue(result.wasApplied)

        var stored = try fixture.database.fetchNote(id: note.id)
        XCTAssertEqual(stored.body, body)
        let pending = try XCTUnwrap(stored.linkPreviews.first)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(
            try fixture.database.searchNotes(NoteSearchRequest(
                text: "",
                filters: NoteSearchFilters(hasLink: true),
                sort: .newest
            )).results.map(\.id),
            [note.id]
        )

        try fixture.database.setAutomaticLinkPreviewsEnabled(true)
        let metadata = LinkPreviewMetadata(
            canonicalURL: "https://example.net/path?keep=Yes",
            title: "Indexed Preview Launch",
            summary: "Summary with 🚀",
            imageURL: nil,
            siteName: "Example Site",
            imagePNGData: nil
        )
        let commit = try fixture.database.commitLinkPreviewMetadata(
            requestKey: pending.requestKey,
            metadata: metadata,
            localImageFilename: nil
        )
        XCTAssertEqual(commit.changedNoteIDs, [note.id])
        stored = try fixture.database.fetchNote(id: note.id)
        XCTAssertEqual(stored.linkPreviews.first?.status, .ready)
        XCTAssertEqual(stored.linkPreviews.first?.title, "Indexed Preview Launch")
        XCTAssertEqual(
            try fixture.database.searchNotes(NoteSearchRequest(
                text: "Indexed Preview",
                filters: NoteSearchFilters(),
                sort: .relevance
            )).results.map(\.id),
            [note.id]
        )
        XCTAssertEqual(
            try fixture.database.searchNotes(NoteSearchRequest(
                text: "🚀",
                filters: NoteSearchFilters(),
                sort: .relevance
            )).results.map(\.id),
            [note.id]
        )

        let removal = try fixture.database.removeLinkPreview(id: pending.id)
        XCTAssertEqual(removal.changedNoteID, note.id)
        stored = try fixture.database.fetchNote(id: note.id)
        XCTAssertEqual(stored.body, body)
        XCTAssertEqual(stored.linkPreviews.first?.status, .removed)
        XCTAssertEqual(
            try fixture.database.searchNotes(NoteSearchRequest(
                text: "",
                filters: NoteSearchFilters(hasLink: true),
                sort: .newest
            )).results.map(\.id),
            [note.id]
        )
    }

    func testReconciliationRejectsStaleBodyAndReaddingEditedAwayURLClearsSuppression() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let note = try fixture.database.createNote(body: "https://example.net/one")
        let oldSnapshot = try XCTUnwrap(fixture.database.fetchLinkReconciliationSnapshot(noteID: note.id))
        let oldLinks = LinkDetector().links(in: oldSnapshot.body)
        _ = try fixture.database.editNote(id: note.id, body: "A newer body without a link")
        XCTAssertFalse(try fixture.database.reconcileLinkPreviews(
            snapshot: oldSnapshot,
            detectedLinks: oldLinks
        ).wasApplied)

        var snapshot = try XCTUnwrap(fixture.database.fetchLinkReconciliationSnapshot(noteID: note.id))
        _ = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        XCTAssertTrue(try fixture.database.fetchNote(id: note.id).linkPreviews.isEmpty)

        _ = try fixture.database.editNote(id: note.id, body: "Again https://example.net/one")
        snapshot = try XCTUnwrap(fixture.database.fetchLinkReconciliationSnapshot(noteID: note.id))
        _ = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        XCTAssertEqual(try fixture.database.fetchNote(id: note.id).linkPreviews.first?.status, .pending)
    }

    func testBodyEditTransactionMakesPersistedAssociationsIneligibleAcrossRelaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: root)
        try provider.prepare()
        var database: AppDatabase? = try AppDatabase(databaseURL: provider.databaseURL)
        let note = try XCTUnwrap(database).createNote(body: "https://example.net/stale")
        let snapshot = try XCTUnwrap(
            try database?.fetchLinkReconciliationSnapshot(noteID: note.id)
        )
        _ = try database?.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        try database?.setAutomaticLinkPreviewsEnabled(true)

        _ = try database?.editNote(id: note.id, body: "The URL is gone")
        XCTAssertTrue(try XCTUnwrap(database).fetchNote(id: note.id).linkPreviews.isEmpty)
        XCTAssertTrue(try XCTUnwrap(database).fetchLinkPreviewWork(
            fetchBefore: Date(),
            excludingRequestKeys: []
        ).isEmpty)
        XCTAssertFalse(try XCTUnwrap(database).hasEligibleLinkPreviewWork(
            requestKey: "https://example.net/stale"
        ))
        try database?.close()
        database = nil

        let reopened = try AppDatabase(databaseURL: provider.databaseURL)
        defer { try? reopened.close() }
        let fetcher = RecordingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: provider,
            database: reopened,
            fetcher: fetcher
        )
        XCTAssertTrue((await coordinator.start()).automaticFetchingEnabled)
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertTrue(try reopened.fetchNote(id: note.id).linkPreviews.isEmpty)
    }

    func testOptInCannotBypassPausedStartupReconciliation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.database.createNote(body: "https://example.net/startup-gate")
        let gate = TestGate()
        let fetcher = RecordingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher,
            startupCheckpoint: { _ in await gate.wait() }
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await gate.isWaiting }

        try await coordinator.setAutomaticFetchingEnabled(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertFalse(await coordinator.startupReconciliationComplete)

        await gate.open()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }
        try await waitUntil { fetcher.requestCount == 1 }
    }

    func testQueueSlotOpeningAfterEditCannotFetchStaleFifthURL() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let fetcher = SlotMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }
        try await coordinator.setAutomaticFetchingEnabled(true)

        let links = (1...5).map { "https://example.net/slot/\($0)" }
        let note = try fixture.database.createNote(body: links.joined(separator: " "))
        await coordinator.reconcileNote(id: note.id)
        try await waitUntil { fetcher.requestCount == LinkPreviewCoordinator.maximumConcurrentFetches }

        _ = try fixture.database.editNote(
            id: note.id,
            body: links.prefix(4).joined(separator: " ")
        )
        fetcher.releaseOne()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fetcher.requestCount, 4)
        XCTAssertFalse(fetcher.requestedURLs.contains(links[4]))

        try await coordinator.setAutomaticFetchingEnabled(false)
        fetcher.releaseAll()
    }

    func testCoordinatorEditAfterEligibilityCheckPreventsFetchInvocation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let checkpoint = TestGate()
        let fetcher = RecordingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher,
            preFetchCheckpoint: { _ in await checkpoint.wait() }
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }

        let requestKey = "https://example.net/validated-before-edit"
        let note = try fixture.database.createNote(body: requestKey)
        await coordinator.reconcileNote(id: note.id)
        try await coordinator.setAutomaticFetchingEnabled(true)
        try await waitUntilAsync { await checkpoint.isWaiting }

        let updated = try await coordinator.editNote(
            id: note.id,
            body: "The link was removed before fetch invocation"
        )
        XCTAssertEqual(updated.body, "The link was removed before fetch invocation")
        XCTAssertTrue(updated.linkPreviews.isEmpty)
        await checkpoint.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertFalse(try fixture.database.hasEligibleLinkPreviewWork(
            requestKey: requestKey
        ))
    }

    func testRestorePauseRejectsPreviewMutationsUntilExplicitResume() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: RecordingMetadataFetcher()
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }

        let note = try fixture.database.createNote(body: "https://example.net/restore-pause")
        await coordinator.reconcileNote(id: note.id)
        let preview = try XCTUnwrap(
            fixture.database.fetchNote(id: note.id).linkPreviews.first
        )
        await coordinator.pauseBackgroundWork()

        do {
            _ = try await coordinator.editNote(id: note.id, body: "must not be written")
            XCTFail("Expected restore mutation pause")
        } catch {
            XCTAssertEqual(
                error as? LinkPreviewCoordinatorError,
                .mutationsPausedForRestore
            )
        }
        do {
            try await coordinator.remove(previewID: preview.id)
            XCTFail("Expected restore mutation pause")
        } catch {
            XCTAssertEqual(
                error as? LinkPreviewCoordinatorError,
                .mutationsPausedForRestore
            )
        }
        XCTAssertEqual(try fixture.database.fetchNote(id: note.id).body, note.body)
        XCTAssertEqual(
            try fixture.database.fetchNote(id: note.id).linkPreviews.first?.status,
            .pending
        )

        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }
        _ = try await coordinator.editNote(id: note.id, body: "written after safe resume")
        XCTAssertEqual(
            try fixture.database.fetchNote(id: note.id).body,
            "written after safe resume"
        )
    }

    func testPauseAndResumeDoesNotRepeatCompletedStartupReconciliation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.database.createNote(body: "https://example.net/completed-pause")
        let checkpointCount = ThreadSafeCounter()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: RecordingMetadataFetcher(),
            startupCheckpoint: { _ in checkpointCount.increment() }
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }
        let completedCount = checkpointCount.value

        await coordinator.pauseBackgroundWork()
        await coordinator.resumeBackgroundWork()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(checkpointCount.value, completedCount)
        XCTAssertTrue(await coordinator.startupReconciliationComplete)
    }

    func testPauseAndResumeRestartsCanceledStartupReconciliation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.database.createNote(body: "https://example.net/canceled-pause")
        let gate = TestGate()
        let checkpointCount = ThreadSafeCounter()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: RecordingMetadataFetcher(),
            startupCheckpoint: { _ in
                checkpointCount.increment()
                await gate.wait()
            }
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await gate.isWaiting }

        let pause = Task { await coordinator.pauseBackgroundWork() }
        await gate.open()
        await pause.value
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }

        XCTAssertEqual(checkpointCount.value, 2)
    }

    func testSharedRefreshBackoffIsInheritedByNewAssociation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let requestKey = "https://example.net/shared-backoff"
        let first = try fixture.database.createNote(body: requestKey)
        var snapshot = try XCTUnwrap(
            fixture.database.fetchLinkReconciliationSnapshot(noteID: first.id)
        )
        _ = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        try fixture.database.setAutomaticLinkPreviewsEnabled(true)
        let now = Date()
        _ = try fixture.database.commitLinkPreviewMetadata(
            requestKey: requestKey,
            metadata: LinkPreviewMetadata(
                canonicalURL: requestKey,
                title: "Cached",
                summary: nil,
                imageURL: nil,
                siteName: "Example",
                imagePNGData: nil
            ),
            localImageFilename: nil,
            fetchedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        _ = try fixture.database.markLinkPreviewFailure(
            requestKey: requestKey,
            reason: "refresh failed",
            now: now
        )

        let second = try fixture.database.createNote(body: requestKey)
        snapshot = try XCTUnwrap(
            fixture.database.fetchLinkReconciliationSnapshot(noteID: second.id)
        )
        _ = try fixture.database.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body),
            now: now
        )
        XCTAssertTrue(try fixture.database.fetchLinkPreviewWork(
            fetchBefore: now.addingTimeInterval(23 * 60 * 60),
            excludingRequestKeys: []
        ).isEmpty)
        XCTAssertEqual(try fixture.database.fetchLinkPreviewWork(
            fetchBefore: now.addingTimeInterval(25 * 60 * 60),
            excludingRequestKeys: []
        ).map(\.requestKey), [requestKey])
    }

    func testPreviewMaintenanceTouchesOnlyGeneratedRegularPNGFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let fileManager = FileManager()
        let orphan = fixture.provider.previewsURL.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).png"
        )
        let invalid = fixture.provider.previewsURL.appendingPathComponent("keep.txt")
        let target = fixture.rootURL.appendingPathComponent("target.png")
        let symlink = fixture.provider.previewsURL.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).png"
        )
        try Data("orphan".utf8).write(to: orphan)
        try Data("invalid".utf8).write(to: invalid)
        try Data("target".utf8).write(to: target)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: target)

        let store = LinkPreviewImageStore(
            provider: fixture.provider,
            database: fixture.database,
            fileManager: fileManager
        )
        XCTAssertTrue(try store.performStartupMaintenance().isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: orphan.path))
        XCTAssertTrue(fileManager.fileExists(atPath: invalid.path))
        XCTAssertTrue(fileManager.fileExists(atPath: symlink.path))
        XCTAssertNil(store.imageURL(filename: invalid.lastPathComponent))
        XCTAssertNil(store.imageURL(filename: symlink.lastPathComponent))
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
    }

    func testPendingWorkAndDisabledSettingSurviveReopenWithoutNetwork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ApplicationSupportDirectoryProvider(rootURL: root)
        try provider.prepare()
        var database: AppDatabase? = try AppDatabase(databaseURL: provider.databaseURL)
        let note = try XCTUnwrap(database).createNote(body: "https://example.net/relaunch")
        let snapshot = try XCTUnwrap(try database?.fetchLinkReconciliationSnapshot(noteID: note.id))
        _ = try database?.reconcileLinkPreviews(
            snapshot: snapshot,
            detectedLinks: LinkDetector().links(in: snapshot.body)
        )
        try database?.close()
        database = nil

        let reopened = try AppDatabase(databaseURL: provider.databaseURL)
        defer { try? reopened.close() }
        let fetcher = RecordingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: provider,
            database: reopened,
            fetcher: fetcher
        )
        let startup = await coordinator.start()
        XCTAssertFalse(startup.automaticFetchingEnabled)
        await coordinator.resumeBackgroundWork()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertEqual(try reopened.fetchNote(id: note.id).linkPreviews.first?.status, .pending)
    }

    func testCoordinatorFetchesAfterOptInAndReusesFreshCache() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let fetcher = RecordingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher
        )
        let startup = await coordinator.start()
        XCTAssertFalse(startup.automaticFetchingEnabled)
        await coordinator.resumeBackgroundWork()

        let first = try fixture.database.createNote(body: "https://example.net/shared")
        await coordinator.reconcileNote(id: first.id)
        XCTAssertEqual(fetcher.requestCount, 0)
        try await coordinator.setAutomaticFetchingEnabled(true)
        try await waitUntil {
            try fixture.database.fetchNote(id: first.id).linkPreviews.first?.status == .ready
        }
        XCTAssertEqual(fetcher.requestCount, 1)

        let second = try fixture.database.createNote(body: "Duplicate https://example.net/shared")
        await coordinator.reconcileNote(id: second.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try fixture.database.fetchNote(id: second.id).linkPreviews.first?.status, .ready)
        XCTAssertEqual(fetcher.requestCount, 1)
    }

    func testTurningSettingOffCancelsInflightFetch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let fetcher = BlockingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        let note = try fixture.database.createNote(body: "https://example.net/slow")
        await coordinator.reconcileNote(id: note.id)
        try await coordinator.setAutomaticFetchingEnabled(true)
        try await waitUntil { fetcher.didStart }
        try await coordinator.setAutomaticFetchingEnabled(false)
        try await waitUntil { fetcher.wasCancelled }
        XCTAssertFalse(try fixture.database.automaticLinkPreviewsEnabled())
        XCTAssertEqual(try fixture.database.fetchNote(id: note.id).linkPreviews.first?.status, .pending)
    }

    func testFailedDisableStaysRuntimeOffAndCanRetryPersistenceInSameSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let fetcher = RecordingMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        try await waitUntilAsync { await coordinator.startupReconciliationComplete }
        try await coordinator.setAutomaticFetchingEnabled(true)

        let external = try DatabaseQueue(path: fixture.provider.databaseURL.path)
        defer { try? external.close() }
        try external.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_link_preview_disable
                BEFORE UPDATE OF automaticLinkPreviewsEnabled ON app_settings
                WHEN new.automaticLinkPreviewsEnabled = 0
                BEGIN
                    SELECT RAISE(ABORT, 'forced durable setting failure');
                END;
                """)
        }
        do {
            try await coordinator.setAutomaticFetchingEnabled(false)
            XCTFail("Expected durable setting failure")
        } catch { }

        let note = try fixture.database.createNote(body: "https://example.net/remains-off")
        await coordinator.reconcileNote(id: note.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertTrue(try fixture.database.automaticLinkPreviewsEnabled())

        try external.write { database in
            try database.execute(sql: "DROP TRIGGER fail_link_preview_disable")
        }
        try await coordinator.setAutomaticFetchingEnabled(false)
        XCTAssertFalse(try fixture.database.automaticLinkPreviewsEnabled())
    }

    func testStartupReconciliationFailureWarnsAndRemainsFailClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.database.createNote(body: "https://example.net/startup-failure")
        try fixture.database.setAutomaticLinkPreviewsEnabled(true)
        let fetcher = RecordingMetadataFetcher()
        let warning = ThreadSafeString()
        let checkpointCount = ThreadSafeCounter()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher,
            startupCheckpoint: { _ in
                checkpointCount.increment()
                throw LinkPreviewNetworkError.transportFailed
            }
        )
        await coordinator.setWarningHandler { message in warning.set(message) }
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()

        try await waitUntil { warning.value != nil }
        XCTAssertFalse(await coordinator.startupReconciliationComplete)
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertTrue(warning.value?.contains("remains paused") == true)

        await coordinator.pauseBackgroundWork()
        await coordinator.resumeBackgroundWork()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertFalse(await coordinator.startupReconciliationComplete)
        XCTAssertEqual(checkpointCount.value, 1)
    }

    func testCanceledOrdinaryFailureCannotMutateWorkAfterReenable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let fetcher = NonCooperativeMetadataFetcher()
        let coordinator = LinkPreviewCoordinator(
            provider: fixture.provider,
            database: fixture.database,
            fetcher: fetcher
        )
        _ = await coordinator.start()
        await coordinator.resumeBackgroundWork()
        let note = try fixture.database.createNote(body: "https://example.net/re-enabled")
        await coordinator.reconcileNote(id: note.id)
        try await coordinator.setAutomaticFetchingEnabled(true)
        try await waitUntil { fetcher.firstRequestIsWaiting }

        try await coordinator.setAutomaticFetchingEnabled(false)
        try await coordinator.setAutomaticFetchingEnabled(true)
        fetcher.failFirstRequest()

        try await waitUntil {
            try fixture.database.fetchNote(id: note.id).linkPreviews.first?.status == .ready
        }
        XCTAssertEqual(fetcher.requestCount, 2)
    }

    func testStreamingClientOmitsCookiesCredentialsAndRejectsOversizedBody() async throws {
        let resolver = StubResolver(addresses: [ipv4(93, 184, 216, 34)])
        StubURLProtocol.setHandler { request, protocolInstance in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )!
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                didLoad: Data(repeating: 65, count: 33)
            )
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let client = LinkPreviewHTTPClient(
            resolver: resolver,
            protocolClasses: [StubURLProtocol.self]
        )
        do {
            _ = try await client.fetch(LinkPreviewHTTPRequest(
                url: try XCTUnwrap(URL(string: "https://example.net/large")),
                acceptedContentTypes: ["text/html"],
                maximumBytes: 32,
                timeout: 1
            ))
            XCTFail("Expected streamed body limit failure")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .responseTooLarge)
        }
    }

    func testRedirectToPrivateTargetIsRejectedBeforeSecondRequest() async throws {
        let resolver = StubResolver(addresses: [ipv4(93, 184, 216, 34)])
        StubURLProtocol.setHandler { request, protocolInstance in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "http://127.0.0.1/private"]
            )!
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                wasRedirectedTo: URLRequest(url: URL(string: "http://127.0.0.1/private")!),
                redirectResponse: response
            )
        }
        let client = LinkPreviewHTTPClient(
            resolver: resolver,
            protocolClasses: [StubURLProtocol.self]
        )
        do {
            _ = try await client.fetch(LinkPreviewHTTPRequest(
                url: try XCTUnwrap(URL(string: "https://example.net/redirect")),
                acceptedContentTypes: ["text/html"],
                maximumBytes: 1_024,
                timeout: 1
            ))
            XCTFail("Expected private redirect rejection")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .unsafeDestination)
        }
        XCTAssertEqual(resolver.requestCount, 1)
    }

    func testAlreadyCanceledFetchDoesNotResolveOrStartURLProtocol() async throws {
        let resolver = StubResolver(addresses: [ipv4(93, 184, 216, 34)])
        let client = LinkPreviewHTTPClient(
            resolver: resolver,
            protocolClasses: [StubURLProtocol.self]
        )
        let gate = TestGate()
        StubURLProtocol.setHandler { _, _ in }
        let task = Task {
            await gate.wait()
            return try await client.fetch(LinkPreviewHTTPRequest(
                url: URL(string: "https://example.net/canceled")!,
                acceptedContentTypes: ["text/html"],
                maximumBytes: 1_024,
                timeout: 1
            ))
        }
        while !(await gate.isWaiting) { await Task.yield() }
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(resolver.requestCount, 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testCancellationBeforeContinuationPublicationCannotHang() async throws {
        let resolver = StubResolver(addresses: [ipv4(93, 184, 216, 34)])
        let gate = SynchronousCheckpointGate()
        StubURLProtocol.setHandler { _, _ in }
        let client = LinkPreviewHTTPClient(
            resolver: resolver,
            protocolClasses: [StubURLProtocol.self],
            beforeContinuationRegistration: { gate.wait() }
        )
        let task = Task {
            try await client.fetch(LinkPreviewHTTPRequest(
                url: URL(string: "https://example.net/pre-publication")!,
                acceptedContentTypes: ["text/html"],
                maximumBytes: 1_024,
                timeout: 2
            ))
        }
        try await waitUntil { gate.isWaiting }
        task.cancel()
        gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testDNSSDQueueAssociatedCancellationCleansUpOnCallbackQueue() async throws {
        let lifecycle = DNSLifecycleProbe()
        let resolver = SystemLinkPreviewHostResolver(lifecycleHooks: DNSResolutionLifecycleHooks(
            didAssociateQueue: { lifecycle.didAssociate() },
            didCleanUpOnQueue: { lifecycle.didCleanUp() }
        ))
        let task = Task {
            try await resolver.resolve(host: "localhost", timeout: 1)
        }
        try await waitUntil { lifecycle.associationCount == 1 }
        task.cancel()
        _ = try? await task.value
        try await waitUntil { lifecycle.cleanupCount == 1 }
        XCTAssertEqual(lifecycle.associationCount, lifecycle.cleanupCount)

        for _ in 0..<50 {
            let operation = Task {
                try await resolver.resolve(host: "localhost", timeout: 0.2)
            }
            await Task.yield()
            operation.cancel()
            _ = try? await operation.value
        }
        try await waitUntil(timeout: 5) {
            lifecycle.cleanupCount == lifecycle.associationCount
        }
    }

    func testTimeoutUnsupportedContentAndRedirectLimitAreDeterministic() async throws {
        let resolver = StubResolver(addresses: [ipv4(93, 184, 216, 34)])
        let client = LinkPreviewHTTPClient(
            resolver: resolver,
            protocolClasses: [StubURLProtocol.self]
        )
        let request = { (path: String, timeout: TimeInterval) in
            LinkPreviewHTTPRequest(
                url: URL(string: "https://example.net/\(path)")!,
                acceptedContentTypes: ["text/html"],
                maximumBytes: 1_024,
                timeout: timeout
            )
        }

        StubURLProtocol.setHandler { _, _ in }
        do {
            _ = try await client.fetch(request("timeout", 0.1))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .timedOut)
        }

        StubURLProtocol.setHandler { request, protocolInstance in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )!
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
        }
        do {
            _ = try await client.fetch(request("binary", 1))
            XCTFail("Expected content-type rejection")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .unacceptableResponse)
        }

        StubURLProtocol.setHandler { request, protocolInstance in
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.query = "redirect=\(UUID().uuidString)"
            let redirected = components.url!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirected.absoluteString]
            )!
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                wasRedirectedTo: URLRequest(url: redirected),
                redirectResponse: response
            )
        }
        do {
            _ = try await client.fetch(request("loop", 2))
            XCTFail("Expected redirect limit")
        } catch {
            XCTAssertEqual(error as? LinkPreviewNetworkError, .tooManyRedirects)
        }
    }

    private func makeFixture() throws -> LinkPreviewFixture {
        let root = temporaryRoot()
        let provider = ApplicationSupportDirectoryProvider(rootURL: root)
        try provider.prepare()
        return LinkPreviewFixture(
            rootURL: root,
            provider: provider,
            database: try AppDatabase(databaseURL: provider.databaseURL)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfDMNotesLinkPreviewTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Condition did not become true before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            guard Date() < deadline else {
                XCTFail("Async condition did not become true before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func ipv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> ResolvedIPAddress {
        ResolvedIPAddress(family: .ipv4, bytes: [a, b, c, d])
    }

    private func ipv6(_ bytes: [UInt8]) -> ResolvedIPAddress {
        ResolvedIPAddress(family: .ipv6, bytes: bytes)
    }
}

private struct LinkPreviewFixture {
    let rootURL: URL
    let provider: ApplicationSupportDirectoryProvider
    let database: AppDatabase

    func cleanUp() {
        try? database.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class StubResolver: LinkPreviewHostResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let addresses: [ResolvedIPAddress]
    private var count = 0

    init(addresses: [ResolvedIPAddress]) {
        self.addresses = addresses
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func resolve(host: String, timeout: TimeInterval) async throws -> [ResolvedIPAddress] {
        lock.withLock { count += 1 }
        return addresses
    }
}

private final class RecordingMetadataFetcher: LinkPreviewMetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    func fetchPreview(for url: URL) async throws -> LinkPreviewMetadata {
        lock.withLock { count += 1 }
        return LinkPreviewMetadata(
            canonicalURL: url.absoluteString,
            title: "Fetched preview",
            summary: "Deterministic metadata",
            imageURL: nil,
            siteName: "Example",
            imagePNGData: nil
        )
    }
}

private final class SlotMetadataFetcher: LinkPreviewMetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var requestCount: Int { lock.withLock { requests.count } }
    var requestedURLs: Set<String> { lock.withLock { Set(requests) } }

    func releaseOne() {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }

    func releaseAll() {
        let pending = lock.withLock {
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }

    func fetchPreview(for url: URL) async throws -> LinkPreviewMetadata {
        await withCheckedContinuation { continuation in
            lock.withLock {
                requests.append(url.absoluteString)
                continuations.append(continuation)
            }
        }
        return LinkPreviewMetadata(
            canonicalURL: url.absoluteString,
            title: "Slot",
            summary: nil,
            imageURL: nil,
            siteName: "Example",
            imagePNGData: nil
        )
    }
}

private final class ThreadSafeString: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? { lock.withLock { storedValue } }
    func set(_ value: String) { lock.withLock { storedValue = value } }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class SynchronousCheckpointGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var waiting = false

    var isWaiting: Bool { lock.withLock { waiting } }

    func wait() {
        lock.withLock { waiting = true }
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}

private final class DNSLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var associations = 0
    private var cleanups = 0

    var associationCount: Int { lock.withLock { associations } }
    var cleanupCount: Int { lock.withLock { cleanups } }
    func didAssociate() { lock.withLock { associations += 1 } }
    func didCleanUp() { lock.withLock { cleanups += 1 } }
}

private final class BlockingMetadataFetcher: LinkPreviewMetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    var didStart: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func fetchPreview(for url: URL) async throws -> LinkPreviewMetadata {
        lock.withLock { started = true }
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw LinkPreviewNetworkError.timedOut
        } catch is CancellationError {
            lock.withLock { cancelled = true }
            throw CancellationError()
        }
    }
}

private final class NonCooperativeMetadataFetcher: LinkPreviewMetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    var requestCount: Int { lock.withLock { count } }
    var firstRequestIsWaiting: Bool { lock.withLock { firstContinuation != nil } }

    func failFirstRequest() {
        let continuation = lock.withLock {
            let continuation = firstContinuation
            firstContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func fetchPreview(for url: URL) async throws -> LinkPreviewMetadata {
        let requestNumber = lock.withLock {
            count += 1
            return count
        }
        if requestNumber == 1 {
            await withCheckedContinuation { continuation in
                lock.withLock { firstContinuation = continuation }
            }
            throw LinkPreviewNetworkError.transportFailed
        }
        return LinkPreviewMetadata(
            canonicalURL: url.absoluteString,
            title: "New operation",
            summary: nil,
            imageURL: nil,
            siteName: "Example",
            imagePNGData: nil
        )
    }
}

private actor TestGate {
    private(set) var isWaiting = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, StubURLProtocol) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func setHandler(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            count = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.count += 1
            return Self.handler
        }
        handler?(request, self)
    }

    override func stopLoading() { }
}
