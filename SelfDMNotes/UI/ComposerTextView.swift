import AppKit
import SwiftUI

struct ComposerCodeRegion: Equatable {
    enum Kind: Equatable {
        case inline
        case fenced(isClosed: Bool)
    }

    let kind: Kind
    let range: NSRange
    let markerRanges: [NSRange]

    init(kind: Kind, range: NSRange, markerRanges: [NSRange] = []) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
    }
}

struct ComposerQuoteRegion: Equatable {
    let range: NSRange
    let markerRanges: [NSRange]
}

struct ComposerTextEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selectionAfterEdit: NSRange?

    init(
        range: NSRange,
        replacement: String,
        selectionAfterEdit: NSRange? = nil
    ) {
        self.range = range
        self.replacement = replacement
        self.selectionAfterEdit = selectionAfterEdit
    }
}

struct ComposerListDrawingItem: Equatable {
    let range: NSRange
    let marker: String
    let depth: Int
}

enum ComposerCodeSyntaxParser {
    static func regions(in text: String) -> [ComposerCodeRegion] {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var fencedRegions: [ComposerCodeRegion] = []
        var openFenceLocation: Int?
        var openMarkerRange: NSRange?
        var position = 0

        while position < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: position, length: 0)
            )
            let line = source.substring(
                with: NSRange(location: lineStart, length: contentsEnd - lineStart)
            )
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if let openingLocation = openFenceLocation {
                if trimmedLine == "```" {
                    fencedRegions.append(
                        ComposerCodeRegion(
                            kind: .fenced(isClosed: true),
                            range: NSRange(
                                location: openingLocation,
                                length: contentsEnd - openingLocation
                            ),
                            markerRanges: [
                                openMarkerRange,
                                NSRange(
                                    location: lineStart,
                                    length: contentsEnd - lineStart
                                )
                            ].compactMap { $0 }
                        )
                    )
                    openFenceLocation = nil
                    openMarkerRange = nil
                }
            } else if let markerLength = openingFenceMarkerLength(in: line) {
                openFenceLocation = lineStart
                openMarkerRange = NSRange(
                    location: lineStart,
                    length: markerLength
                )
            }
            position = lineEnd
        }

        if let openingLocation = openFenceLocation {
            fencedRegions.append(
                ComposerCodeRegion(
                    kind: .fenced(isClosed: false),
                    range: NSRange(
                        location: openingLocation,
                        length: source.length - openingLocation
                    ),
                    markerRanges: [openMarkerRange].compactMap { $0 }
                )
            )
        }

        let inlineRegions = inlineExpression.matches(
            in: text,
            range: fullRange
        ).compactMap { match -> ComposerCodeRegion? in
            guard !fencedRegions.contains(where: { rangesOverlap($0.range, match.range) }) else {
                return nil
            }
            return ComposerCodeRegion(kind: .inline, range: match.range)
        }
        return (fencedRegions + inlineRegions).sorted { $0.range.location < $1.range.location }
    }

    private static let inlineExpression = try! NSRegularExpression(
        pattern: #"(?<!`)`[^`\r\n]+`(?!`)"#
    )

    private static func openingFenceMarkerLength(in line: String) -> Int? {
        guard let markerStart = line.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        let fenceAndContent = line[markerStart...]
        guard fenceAndContent.hasPrefix("```") else {
            return nil
        }
        return line[..<markerStart].utf16.count + 3
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }
}

enum ComposerCodeEditing {
    static func returnEdit(
        in text: String,
        selectedRange: NSRange
    ) -> ComposerTextEdit? {
        let source = text as NSString
        guard selectedRange.length == 0,
              selectedRange.location == source.length,
              let region = ComposerCodeSyntaxParser.regions(in: text).last,
              case .fenced(isClosed: false) = region.kind,
              NSMaxRange(region.range) == source.length else {
            return nil
        }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        source.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: selectedRange
        )
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        guard source.substring(with: lineRange)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty else {
            return nil
        }

        return ComposerTextEdit(
            range: lineRange,
            replacement: "```\n",
            selectionAfterEdit: NSRange(location: lineStart + 4, length: 0)
        )
    }
}

