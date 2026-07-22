import Foundation

enum NoteSearchSort: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case newest
    case oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: "Relevance"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        }
    }
}

struct NoteSearchFilters: Equatable, Sendable {
    var startDate: Date? = nil
    var endDateExclusive: Date? = nil
    var hasAttachment = false
    var hasImage = false
    var hasLink = false

    var hasActiveFilter: Bool {
        startDate != nil
            || endDateExclusive != nil
            || hasAttachment
            || hasImage
            || hasLink
    }

    var requestsFutureContent: Bool { false }
}

struct NoteSearchRequest: Equatable, Sendable {
    var text: String
    var filters: NoteSearchFilters
    var sort: NoteSearchSort
    var limit: Int = 200

    var hasCriteria: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filters.hasActiveFilter
    }
}

struct NoteSearchResult: Identifiable, Equatable, Sendable {
    let note: Note
    let matchedTerms: [String]
    let relevance: Double?

    var id: UUID { note.id }
    var threadRootID: UUID? { note.threadRootID }
    var navigationNoteID: UUID { note.threadRootID ?? note.id }
    var opensThread: Bool { note.isReply }
}

struct NoteSearchResponse: Equatable, Sendable {
    let results: [NoteSearchResult]
    let totalCount: Int
}

struct TimelineContext: Equatable, Sendable {
    let notes: [Note]
    let selectedNoteID: UUID
    let hasOlder: Bool
    let hasNewer: Bool
}

struct ParsedNoteSearchQuery: Equatable, Sendable {
    let matchExpression: String?
    let literalTerms: [String]
    let highlightedTerms: [String]

    static func parse(_ input: String) -> Self {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self(matchExpression: nil, literalTerms: [], highlightedTerms: [])
        }

        var tokens: [String] = []
        var token = ""
        for scalar in trimmed.unicodeScalars {
            if isIndexedScalar(scalar) {
                token.unicodeScalars.append(scalar)
            } else if !token.isEmpty {
                tokens.append(token)
                token = ""
            }
        }
        if !token.isEmpty {
            tokens.append(token)
        }

        var symbols: [String] = []
        for character in trimmed where character.unicodeScalars.contains(where: isSearchableSymbol) {
            let value = String(character)
            if !symbols.contains(value) {
                symbols.append(value)
            }
        }

        let uniqueTokens = tokens.reduce(into: [String]()) { result, value in
            if !result.contains(where: { $0.compare(value, options: .caseInsensitive) == .orderedSame }) {
                result.append(value)
            }
        }
        let expression = uniqueTokens.isEmpty
            ? nil
            : uniqueTokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
        let literalTerms = if uniqueTokens.isEmpty && symbols.isEmpty {
            [trimmed]
        } else {
            symbols
        }

        return Self(
            matchExpression: expression,
            literalTerms: literalTerms,
            highlightedTerms: uniqueTokens + literalTerms
        )
    }

    private static func isIndexedScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
             .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            true
        default:
            false
        }
    }

    private static func isSearchableSymbol(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .currencySymbol, .modifierSymbol, .mathSymbol, .otherSymbol:
            true
        default:
            false
        }
    }
}
