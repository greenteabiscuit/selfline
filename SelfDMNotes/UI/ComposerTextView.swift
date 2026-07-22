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

@MainActor
enum ComposerCodeHighlighter {
    static func apply(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let source = textView.string
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let regions = ComposerCodeSyntaxParser.regions(in: source)
        (textView as? SendingTextView)?.codeBlockRanges = regions.compactMap { region in
            guard case .fenced = region.kind else { return nil }
            return region.range
        }
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
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
        for region in regions {
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
        textStorage.endEditing()
        if shouldRestoreUndoRegistration {
            undoManager?.enableUndoRegistration()
        }
        textView.typingAttributes = typingAttributes(
            at: textView.selectedRange().location,
            textLength: textStorage.length,
            regions: regions,
            textStorage: textStorage,
            fallback: baseAttributes
        )
    }

    private static func typingAttributes(
        at location: Int,
        textLength: Int,
        regions: [ComposerCodeRegion],
        textStorage: NSTextStorage,
        fallback: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        guard let region = regions.first(where: { region in
            if NSLocationInRange(location, region.range) {
                return true
            }
            guard case .fenced(isClosed: false) = region.kind else { return false }
            return location == NSMaxRange(region.range) && location == textLength
        }), region.range.length > 0 else {
            return fallback
        }
        let attributeLocation = min(
            max(location, region.range.location),
            NSMaxRange(region.range) - 1
        )
        return textStorage.attributes(at: attributeLocation, effectiveRange: nil)
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
    var accessibilityHelp = "Command Return sends the note. Return inserts a new line. Single and triple backticks preview code formatting. Pasting a clipboard image adds it as an attachment."

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
        ComposerCodeHighlighter.apply(to: textView)
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
            ComposerCodeHighlighter.apply(to: textView)
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
                ComposerCodeHighlighter.apply(to: textView)
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
        super.paste(sender)
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