enum ComposerQuoteSyntaxParser {
    static func regions(
        in text: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [ComposerQuoteRegion] {
        let source = text as NSString
        var regions: [ComposerQuoteRegion] = []
        var regionStart: Int?
        var regionEnd: Int?
        var markerRanges: [NSRange] = []
        var position = 0

        func appendRegion() {
            guard let regionStart, let regionEnd else { return }
            regions.append(
                ComposerQuoteRegion(
                    range: NSRange(location: regionStart, length: regionEnd - regionStart),
                    markerRanges: markerRanges
                )
            )
        }

        while position < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: position, length: 0)
            )
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let isExcluded = excludedRanges.contains {
                NSIntersectionRange($0, lineRange).length > 0
            }

            if !isExcluded, let markerRange = quoteMarkerRange(in: source, lineRange: lineRange) {
                if regionStart == nil {
                    regionStart = lineStart
                }
                regionEnd = contentsEnd
                markerRanges.append(markerRange)
            } else {
                appendRegion()
                regionStart = nil
                regionEnd = nil
                markerRanges.removeAll(keepingCapacity: true)
            }
            position = lineEnd
        }

        appendRegion()
        return regions
    }

    static func quoteMarkerRange(
        in source: NSString,
        lineRange: NSRange
    ) -> NSRange? {
        let marker = source.rangeOfCharacter(
            from: CharacterSet.whitespaces.inverted,
            options: [],
            range: lineRange
        )
        guard marker.location != NSNotFound,
              source.character(at: marker.location) == 0x3E else {
            return nil
        }
        var markerEnd = marker.location + 1
        if markerEnd < NSMaxRange(lineRange) {
            let nextCharacter = source.character(at: markerEnd)
            if nextCharacter == 0x20 || nextCharacter == 0x09 {
                markerEnd += 1
            }
        }
        return NSRange(location: lineRange.location, length: markerEnd - lineRange.location)
    }
}

enum ComposerQuoteEditing {
    static func returnEdit(
        in text: String,
        selectedRange: NSRange
    ) -> ComposerTextEdit? {
        let source = text as NSString
        guard selectedRange.location <= source.length,
              NSMaxRange(selectedRange) <= source.length else {
            return nil
        }

        let fencedCodeRanges = ComposerCodeSyntaxParser.regions(in: text).compactMap {
            region -> NSRange? in
            guard case .fenced = region.kind else { return nil }
            return region.range
        }
        let quoteRegions = ComposerQuoteSyntaxParser.regions(
            in: text,
            excluding: fencedCodeRanges
        )
        guard quoteRegions.contains(where: {
            NSLocationInRange(selectedRange.location, $0.range)
                || selectedRange.location == NSMaxRange($0.range)
        }) else {
            return nil
        }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        source.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: selectedRange.location, length: 0)
        )
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        guard let markerRange = ComposerQuoteSyntaxParser.quoteMarkerRange(
            in: source,
            lineRange: lineRange
        ),
              selectedRange.location >= NSMaxRange(markerRange) else {
            return nil
        }

        let contentRange = NSRange(
            location: NSMaxRange(markerRange),
            length: contentsEnd - NSMaxRange(markerRange)
        )
        let lineIsEmpty = source.substring(with: contentRange)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
        if lineIsEmpty, selectedRange.location == contentsEnd {
            return ComposerTextEdit(range: lineRange, replacement: "\n")
        }

        var marker = source.substring(with: markerRange)
        if marker.last == ">" {
            marker.append(" ")
        }
        return ComposerTextEdit(
            range: selectedRange,
            replacement: "\n" + marker
        )
    }
}

enum ComposerListIndentationDirection {
    case deeper
    case shallower
}

