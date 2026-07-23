import AppKit
import SwiftUI

enum NoteBodyBlock: Equatable {
    case prose(String)
    case quote(String)
    case code(language: String?, text: String)
    case list([NoteBodyListItem])
}

enum NoteBodyInlineSegment: Equatable {
    case prose(String)
    case code(String)
}

enum NoteBodyMarkupParser {
    private struct FenceOpening {
        let content: String
    }

    static func blocks(in text: String) -> [NoteBodyBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [NoteBodyBlock] = []
        var proseLines: [String] = []
        var lineIndex = 0

        func appendProse() {
            let prose = proseLines.joined(separator: "\n")
            if !prose.isEmpty {
                blocks.append(.prose(prose))
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        while lineIndex < lines.count {
            if let opening = openingFence(in: lines[lineIndex]) {
                appendProse()
                let closingIndex = lines[(lineIndex + 1)...].firstIndex(
                    where: isClosingFence
                )
                let contentEnd = closingIndex ?? lines.endIndex
                var codeLines = Array(lines[(lineIndex + 1)..<contentEnd])
                if !opening.content.isEmpty {
                    codeLines.insert(opening.content, at: 0)
                }
                blocks.append(
                    .code(
                        language: nil,
                        text: codeLines.joined(separator: "\n")
                    )
                )
                lineIndex = closingIndex.map { $0 + 1 } ?? lines.endIndex
                continue
            }

            if quoteContent(in: lines[lineIndex]) != nil {
                appendProse()
                var quoteLines: [String] = []
                while lineIndex < lines.count,
                      let quote = quoteContent(in: lines[lineIndex]) {
                    quoteLines.append(quote)
                    lineIndex += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
            } else if NoteListSyntaxParser.item(in: lines[lineIndex]) != nil {
                appendProse()
                var items: [NoteBodyListItem] = []
                while lineIndex < lines.count,
                      let item = NoteListSyntaxParser.item(in: lines[lineIndex]) {
                    items.append(item)
                    lineIndex += 1
                }
                blocks.append(.list(items))
            } else {
                proseLines.append(lines[lineIndex])
                lineIndex += 1
            }
        }

        appendProse()
        return blocks
    }

    static func inlineSegments(in text: String) -> [NoteBodyInlineSegment] {
        var segments: [NoteBodyInlineSegment] = []
        var cursor = text.startIndex

        func appendProse(_ prose: Substring) {
            guard !prose.isEmpty else { return }
            if case let .prose(existing)? = segments.last {
                segments[segments.count - 1] = .prose(existing + prose)
            } else {
                segments.append(.prose(String(prose)))
            }
        }

        while let opening = nextSingleBacktick(in: text, from: cursor) {
            appendProse(text[cursor..<opening])
            let contentStart = text.index(after: opening)
            guard let closing = nextSingleBacktick(in: text, from: contentStart),
                  !text[contentStart..<closing].contains("\n") else {
                appendProse(text[opening...opening])
                cursor = contentStart
                continue
            }

            segments.append(.code(String(text[contentStart..<closing])))
            cursor = text.index(after: closing)
        }

        appendProse(text[cursor...])
        return segments
    }

    private static func openingFence(in line: String) -> FenceOpening? {
        guard let markerStart = line.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        let fenceAndContent = line[markerStart...]
        guard fenceAndContent.hasPrefix("```") else {
            return nil
        }
        return FenceOpening(content: String(fenceAndContent.dropFirst(3)))
    }

    private static func isClosingFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "```"
    }

    private static func quoteContent(in line: String) -> String? {
        guard let marker = line.firstIndex(where: { !$0.isWhitespace }),
              line[marker] == ">" else {
            return nil
        }
        var contentStart = line.index(after: marker)
        if contentStart < line.endIndex,
           line[contentStart] == " " || line[contentStart] == "\t" {
            contentStart = line.index(after: contentStart)
        }
        return String(line[contentStart...])
    }

    private static func nextSingleBacktick(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "`" {
                let previousIsBacktick = index > text.startIndex
                    && text[text.index(before: index)] == "`"
                let next = text.index(after: index)
                let nextIsBacktick = next < text.endIndex && text[next] == "`"
                if !previousIsBacktick && !nextIsBacktick {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum NoteBodyLinkFormatter {
    static func attributedString(for text: String) -> AttributedString {
        var attributed = AttributedString()
        for segment in NoteBodyMarkupParser.inlineSegments(in: text) {
            switch segment {
            case let .prose(prose):
                attributed.append(linkedAttributedString(for: prose))
            case let .code(code):
                var inlineCode = AttributedString(code)
                inlineCode.font = .system(.body, design: .monospaced)
                inlineCode.foregroundColor = Color(nsColor: .systemRed)
                inlineCode.backgroundColor = Color(nsColor: .controlBackgroundColor)
                attributed.append(inlineCode)
            }
        }
        return attributed
    }

    private static func linkedAttributedString(for text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return attributed
        }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        detector.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match,
                  let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  source.substring(with: match.range).range(
                      of: #"^https?://"#,
                      options: [.regularExpression, .caseInsensitive]
                  ) != nil,
                  let stringRange = Range(match.range, in: text),
                  let lowerBound = AttributedString.Index(
                      stringRange.lowerBound,
                      within: attributed
                  ),
                  let upperBound = AttributedString.Index(
                      stringRange.upperBound,
                      within: attributed
                  ) else {
                return
            }
            let range = lowerBound..<upperBound
            let linkColor = Color(nsColor: .linkColor)
            attributed[range].link = url
            attributed[range].foregroundColor = linkColor
            attributed[range].underlineStyle = Text.LineStyle(
                pattern: .solid,
                color: linkColor
            )
        }
        return attributed
    }
}

struct LinkedNoteBodyText: View {
    let text: String
    let accessibilityLabel: String

    var body: some View {
        let blocks = NoteBodyMarkupParser.blocks(in: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .prose(prose):
                    Text(NoteBodyLinkFormatter.attributedString(for: prose))
                        .textSelection(.enabled)
                case let .quote(quote):
                    NoteQuoteBlock(text: quote)
                case let .code(language, code):
                    NoteCodeBlock(text: code, language: language)
                case let .list(items):
                    NoteListBlock(items: items)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(text)
        .accessibilityHint(
            blocks.contains { block in
                let linkableText: String
                switch block {
                case let .prose(prose), let .quote(prose):
                    linkableText = prose
                case let .list(items):
                    linkableText = items.map(\.content).joined(separator: "\n")
                case .code:
                    return false
                }
                return NoteBodyLinkFormatter.attributedString(for: linkableText).runs.contains {
                    $0.link != nil
                }
            }
                ? "HTTP and HTTPS links open in the default browser."
                : ""
        )
    }
}

private struct NoteListBlock: View {
    let items: [NoteBodyListItem]

    var body: some View {
        let markers = NoteListSyntaxParser.displayMarkers(for: items)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let marker = markers[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker)
                        .frame(width: 24, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(NoteBodyLinkFormatter.attributedString(for: item.content))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    item.kind == .ordered ? "List item \(marker)" : "Bullet item"
                )
                .accessibilityValue(item.content)
                .accessibilityHint(
                    NoteBodyLinkFormatter.attributedString(for: item.content).runs.contains {
                        $0.link != nil
                    }
                        ? "HTTP and HTTPS links open in the default browser."
                        : ""
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoteQuoteBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 3)
                .accessibilityHidden(true)
            Text(NoteBodyLinkFormatter.attributedString(for: text.isEmpty ? " " : text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quote block")
        .accessibilityValue(text)
        .accessibilityHint(
            NoteBodyLinkFormatter.attributedString(for: text).runs.contains { $0.link != nil }
                ? "HTTP and HTTPS links open in the default browser."
                : ""
        )
    }
}

private struct NoteCodeBlock: View {
    let text: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language {
                Text(language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(text.isEmpty ? " " : text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.map { "\($0) code block" } ?? "Code block")
        .accessibilityValue(text)
    }
}

struct DateSeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            dateBoundaryLine
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            dateBoundaryLine
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notes from \(date.formatted(date: .complete, time: .omitted))")
    }

    private var dateBoundaryLine: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct NoteRow: View {
    let note: Note
    @ObservedObject var model: TimelineViewModel
    let copy: () -> Void
    let edit: () -> Void
    let editReminder: () -> Void
    let moveToTrash: () -> Void
    let openThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.body.isEmpty {
                LinkedNoteBodyText(text: note.body, accessibilityLabel: "Note text")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("note-body")
            }

            if !note.attachments.isEmpty {
                NoteAttachmentsView(attachments: note.attachments, model: model)
            }

            if note.linkPreviews.contains(where: { $0.status != .removed }) {
                NoteLinkPreviewsView(previews: note.linkPreviews, model: model)
            }

            ReminderStatusLabel(note: note, now: model.reminderClock)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let updatedAt = note.updatedAt {
                    Text("Edited")
                        .accessibilityLabel(
                            "Edited \(updatedAt.formatted(date: .complete, time: .complete))"
                        )
                }
                Text(note.createdAt, format: .dateTime.hour().minute())
                    .accessibilityLabel(
                        "Created \(note.createdAt.formatted(date: .complete, time: .complete))"
                    )
                Button("Reply", systemImage: "bubble.left") {
                    openThread()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("reply-button")
                .accessibilityLabel("Reply to note")
                .accessibilityHint("Opens this note's thread.")
                if note.replyCount > 0 {
                    Text(note.replyCount == 1 ? "1 reply" : "\(note.replyCount) replies")
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("reply-count")
                        .accessibilityLabel(
                            note.replyCount == 1 ? "1 reply" : "\(note.replyCount) replies"
                        )
                }
                Spacer()
                Menu("Note actions", systemImage: "ellipsis") {
                    if !note.body.isEmpty {
                        Button("Copy Text", systemImage: "doc.on.doc", action: copy)
                    }
                    Button("Edit", systemImage: "pencil", action: edit)
                        .disabled(!model.canMutateLibrary)
                    Divider()
                    if note.hasPendingReminder {
                        Button("Edit Reminder…", systemImage: "clock", action: editReminder)
                            .disabled(!model.canMutateLibrary)
                        Button("Mark Reminder as Done", systemImage: "checkmark") {
                            Task { await model.markReminderDone(note) }
                        }
                        .disabled(!model.canMutateLibrary)
                        Button("Remove Reminder", systemImage: "bell.slash") {
                            Task { await model.removeReminder(note) }
                        }
                        .disabled(!model.canMutateLibrary)
                    } else {
                        Button("Set Reminder…", systemImage: "bell", action: editReminder)
                            .disabled(!model.canMutateLibrary)
                    }
                    Divider()
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        moveToTrash()
                    }
                    .disabled(!model.canMutateLibrary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("note-actions")
                .accessibilityHint(
                    "Copy text, edit, manage its reminder, or move this note and its attachments to Trash."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            note.isReminderDue(at: model.reminderClock) ? Color.blue.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct StatusBanner: View {
    let title: String
    let message: String
    let isError: Bool
    let identifier: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    var dismiss: (() -> Void)?
    var announcesChanges = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
            }
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Dismiss status message")
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(message)
        .onAppear {
            announceIfNeeded()
        }
        .onChange(of: message) { _, _ in
            announceIfNeeded()
        }
    }

    private func announceIfNeeded() {
        guard announcesChanges else { return }
        AccessibilityAnnouncement.post(
            "\(title). \(message)",
            priority: isError ? .high : .medium
        )
    }
}
