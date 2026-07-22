import SwiftUI

struct SearchWorkspace: View {
    @ObservedObject var model: TimelineViewModel

    let focusGeneration: Int
    let selectResult: (NoteSearchResult) -> Void
    let exitSearch: () -> Void

    @FocusState private var searchFieldFocused: Bool
    @State private var includeStartDate = false
    @State private var includeEndDate = false
    @State private var startDay = Date()
    @State private var endDay = Date()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            results
        }
        .onAppear {
            synchronizeDateControls()
            searchFieldFocused = true
        }
        .onChange(of: focusGeneration) { _, _ in
            searchFieldFocused = true
        }
        .onChange(of: model.isSearching) { wasSearching, isSearching in
            guard wasSearching, !isSearching else { return }
            if let searchErrorMessage = model.searchErrorMessage {
                AccessibilityAnnouncement.post(
                    "Search unavailable. \(searchErrorMessage)",
                    priority: .high
                )
            } else {
                AccessibilityAnnouncement.post(resultCountDescription)
            }
        }
        .onExitCommand(perform: exitSearch)
        .accessibilityIdentifier("search-workspace")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(
                    "Search notes",
                    text: Binding(
                        get: { model.searchText },
                        set: { model.setSearchText($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .accessibilityIdentifier("search-field")
                .accessibilityLabel("Search notes")
                .accessibilityHint("Search text is treated literally, not as advanced query syntax.")

                if model.hasSearchCriteria {
                    Button("Clear search", systemImage: "xmark.circle.fill") {
                        includeStartDate = false
                        includeEndDate = false
                        model.clearSearch()
                        searchFieldFocused = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Clear search and filters")
                    .accessibilityIdentifier("clear-search-button")
                }

                Button("Close Search", systemImage: "xmark", action: exitSearch)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Close search")
                    .accessibilityHint("Returns focus to the note composer. Escape also closes search.")
            }

            HStack(spacing: 14) {
                Picker(
                    "Sort",
                    selection: Binding(
                        get: { model.searchSort },
                        set: { model.setSearchSort($0) }
                    )
                ) {
                    ForEach(NoteSearchSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                .accessibilityIdentifier("search-sort-picker")

                Spacer()

                if model.hasSearchCriteria {
                    Text(resultCountDescription)
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("search-result-count")
                }
            }

            HStack(spacing: 12) {
                Toggle("From", isOn: $includeStartDate)
                    .onChange(of: includeStartDate) { _, _ in updateDateFilter() }
                DatePicker(
                    "Start date",
                    selection: $startDay,
                    displayedComponents: .date
                )
                .labelsHidden()
                .disabled(!includeStartDate)
                .onChange(of: startDay) { _, _ in updateDateFilter() }
                .accessibilityLabel("Search start date")

                Toggle("Through", isOn: $includeEndDate)
                    .onChange(of: includeEndDate) { _, _ in updateDateFilter() }
                DatePicker(
                    "End date",
                    selection: $endDay,
                    displayedComponents: .date
                )
                .labelsHidden()
                .disabled(!includeEndDate)
                .onChange(of: endDay) { _, _ in updateDateFilter() }
                .accessibilityLabel("Search end date")

                Spacer()

                Menu("Content filters", systemImage: "line.3.horizontal.decrease.circle") {
                    Toggle(
                        "Has attachment",
                        isOn: Binding(
                            get: { model.searchFilters.hasAttachment },
                            set: { model.setSearchHasAttachment($0) }
                        )
                    )
                    Toggle(
                        "Has image",
                        isOn: Binding(
                            get: { model.searchFilters.hasImage },
                            set: { model.setSearchHasImage($0) }
                        )
                    )
                    Toggle(
                        "Has link",
                        isOn: Binding(
                            get: { model.searchFilters.hasLink },
                            set: { model.setSearchHasLink($0) }
                        )
                    )
                }
                .accessibilityHint(
                    "Filters notes containing an attachment, a validated image, or an HTTP or HTTPS link."
                )
                .accessibilityIdentifier("content-filters")
            }
            .font(.callout)
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var results: some View {
        if !model.hasSearchCriteria {
            ContentUnavailableView(
                "Search your notes",
                systemImage: "magnifyingglass",
                description: Text("Enter ordinary text or choose a date range. Punctuation, Unicode, and emoji are supported.")
            )
            .accessibilityIdentifier("search-prompt")
        } else if let searchError = model.searchErrorMessage {
            ContentUnavailableView(
                "Search unavailable",
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(searchError)
            )
            .accessibilityIdentifier("search-error")
        } else if model.isSearching && model.searchResults.isEmpty {
            ProgressView("Searching notes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search-loading")
        } else if model.searchResults.isEmpty {
            ContentUnavailableView(
                "No matching notes",
                systemImage: "text.magnifyingglass",
                description: Text("Try fewer words, a different date range, or clear the search.")
            )
            .accessibilityIdentifier("empty-search-results")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.searchResults) { result in
                        Button {
                            selectResult(result)
                        } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result")
                        .accessibilityHint("Loads and focuses this note in its timeline context.")
                    }
                }
                .padding(12)
            }
            .accessibilityIdentifier("search-results")
        }
    }

    private var resultCountDescription: String {
        if model.isSearching {
            return "Searching…"
        }
        if model.searchResultCount > model.searchResults.count {
            return "Showing \(model.searchResults.count) of \(model.searchResultCount) results"
        }
        return model.searchResultCount == 1 ? "1 result" : "\(model.searchResultCount) results"
    }

    private func synchronizeDateControls() {
        let calendar = Calendar.autoupdatingCurrent
        if let startDate = model.searchFilters.startDate {
            includeStartDate = true
            startDay = startDate
        }
        if let endDate = model.searchFilters.endDateExclusive,
           let inclusiveDay = calendar.date(byAdding: .day, value: -1, to: endDate) {
            includeEndDate = true
            endDay = inclusiveDay
        }
    }

    private func updateDateFilter() {
        let calendar = Calendar.autoupdatingCurrent
        let start = includeStartDate ? calendar.startOfDay(for: startDay) : nil
        let end = includeEndDate
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay))
            : nil
        model.setSearchDateRange(start: start, endExclusive: end)
    }
}