enum ComposerListEditing {
    static func returnEdit(
        in text: String,
        selectedRange: NSRange
    ) -> ComposerTextEdit? {
        let source = text as NSString
        guard NSMaxRange(selectedRange) <= source.length else { return nil }
        let items = sourceItems(in: text)
        guard let index = currentItemIndex(in: items, at: selectedRange.location) else {
            return nil
        }
        let sourceItem = items[index]
        guard selectedRange.location >= NSMaxRange(sourceItem.markerRange) else {
            return nil
        }

        let isEmpty = sourceItem.item.content
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
        if isEmpty, selectedRange.location == NSMaxRange(sourceItem.lineRange) {
            if sourceItem.item.depth == 0 {
                return ComposerTextEdit(range: sourceItem.lineRange, replacement: "\n")
            }

            let parentDepth = sourceItem.item.depth - 1
            let currentList = items[currentListStart(in: items, at: index)..<index]
            let parent = currentList.last { $0.item.depth == parentDepth }
            let parentKind = parent?.item.kind ?? sourceItem.item.kind
            let parentMarker = parent.map { NoteListSyntaxParser.nextSourceMarker(for: $0.item) }
                ?? NoteListSyntaxParser.defaultSourceMarker(for: parentKind)
            return ComposerTextEdit(
                range: sourceItem.lineRange,
                replacement: NoteListSyntaxParser.indentation(for: parentDepth) + parentMarker
            )
        }

        return ComposerTextEdit(
            range: selectedRange,
            replacement: "\n"
                + sourceItem.indentation
                + NoteListSyntaxParser.nextSourceMarker(for: sourceItem.item)
        )
    }

    static func indentationEdit(
        in text: String,
        selectedRange: NSRange,
        direction: ComposerListIndentationDirection
    ) -> ComposerTextEdit? {
        guard selectedRange.length == 0 else { return nil }
        let items = sourceItems(in: text)
        guard let index = currentItemIndex(in: items, at: selectedRange.location) else {
            return nil
        }
        let sourceItem = items[index]
        let targetDepth: Int
        let marker: String

        switch direction {
        case .deeper:
            targetDepth = sourceItem.item.depth + 1
            if sourceItem.item.kind == .ordered {
                marker = NoteListSyntaxParser.defaultSourceMarker(for: .ordered)
            } else {
                marker = NoteListSyntaxParser.nextSourceMarker(for: sourceItem.item)
            }
        case .shallower:
            guard sourceItem.item.depth > 0 else { return nil }
            targetDepth = sourceItem.item.depth - 1
            let currentList = items[currentListStart(in: items, at: index)..<index]
            let previousPeer = currentList.last {
                $0.item.depth == targetDepth && $0.item.kind == sourceItem.item.kind
            }
            marker = previousPeer.map {
                NoteListSyntaxParser.nextSourceMarker(for: $0.item)
            } ?? NoteListSyntaxParser.defaultSourceMarker(for: sourceItem.item.kind)
        }

        let replacement = NoteListSyntaxParser.indentation(for: targetDepth) + marker
        let selectionAfterEdit = NSRange(
            location: selectedRange.location
                + (replacement as NSString).length
                - sourceItem.markerRange.length,
            length: 0
        )
        return ComposerTextEdit(
            range: sourceItem.markerRange,
            replacement: replacement,
            selectionAfterEdit: selectionAfterEdit
        )
    }

    private static func sourceItems(in text: String) -> [NoteListSourceItem] {
        let fencedCodeRanges = ComposerCodeSyntaxParser.regions(in: text).compactMap {
            region -> NSRange? in
            guard case .fenced = region.kind else { return nil }
            return region.range
        }
        return NoteListSyntaxParser.sourceItems(in: text, excluding: fencedCodeRanges)
    }

    private static func currentItemIndex(
        in items: [NoteListSourceItem],
        at location: Int
    ) -> Int? {
        items.lastIndex {
            NSLocationInRange(location, $0.lineRange)
                || location == NSMaxRange($0.lineRange)
        }
    }

    private static func currentListStart(
        in items: [NoteListSourceItem],
        at index: Int
    ) -> Int {
        items[...index].lastIndex(where: \.startsNewList) ?? index
    }
}

