# Phase 1 — Durable Text-Note MVP

- **Status:** Implemented — review fixes applied; Xcode interaction verification pending
- **Depends on:** Phase 0
- **Produces:** A reliable self-DM timeline for plain-text notes

## Goal

Allow the user to write, view, edit, copy, trash, restore, and permanently delete plain-text notes in a bottom-anchored chronological timeline without losing data across restarts.

## Scope

### Persistence

1. Add the initial `notes` and `drafts` migrations.
2. Store note IDs, bodies, creation timestamps, optional edit/deletion timestamps, and a monotonic sort key.
3. Implement focused storage operations for creating, fetching pages, editing, moving to trash, restoring, and permanently deleting notes.
4. Ensure timestamp encoding and ordering are stable across locale and time-zone changes.
5. Save and restore the composer draft without turning every keystroke into an expensive synchronous write.
6. Define transaction and error behavior so the UI never displays an unsaved note as successfully persisted.

### Interface

1. Replace the placeholder with a chronological timeline whose latest note is at the bottom.
2. Add date separators and exact, accessible timestamps.
3. Add a fixed multiline composer and visible send control.
4. Implement Slack-style `Command+Return` to send and `Return` to insert a newline, with visible and accessible help text.
5. Add note actions for copy, edit, and move to trash.
6. Add a trash view with restore and permanent-delete actions. Permanent deletion must require explicit confirmation.
7. Load notes in bounded pages and preserve visible scroll position when prepending older notes.
8. Scroll to a newly sent note only when the user was already at or near the bottom; otherwise expose an accessible “newest note” action.
9. Preserve text selection and avoid stealing keyboard or VoiceOver focus during background loads.

## Important behavior

- Whitespace-only notes without attachments are not saved.
- Editing preserves `createdAt`, updates `updatedAt`, and never changes deterministic timeline order.
- A failed save leaves the draft intact and displays a recoverable error.
- Moving a note to trash removes it from the main timeline without immediately destroying it.
- App termination or a crash must not erase the last recoverable draft.

## Non-goals

- Full-text search
- Attachments
- Link detection or previews
- Backup/export
- Rich-text or Markdown rendering
- Multiple conversations

## Acceptance criteria

- [ ] A note can be sent using both keyboard and the visible send button.
- [x] Notes remain present and correctly ordered after relaunch.
- [x] The draft survives relaunch and clears only after successful send or explicit discard.
- [ ] Edit, copy, trash, restore, and confirmed permanent delete work.
- [ ] Loading older pages does not visibly jump the current reading position.
- [ ] Sending while reading older notes does not force the user to the bottom.
- [x] Database-write failure leaves user input recoverable.
- [ ] Timeline, note actions, composer, timestamps, errors, and trash are usable with keyboard and VoiceOver.
- [x] Persistence tests cover ordering, edit semantics, trash, restore, and draft recovery.
- [x] UI tests cover send, multiline input, relaunch persistence, and keyboard focus.

## Performance fixture

Provide a test or development-only fixture generator outside production behavior. Validate scrolling and incremental loading with at least 10,000 notes without loading all note bodies into duplicated in-memory collections.

## Verification

- Run unit and UI tests.
- Test a production-like app launch against a populated fixture.
- Perform keyboard-only and VoiceOver smoke tests for compose, send, edit, trash, restore, and paging.
- Force at least one persistence error using a test database or injected failure and verify draft recovery.

## Completion notes

- **Implementation summary:** Added the Phase 1 note/draft domain and focused GRDB API; monotonic keyset paging; transactional create-and-draft-clear behavior; edit, copy, trash, restore, and confirmed permanent delete; a bottom-anchored date-separated timeline; debounced lifecycle/last-window draft recovery; Slack-style `Command-Return` send, `Return` newline, and `Command-N` focus; recoverable status/error UI; and isolated unit/XCUITest coverage. Review fixes make lifecycle draft flushes a no-op while a synchronously captured send is in flight, use SwiftUI scroll-position tracking instead of forcing the previous page boundary to the top, place an asynchronously recovered unfocused draft cursor at the end, invalidate stale list reads after mutations, refill emptied windows from stable keyset cursors, and avoid injecting out-of-window restored/trashed rows. No Phase 2-or-later feature was added.
- **Schema migrations added:** `v1_create_notes_and_drafts` creates `notes` with an `INTEGER PRIMARY KEY AUTOINCREMENT` sort key, UUID, body, UTC epoch-millisecond creation/edit/deletion timestamps, and partial active/trash paging indexes; it also creates the single-row `drafts` table.
- **Commands and checks run:** Swift 6.3.2 CLT production typecheck passed for every app source after the review fixes. A temporary ignored SwiftPM bootstrap build of GRDB 7.11.1 completed successfully; its linker emitted non-fatal missing module-cache `.pcm` debug-info warnings. Test sources passed parser validation; `plutil -lint SelfDMNotes.xcodeproj/project.pbxproj` and `git diff --check` passed. The temporary executable exercised bounded keyset pages over 10,000 notes, timeline and Trash empty-window refill, exclusion of an out-of-window restored note, the 200-row request cap, and a trigger-forced insert failure with the draft retained. Latest run: fixture insert `0.192s`, newest 50-note page `0.000625s`, previous 50-note page `0.000439s`.
- **Accessibility checks:** Added semantic labels, values, hints, exact accessible creation/edit/deletion timestamps, exposed action controls, recoverable error announcements, keyboard help, focused selection preservation, end-positioning for asynchronously recovered unfocused drafts, IME-safe model updates and Return handling, a newest-note action, and Reduce Motion handling. The older-page hint now describes only the bounded load rather than claiming an unverified visual result. XCUITests were updated to wait for async edit/trash/restore/delete outcomes and cover immediate post-send relaunch plus recovered-draft append behavior, but were not run.
- **Known issues or follow-up tickets:** Full Xcode is absent. `xcodebuild`, XCTest execution, XCUITest execution, app launch against the fixture, visual validation of the macOS 14 scroll-position preservation, keyboard-only smoke testing, and VoiceOver testing remain unverified. A prior `swift test` attempt with the CLT-only harness could not compile the XCTest target because the installed command-line toolchain has no `XCTest` module. The visual paging acceptance box intentionally remains unchecked; the other unchecked acceptance boxes also require Xcode/manual checks. There is no known production-code blocker from the checks that were available.