private struct SearchResultRow: View {
    let result: NoteSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    result.matchedTerms.isEmpty ? "Date match" : "Text match",
                    systemImage: result.matchedTerms.isEmpty ? "calendar" : "text.magnifyingglass"
                )
                .font(.caption.weight(.semibold))
                Spacer()
                Text(result.note.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HighlightedSearchText(
                text: visibleExcerpt,
                terms: result.matchedTerms
            )
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search result")
        .accessibilityValue(
            "\(visibleExcerpt). Created \(result.note.createdAt.formatted(date: .complete, time: .complete)). \(result.matchedTerms.isEmpty ? "Matches the date filter." : "Matching text is underlined and labeled Text match.")"
        )
    }

    private var visibleExcerpt: String {
        let body = result.note.body
        let attachmentNames = result.note.attachments.map(\.originalFilename)
        let previewMetadata = result.note.linkPreviews
            .filter { $0.status != .removed }
            .flatMap { preview in
                [preview.originalURL, preview.title, preview.summary, preview.siteName]
                    .compactMap { $0 }
            }
        let filenameMatch = attachmentNames.first { filename in
            result.matchedTerms.contains { term in
                filename.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
        let previewMatch = previewMetadata.first { value in
            result.matchedTerms.contains { term in
                value.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
        if body.isEmpty || filenameMatch != nil || previewMatch != nil {
            let filenames = attachmentNames.joined(separator: ", ")
            let links = previewMetadata.joined(separator: " · ")
            let supplements = [
                filenames.isEmpty ? nil : "Attachments: \(filenames)",
                links.isEmpty ? nil : "Links: \(links)"
            ].compactMap { $0 }.joined(separator: "\n")
            return body.isEmpty ? supplements : "\(body)\n\(supplements)"
        }
        guard body.count > 240,
              let match = result.matchedTerms.compactMap({ term in
                  body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
              }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return body
        }

        let start = body.index(match.lowerBound, offsetBy: -80, limitedBy: body.startIndex)
            ?? body.startIndex
        let end = body.index(match.upperBound, offsetBy: 160, limitedBy: body.endIndex)
            ?? body.endIndex
        return (start == body.startIndex ? "" : "…")
            + body[start..<end]
            + (end == body.endIndex ? "" : "…")
    }
}

private struct HighlightedSearchText: View {
    let text: String
    let terms: [String]

    var bodyView: Text {
        let ranges = matchRanges
        guard !ranges.isEmpty else { return Text(text) }

        var result = Text("")
        var location = 0
        let length = (text as NSString).length
        for range in ranges {
            if range.location > location {
                result = result + Text(substring(NSRange(location: location, length: range.location - location)))
            }
            result = result + Text(substring(range)).bold().underline()
            location = NSMaxRange(range)
        }
        if location < length {
            result = result + Text(substring(NSRange(location: location, length: length - location)))
        }
        return result
    }

    var body: some View {
        bodyView
    }

    private var matchRanges: [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        for term in terms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let range = source.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard range.location != NSNotFound, range.length > 0 else { break }
                ranges.append(range)
                let nextLocation = NSMaxRange(range)
                searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
            }
        }

        let sorted = ranges.sorted {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        return sorted.reduce(into: [NSRange]()) { merged, range in
            guard let last = merged.last else {
                merged.append(range)
                return
            }
            if range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
    }

    private func substring(_ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }
}
