# Phase 2 — Search and Timeline Navigation

- **Status:** Implemented — automated harness passed; Xcode and interaction verification pending
- **Depends on:** Phase 1
- **Produces:** Fast full-text search and reliable navigation to results

## Goal

Make years of notes easy to retrieve by text, date, and content type while preserving the timeline's bottom-anchored behavior.

## Scope

1. Add and migrate an SQLite FTS5 index for note bodies.
2. Keep the index consistent for create, edit, trash, restore, and permanent delete operations.
3. Implement search result ranking and an explicit chronological sort option.
4. Add `Command+F`, a visible search field, clear action, result count, and helpful empty states.
5. Add filters for date range, has attachment, has image, and has link. Attachment/link filters may remain disabled or return no results until their corresponding phases populate data, but the query design must not require rebuilding search later.
6. Highlight matching terms accessibly without relying only on color.
7. Selecting a result must load the required timeline page, reveal the note in context, and focus or announce it without permanently disturbing normal timeline state.
8. Add a keyboard-accessible action to return to the newest note.
9. Define safe query handling for punctuation, quoted text, Unicode, emoji, and invalid FTS syntax.
10. Ensure deleted notes do not appear in normal search; provide a separate trash search only if it can remain simple.

## Search semantics

- Empty search text with filters is valid.
- User text is treated as search input, not raw FTS syntax, unless an advanced-query mode is deliberately added later.
- Search should debounce enough to avoid unnecessary work while remaining responsive.
- Cancelling or replacing an in-flight query must not display stale results.
- Result snippets must not expose markup as speech noise to VoiceOver.

## Non-goals

- OCR or semantic/vector search
- Natural-language date parsing
- Searching inside arbitrary attached documents
- Saved searches
- Search synchronization across devices

## Acceptance criteria

- [x] Search indexes existing notes during migration and new changes incrementally.
- [x] Creating, editing, trashing, restoring, and deleting a note produce correct search results.
- [ ] `Command+F` reliably moves focus to search, and `Escape` returns focus predictably.
- [ ] Selecting a result reveals the exact note even when it is outside the loaded timeline pages.
- [ ] Match highlighting has a non-color-only indication and an understandable VoiceOver representation.
- [x] Invalid or unusual user input cannot cause an SQL/FTS error to escape to the UI.
- [x] Stale asynchronous results never replace a newer query's results.
- [x] A representative 100,000-note fixture returns common searches within the agreed local performance budget; record measured hardware and timings.
- [x] Unit tests cover indexing lifecycle, query escaping, filters, Unicode, and result navigation identifiers.
- [x] UI tests cover focus, query, result selection, clear, and return-to-latest behavior.

## Verification

- Run all unit and UI tests.
- Build a deterministic 100,000-note fixture and record median/worst observed query latency for several common and rare terms.
- Perform keyboard-only and VoiceOver searches, including a no-results case and navigation to an unloaded old note.
- Verify main timeline scroll state remains understandable after leaving search.

## Completion notes

- **Implementation summary:** Added safe ordinary-text search with relevance/newest/oldest sorting, inclusive-day date controls, exact result counts, a 250 ms cancellable debounce with generation guards, disabled future attachment/image/link filters, explicit empty/loading/error states, underlined and text-labeled match excerpts, and bounded result-to-timeline context loading with keyboard and accessibility focus plus a return-to-newest action. Search refreshes after all note mutations. Existing Slack-style `Command-Return` send and Return newline code was not changed.
- **Schema/index migrations added:** Forward-only `v2_create_note_search` creates a contentful FTS5 table using `unicode61 remove_diacritics 2`, backfills existing active notes, and installs insert/update/delete triggers. Trash transitions remove/reinsert index rows; permanent deletion removes any remaining row. User input is converted to quoted generated tokens, with parameterized literal predicates for emoji/symbol-only and punctuation-only searches; raw FTS syntax is never accepted.
- **Performance measurements:** Deterministic 100,000-note fixture on a MacBook Pro (MacBookPro18,2), Apple M1 Max, 64 GiB RAM, macOS 26.5.1, Swift 6.3.2. Latest performance-harness run: fixture `4.837265s`; newest 50-note page `0.000527s`; common term median/worst `0.173680s`/`0.182049s`; rare term `0.000317s`/`0.000552s`; CJK `0.004321s`/`0.005345s`; emoji `0.020960s`/`0.022277s`. Each search probe ran seven times and all worst values were below the one-second local budget encoded by the performance test.
- **Commands and checks run:** `swift build --package-path .build/phase2-harness --target SelfDMNotesAppCheck` compiled all production Swift sources against GRDB 7.11.1. `swift run --package-path .build/phase2-harness Phase2Probe` passed migration backfill, create/edit/trash/restore/delete indexing, Unicode/emoji/punctuation and invalid-syntax input, bounded pages/context identifiers, debounced replacement, return-to-newest, and the performance probes using only fresh temporary databases. A focused correction rerun recompiled all production sources and passed deterministic stale-failure probes for result reveal and return-to-newest, including unchanged newer search/selection state and loaded-result context semantics. Swift parser checks passed for unit/UI test sources. Project plist, scheme/workspace XML, pinned `Package.resolved`, Xcode file references, and `git diff --check` were checked separately. The ignored temporary harness was removed afterward.
- **Accessibility checks:** Search controls have labels, hints, result counts, bounded plain-speech visible excerpts, explicit “Text match”/“Date match” labels, bold underlining independent of color, matched excerpts, selected-result labeling, keyboard/accessibility focus, Escape behavior, and Reduce Motion-aware newest navigation. Focus/query/selection/clear/Escape/newest XCUITest coverage was added, but no XCUITest, manual keyboard, VoiceOver, or visual check ran; the three interaction-dependent acceptance boxes remain unchecked.
- **Known issues or follow-up tickets:** Full Xcode and the XCTest module are unavailable on this machine, so XCTest/XCUITest execution remains pending. Manual keyboard, VoiceOver, visual focus/scroll preservation, and app interaction checks remain pending. Attachment/image filters intentionally remain disabled until Phase 3 and link filtering until Phase 4; no fake attachment/link behavior or later-phase schema was added.
