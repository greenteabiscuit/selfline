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
            } else if isOpeningFence(trimmedLine) {
                openFenceLocation = lineStart
                openMarkerRange = NSRange(
                    location: lineStart,
                    length: contentsEnd - lineStart
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

    private static func isOpeningFence(_ line: String) -> Bool {
        line.hasPrefix("```") && !line.dropFirst(3).contains("`")
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
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

    private static func quoteMarkerRange(
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
        let fencedCodeRanges = codeRegions.compactMap { region -> NSRange? in
            guard case .fenced = region.kind else { return nil }
            return region.range
        }
        let quoteRegions = ComposerQuoteSyntaxParser.regions(
            in: source,
            excluding: fencedCodeRanges
        )
        (textView as? SendingTextView)?.codeBlockRanges = fencedCodeRanges
        (textView as? SendingTextView)?.quoteBlockRanges = quoteRegions.map(\.range)
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let quoteParagraphStyle = NSMutableParagraphStyle()
        quoteParagraphStyle.setParagraphStyle(NSParagraphStyle.default)
        quoteParagraphStyle.firstLineHeadIndent = 14
        quoteParagraphStyle.headIndent = 14
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
        return fallback
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
    var accessibilityHelp = "Command Return sends the note. Return inserts a new line. A greater-than sign at the start of a line previews a quote block. Single and triple backticks preview code formatting. Pasting a clipboard image adds it as an attachment."

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
    var codeBlockRanges: [NSRange] = [] {
        didSet {
            if oldValue != codeBlockRanges {
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager,
              let textContainer else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let containerOrigin = textContainerOrigin

        for characterRange in codeBlockRanges where characterRange.length > 0 {
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
        super.keyDown(with: event)
    }
}
