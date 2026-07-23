import Foundation

enum NoteListKind: Equatable {
    case unordered
    case ordered
}

struct NoteBodyListItem: Equatable {
    let kind: NoteListKind
    let depth: Int
    let content: String
    let sourceMarker: String
}

struct NoteListSourceItem: Equatable {
    let item: NoteBodyListItem
    let lineRange: NSRange
    let markerRange: NSRange
    let indentation: String
    let startsNewList: Bool
}

enum NoteListSyntaxParser {
    static func sourceItems(
        in text: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [NoteListSourceItem] {
        let source = text as NSString
        var items: [NoteListSourceItem] = []
        var position = 0
        var previousLineWasList = false

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
            if !isExcluded,
               let item = sourceItem(
                in: source.substring(with: lineRange),
                lineOffset: lineStart,
                startsNewList: !previousLineWasList
               ) {
                items.append(item)
                previousLineWasList = true
            } else {
                previousLineWasList = false
            }
            position = lineEnd
        }
        return items
    }

    static func item(in line: String) -> NoteBodyListItem? {
        sourceItem(in: line, lineOffset: 0, startsNewList: true)?.item
    }

    static func displayMarkers(for sourceItems: [NoteListSourceItem]) -> [String] {
        var result: [String] = []
        var list: [NoteBodyListItem] = []

        func appendList() {
            result.append(contentsOf: displayMarkers(for: list))
            list.removeAll(keepingCapacity: true)
        }

        for sourceItem in sourceItems {
            if sourceItem.startsNewList, !list.isEmpty {
                appendList()
            }
            list.append(sourceItem.item)
        }
        appendList()
        return result
    }

    static func displayMarkers(for items: [NoteBodyListItem]) -> [String] {
        var orderedCounters: [Int: Int] = [:]
        var markers: [String] = []

        for item in items {
            for depth in orderedCounters.keys.filter({ $0 > item.depth }) {
                orderedCounters.removeValue(forKey: depth)
            }
            switch item.kind {
            case .unordered:
                orderedCounters.removeValue(forKey: item.depth)
                markers.append(unorderedMarker(for: item.depth))
            case .ordered:
                let number: Int
                if let current = orderedCounters[item.depth] {
                    number = current + 1
                } else {
                    number = sourceOrdinal(from: item.sourceMarker) ?? 1
                }
                orderedCounters[item.depth] = number
                markers.append(orderedMarker(number, depth: item.depth))
            }
        }
        return markers
    }

    static func nextSourceMarker(for item: NoteBodyListItem) -> String {
        switch item.kind {
        case .unordered:
            return "\(item.sourceMarker.first ?? "-") "
        case .ordered:
            let marker = item.sourceMarker.dropLast()
            if let number = Int(marker) {
                return "\(number + 1). "
            }
            return "1. "
        }
    }

    static func defaultSourceMarker(for kind: NoteListKind) -> String {
        kind == .unordered ? "- " : "1. "
    }

    static func indentation(for depth: Int) -> String {
        String(repeating: "  ", count: max(depth, 0))
    }

    private static func sourceItem(
        in line: String,
        lineOffset: Int,
        startsNewList: Bool
    ) -> NoteListSourceItem? {
        let source = line as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        guard let match = listExpression.firstMatch(in: line, range: fullRange),
              match.numberOfRanges == 5 else {
            return nil
        }
        let indentation = source.substring(with: match.range(at: 1))
        let sourceMarker = source.substring(with: match.range(at: 2))
        let content = source.substring(with: match.range(at: 4))
        let kind: NoteListKind = sourceMarker == "-"
            || sourceMarker == "+"
            || sourceMarker == "*"
            ? .unordered
            : .ordered
        return NoteListSourceItem(
            item: NoteBodyListItem(
                kind: kind,
                depth: indentationDepth(indentation),
                content: content,
                sourceMarker: sourceMarker
            ),
            lineRange: NSRange(location: lineOffset, length: source.length),
            markerRange: NSRange(
                location: lineOffset,
                length: NSMaxRange(match.range(at: 3))
            ),
            indentation: indentation,
            startsNewList: startsNewList
        )
    }

    private static func indentationDepth(_ indentation: String) -> Int {
        let columns = indentation.reduce(into: 0) { columns, character in
            columns += character == "\t" ? 2 : 1
        }
        return columns / 2
    }

    private static func unorderedMarker(for depth: Int) -> String {
        ["•", "◦", "▪"][max(depth, 0) % 3]
    }

    private static func orderedMarker(_ number: Int, depth: Int) -> String {
        switch max(depth, 0) % 3 {
        case 1:
            return "\(alphabeticLabel(number))."
        case 2:
            return "\(romanLabel(number))."
        default:
            return "\(number)."
        }
    }

    private static func sourceOrdinal(from marker: String) -> Int? {
        let value = marker.hasSuffix(".") ? String(marker.dropLast()) : marker
        guard let number = Int(value), number > 0 else { return nil }
        return number
    }

    private static func alphabeticLabel(_ number: Int) -> String {
        var value = max(number, 1)
        var result = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(97 + (value % 26))!
            result.insert(Character(scalar), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private static func romanLabel(_ number: Int) -> String {
        guard number > 0, number < 4_000 else { return "\(number)" }
        let values = [
            (1_000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")
        ]
        var remainder = number
        var result = ""
        for (value, numeral) in values {
            while remainder >= value {
                result += numeral
                remainder -= value
            }
        }
        return result
    }

    private static let listExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+*]|[0-9]+\.)([ \t]+)(.*)$"#
    )
}