enum ComposerPasteboardText {
    static func emojiPreservingString(plainText: String, html: String) -> String {
        let fullRange = NSRange(location: 0, length: (html as NSString).length)
        let replacements = imageExpression.matches(in: html, range: fullRange).compactMap {
            match -> (shortcode: String, emoji: String)? in
            let tag = (html as NSString).substring(with: match.range)
            guard let shortcode = attribute(named: "data-stringify-emoji", in: tag),
                  let source = attribute(named: "src", in: tag),
                  let emoji = unicodeEmoji(fromImageSource: source) else {
                return nil
            }
            return (shortcode, emoji)
        }

        var result = plainText
        var searchStart = result.startIndex
        for replacement in replacements {
            guard let range = result.range(
                of: replacement.shortcode,
                range: searchStart..<result.endIndex
            ) else {
                continue
            }
            let replacementOffset = result.distance(
                from: result.startIndex,
                to: range.lowerBound
            )
            result.replaceSubrange(range, with: replacement.emoji)
            searchStart = result.index(
                result.startIndex,
                offsetBy: replacementOffset + replacement.emoji.count
            )
        }
        return result
    }

    static func emojiPreservingString(from pasteboard: NSPasteboard) -> String? {
        guard let plainText = pasteboard.string(forType: .string),
              let htmlData = pasteboard.data(forType: .html),
              let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }
        let transformed = emojiPreservingString(plainText: plainText, html: html)
        return transformed == plainText ? nil : transformed
    }

    static func continuingQuoteString(for text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return normalized }
        for index in lines.indices.dropFirst() where !hasQuoteMarker(lines[index]) {
            lines[index] = "> " + lines[index]
        }
        return lines.joined(separator: "\n")
    }

    private static let imageExpression = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    private static func hasQuoteMarker(_ line: String) -> Bool {
        guard let firstContent = line.firstIndex(where: { !$0.isWhitespace }) else {
            return false
        }
        return line[firstContent] == ">"
    }

    private static func attribute(named name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        for quote in ["\"", "'"] {
            let expression = try! NSRegularExpression(
                pattern: "\\b\(escapedName)\\s*=\\s*\(quote)(.*?)\(quote)",
                options: [.caseInsensitive]
            )
            let fullRange = NSRange(location: 0, length: (tag as NSString).length)
            guard let match = expression.firstMatch(in: tag, range: fullRange),
                  match.numberOfRanges == 2 else {
                continue
            }
            return (tag as NSString).substring(with: match.range(at: 1))
        }
        return nil
    }

    private static func unicodeEmoji(fromImageSource source: String) -> String? {
        guard let url = URL(string: source),
              url.host?.lowercased() == "a.slack-edge.com",
              url.path.contains("emoji-assets"),
              let filename = url.path.split(separator: "/").last else {
            return nil
        }
        let stem = filename.split(separator: ".", maxSplits: 1).first?
            .split(separator: "@", maxSplits: 1).first ?? ""
        let scalars = stem.split(separator: "-").compactMap { component -> UnicodeScalar? in
            guard let value = UInt32(component, radix: 16) else { return nil }
            return UnicodeScalar(value)
        }
        guard !scalars.isEmpty,
              scalars.count == stem.split(separator: "-").count else {
            return nil
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

@MainActor
enum ComposerMarkupHighlighter {
    static func apply(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let source = textView.string
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let codeRegions = ComposerCodeSyntaxParser.regions(in: source)
        let fencedCodeRegions = codeRegions.filter { region in
            guard case .fenced = region.kind else { return false }
            return true
        }
        let fencedCodeRanges = fencedCodeRegions.map(\.range)
        let quoteRegions = ComposerQuoteSyntaxParser.regions(
            in: source,
            excluding: fencedCodeRanges
        )
        let listSourceItems = NoteListSyntaxParser.sourceItems(
            in: source,
            excluding: fencedCodeRanges
        )
        let listMarkers = NoteListSyntaxParser.displayMarkers(for: listSourceItems)
        (textView as? SendingTextView)?.codeBlockRegions = fencedCodeRegions
        (textView as? SendingTextView)?.quoteBlockRanges = quoteRegions.map(\.range)
        (textView as? SendingTextView)?.listItems = zip(listSourceItems, listMarkers).map {
            sourceItem, marker in
            ComposerListDrawingItem(
                range: sourceItem.lineRange,
                marker: marker,
                depth: sourceItem.item.depth
            )
        }
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let quoteParagraphStyle = NSMutableParagraphStyle()
        quoteParagraphStyle.setParagraphStyle(NSParagraphStyle.default)
        quoteParagraphStyle.firstLineHeadIndent = 14
        quoteParagraphStyle.headIndent = 14
        quoteParagraphStyle.minimumLineHeight = ceil(
            bodyFont.ascender - bodyFont.descender + bodyFont.leading
        )
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.clear,
            .paragraphStyle: NSParagraphStyle.default
        ]

        let undoManager = textView.undoManager
        let shouldRestoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        textStorage.beginEditing()
        if fullRange.length > 0 {
            textStorage.setAttributes(baseAttributes, range: fullRange)
        }
        for region in codeRegions {
            switch region.kind {
            case .inline:
                textStorage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: bodyFont.pointSize,
                            weight: .regular
                        ),
                        .foregroundColor: NSColor.systemRed,
                        .backgroundColor: NSColor.controlBackgroundColor
                    ],
                    range: region.range
                )
            case .fenced:
                textStorage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: bodyFont.pointSize,
                            weight: .regular
                        ),
                        .foregroundColor: NSColor.textColor
                    ],
                    range: region.range
                )
                for markerRange in region.markerRanges where markerRange.length > 0 {
                    textStorage.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: 0.1),
                            .foregroundColor: NSColor.clear
                        ],
                        range: markerRange
                    )
                }
            }
        }
        for region in quoteRegions {
            textStorage.addAttribute(
                .paragraphStyle,
                value: quoteParagraphStyle,
                range: region.range
            )
            for markerRange in region.markerRanges where markerRange.length > 0 {
                textStorage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 0.1),
                        .foregroundColor: NSColor.clear
                    ],
                    range: markerRange
                )
            }
        }
        for sourceItem in listSourceItems {
            textStorage.addAttribute(
                .paragraphStyle,
                value: listParagraphStyle(depth: sourceItem.item.depth, bodyFont: bodyFont),
                range: sourceItem.lineRange
            )
            textStorage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ],
                range: sourceItem.markerRange
            )
        }
        textStorage.endEditing()
        if shouldRestoreUndoRegistration {
            undoManager?.enableUndoRegistration()
        }
        textView.typingAttributes = typingAttributes(
            at: textView.selectedRange().location,
            textLength: textStorage.length,
            codeRegions: codeRegions,
            quoteRegions: quoteRegions,
            quoteParagraphStyle: quoteParagraphStyle,
            listSourceItems: listSourceItems,
            bodyFont: bodyFont,
            textStorage: textStorage,
            fallback: baseAttributes
        )
    }

    private static func typingAttributes(
        at location: Int,
        textLength: Int,
        codeRegions: [ComposerCodeRegion],
        quoteRegions: [ComposerQuoteRegion],
        quoteParagraphStyle: NSParagraphStyle,
        listSourceItems: [NoteListSourceItem],
        bodyFont: NSFont,
        textStorage: NSTextStorage,
        fallback: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        if let region = codeRegions.first(where: { region in
            if NSLocationInRange(location, region.range) {
                return true
            }
            guard case .fenced(isClosed: false) = region.kind else { return false }
            return location == NSMaxRange(region.range) && location == textLength
        }), region.range.length > 0 {
            if case .fenced(isClosed: false) = region.kind,
               location == NSMaxRange(region.range),
               location == textLength {
                var attributes = fallback
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: bodyFont.pointSize,
                    weight: .regular
                )
                attributes[.foregroundColor] = NSColor.textColor
                return attributes
            }
            let attributeLocation = min(
                max(location, region.range.location),
                NSMaxRange(region.range) - 1
            )
            return textStorage.attributes(at: attributeLocation, effectiveRange: nil)
        }

        if quoteRegions.contains(where: {
            NSLocationInRange(location, $0.range) || location == NSMaxRange($0.range)
        }) {
            var attributes = fallback
            attributes[.paragraphStyle] = quoteParagraphStyle
            return attributes
        }
        if let sourceItem = listSourceItems.first(where: {
            NSLocationInRange(location, $0.lineRange)
                || location == NSMaxRange($0.lineRange)
        }) {
            var attributes = fallback
            attributes[.paragraphStyle] = listParagraphStyle(
                depth: sourceItem.item.depth,
                bodyFont: bodyFont
            )
            return attributes
        }
        return fallback
    }

    private static func listParagraphStyle(
        depth: Int,
        bodyFont: NSFont
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(NSParagraphStyle.default)
        let indentation = CGFloat(max(depth, 0)) * 20 + 28
        style.firstLineHeadIndent = indentation
        style.headIndent = indentation
        style.minimumLineHeight = ceil(
            bodyFont.ascender - bodyFont.descender + bodyFont.leading
        )
        return style
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String

    let focusGeneration: Int
    let isEditable: Bool
    let onSend: () -> Void
    let onPasteImage: (Data, String, String) -> Void
    var accessibilityIdentifier = "composer-field"
    var accessibilityLabel = "Write a note"
    var accessibilityHelp = "Command Return sends the note. Return inserts a new line and continues a quote, list, or code block. Return again on an empty line exits that block. A greater-than sign starts a quote, a hyphen starts bullets, and one followed by a period starts numbering. Tab and Shift Tab change list nesting. Single and triple backticks preview code formatting. Pasting a clipboard image adds it as an attachment."

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = SendingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        ComposerMarkupHighlighter.apply(to: textView)
        textView.onSend = onSend
        textView.onPasteImage = onPasteImage
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SendingTextView else { return }
        context.coordinator.parent = self
        textView.onSend = onSend
        textView.onPasteImage = onPasteImage
        textView.isEditable = isEditable
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        if textView.string != text, !textView.hasMarkedText() {
            let isFocused = textView.window?.firstResponder === textView
            let selectedRanges = isFocused ? textView.selectedRanges : []
            textView.string = text
            let textLength = (text as NSString).length
            if isFocused {
                let adjustedRanges = selectedRanges.map { value in
                    let range = value.rangeValue
                    let location = min(range.location, textLength)
                    let length = min(range.length, textLength - location)
                    return NSValue(range: NSRange(location: location, length: length))
                }
                textView.selectedRanges = adjustedRanges.isEmpty
                    ? [NSValue(range: NSRange(location: textLength, length: 0))]
                    : adjustedRanges
            } else {
                textView.setSelectedRange(NSRange(location: textLength, length: 0))
            }
            ComposerMarkupHighlighter.apply(to: textView)
        }

        if focusGeneration != context.coordinator.appliedFocusGeneration,
           let window = textView.window {
            context.coordinator.appliedFocusGeneration = focusGeneration
            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var appliedFocusGeneration = 0

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !textView.hasMarkedText() {
                ComposerMarkupHighlighter.apply(to: textView)
            }
            parent.text = textView.string
        }
    }
}

private final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteImage: ((Data, String, String) -> Void)?
    var codeBlockRegions: [ComposerCodeRegion] = [] {
        didSet {
            if oldValue != codeBlockRegions {
                needsDisplay = true
            }
        }
    }
    var quoteBlockRanges: [NSRange] = [] {
        didSet {
            if oldValue != quoteBlockRanges {
                needsDisplay = true
            }
        }
    }
    var listItems: [ComposerListDrawingItem] = [] {
        didSet {
            if oldValue != listItems {
                needsDisplay = true
            }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager,
              let textContainer else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let containerOrigin = textContainerOrigin

        for region in codeBlockRegions where region.range.length > 0 {
            let characterRange = region.range
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var blockRect = NSRect.null
            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { lineRect, _, _, _, _ in
                blockRect = blockRect.union(
                    lineRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
                )
            }
            if case .fenced(isClosed: false) = region.kind,
               NSMaxRange(characterRange) == textStorage?.length,
               string.last?.isNewline == true,
               layoutManager.extraLineFragmentTextContainer === textContainer {
                blockRect = blockRect.union(
                    layoutManager.extraLineFragmentRect.offsetBy(
                        dx: containerOrigin.x,
                        dy: containerOrigin.y
                    )
                )
            }
            guard !blockRect.isNull else { continue }
            blockRect = blockRect.insetBy(dx: 0, dy: -3)
            blockRect.origin.x = containerOrigin.x - 4
            blockRect.size.width = max(bounds.width - (containerOrigin.x * 2) + 8, 0)

            NSColor.unemphasizedSelectedContentBackgroundColor
                .withAlphaComponent(0.35)
                .setFill()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(roundedRect: blockRect, xRadius: 6, yRadius: 6)
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }

        for characterRange in quoteBlockRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var quoteRect = NSRect.null
            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { lineRect, _, _, _, _ in
                quoteRect = quoteRect.union(
                    lineRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
                )
            }
            guard !quoteRect.isNull else { continue }
            let barRect = NSRect(
                x: containerOrigin.x + 2,
                y: quoteRect.minY + 1,
                width: 3,
                height: max(quoteRect.height - 2, 1)
            )
            NSColor.separatorColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        let markerStyle = NSMutableParagraphStyle()
        markerStyle.alignment = .right
        let markerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: markerStyle
        ]
        for item in listItems where item.range.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: item.range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { continue }
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let markerRect = NSRect(
                x: containerOrigin.x + CGFloat(max(item.depth, 0)) * 20,
                y: containerOrigin.y + lineRect.minY,
                width: 24,
                height: lineRect.height
            )
            (item.marker as NSString).draw(in: markerRect, withAttributes: markerAttributes)
        }
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
            onPasteImage?(data, "Pasted Image.png", "public.png")
            return
        }
        if let data = pasteboard.data(forType: .tiff) {
            onPasteImage?(data, "Pasted Image.tiff", "public.tiff")
            return
        }
        let emojiPreservingText = ComposerPasteboardText.emojiPreservingString(from: pasteboard)
        let plainText = emojiPreservingText ?? pasteboard.string(forType: .string)
        if isPasteInsertionInQuote,
           let plainText,
           plainText.contains(where: { $0.isNewline }) {
            insertText(
                ComposerPasteboardText.continuingQuoteString(for: plainText),
                replacementRange: selectedRange()
            )
            return
        }
        if let text = emojiPreservingText {
            insertText(text, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    private var isPasteInsertionInQuote: Bool {
        let source = string
        let fencedCodeRanges = ComposerCodeSyntaxParser.regions(in: source).compactMap {
            region -> NSRange? in
            guard case .fenced = region.kind else { return nil }
            return region.range
        }
        let insertionLocation = selectedRange().location
        return ComposerQuoteSyntaxParser.regions(
            in: source,
            excluding: fencedCodeRanges
        ).contains {
            NSLocationInRange(insertionLocation, $0.range)
                || insertionLocation == NSMaxRange($0.range)
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let disallowedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option]
        if isReturn,
           !hasMarkedText(),
           event.modifierFlags.contains(.command),
           event.modifierFlags.intersection(disallowedModifiers).isEmpty {
            onSend?()
            return
        }
        let quoteContinuationModifiers: NSEvent.ModifierFlags = [
            .command,
            .shift,
            .control,
            .option
        ]
        if isReturn,
           !hasMarkedText(),
           event.modifierFlags.intersection(quoteContinuationModifiers).isEmpty,
           let edit = ComposerCodeEditing.returnEdit(
               in: string,
               selectedRange: selectedRange()
           ) {
            apply(edit)
            return
        }
        if isReturn,
           !hasMarkedText(),
           event.modifierFlags.intersection(quoteContinuationModifiers).isEmpty,
           let edit = ComposerQuoteEditing.returnEdit(
               in: string,
               selectedRange: selectedRange()
           ) {
            apply(edit)
            return
        }
        if isReturn,
           !hasMarkedText(),
           event.modifierFlags.intersection(quoteContinuationModifiers).isEmpty,
           let edit = ComposerListEditing.returnEdit(
               in: string,
               selectedRange: selectedRange()
           ) {
            apply(edit)
            return
        }
        let isTab = event.keyCode == 48
        let disallowedTabModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if isTab,
           !hasMarkedText(),
           event.modifierFlags.intersection(disallowedTabModifiers).isEmpty,
           let edit = ComposerListEditing.indentationEdit(
               in: string,
               selectedRange: selectedRange(),
               direction: event.modifierFlags.contains(.shift) ? .shallower : .deeper
           ) {
            apply(edit)
            return
        }
        super.keyDown(with: event)
    }

    private func apply(_ edit: ComposerTextEdit) {
        insertText(edit.replacement, replacementRange: edit.range)
        if let selectionAfterEdit = edit.selectionAfterEdit {
            setSelectedRange(selectionAfterEdit)
        }
    }
}
