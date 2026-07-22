# Phase 3 — Managed Photos and File Attachments

- **Status:** Implemented; full-Xcode and interaction acceptance pending
- **Depends on:** Phase 2
- **Produces:** Durable app-managed images and file attachments

## Goal

Let users supplement notes with photos and ordinary files while ensuring the archive does not depend on the original files remaining in place.

## Scope

### Storage and metadata

1. Add attachment metadata migrations and focused persistence operations.
2. Create managed directories for originals, thumbnails, and staging under the app's application-support library.
3. Copy selected files into staging, validate them, commit metadata, and atomically move them to final storage.
4. Clean abandoned staging files on startup and detect/report database records whose files are missing.
5. Calculate a content hash while copying. Reuse stored bytes where safe while preserving separate logical attachment records.
6. Generate thumbnails asynchronously with bounded memory use. Preserve originals unchanged.
7. Store original filename, media type, byte size, image dimensions when available, content hash, and creation timestamp.
8. Define deletion behavior so shared deduplicated bytes are removed only when no attachment references them and the containing notes are permanently deleted.

### Capture and display

1. Add a visible attachment picker and `Command+Shift+A` shortcut.
2. Support drag-and-drop into the composer.
3. Support pasting images from the clipboard.
4. Show pending attachments before send, with accessible remove and retry actions.
5. Permit attachment-only notes.
6. Display image thumbnails and file cards in the timeline without blocking scrolling.
7. Open originals using Quick Look or a similarly native, keyboard-accessible viewer.
8. Add actions to copy, reveal, or export an attachment.
9. Include original filenames in search and activate the Phase 2 attachment/image filters.

## Safety and resilience

- Use security-scoped access only for the time required to copy a user-selected file.
- Never retain permissions or paths to the source as the archive's primary storage.
- Large files must copy and hash off the main actor with visible progress/cancellation where needed.
- A failed attachment import must not silently create a note that appears complete.
- Rendering malformed or unsupported files must degrade to a generic file card.

## Non-goals

- Editing photos
- OCR
- Searching within PDFs or office documents
- Cloud upload or synchronization
- Audio/video playback beyond normal system handling

## Acceptance criteria

- [ ] Images and ordinary files can be selected, dropped, and—where applicable—pasted.
- [ ] Attachment-only notes can be saved.
- [x] Deleting or moving the original source file does not affect the archived attachment.
- [ ] Photos display efficient thumbnails and open at original quality.
- [ ] Large attachment processing does not freeze the main interface.
- [x] Failed imports remain recoverable and explain what happened.
- [x] Duplicate content does not unnecessarily duplicate stored bytes, and reference deletion is correct.
- [x] Startup maintenance identifies abandoned staging and missing managed files safely.
- [x] Attachment filenames participate in search; image and attachment filters work.
- [ ] Picker, pending items, progress, errors, file cards, image descriptions, viewer, and actions are keyboard and VoiceOver usable.
- [x] Tests cover staging transactions, deduplication, cleanup, failed copy, deletion references, and metadata persistence.

## Verification

- Run unit and UI tests using isolated temporary libraries.
- Test small and large JPEG/PNG/HEIC files, a PDF, a generic file, duplicate content under different names, and a malformed file.
- Remove original source files and relaunch to prove archive independence.
- Simulate interruption during staging and verify startup cleanup.
- Perform keyboard-only and VoiceOver flows for picker, pending removal, send, preview, and export.

## Completion notes

- **Implementation summary:** Streamed, cancellable SHA-256 staging with attempt-safe retry/removal settlement; required manifest restoration before best-effort startup cleanup; persisted completed attachment drafts with fail-closed manifest matching; atomic whole-draft discard with latest-visible-text recovery on failure followed by recoverable file cleanup; blob/reference deduplication; transactional attachment-only send with pending mutation locked during commit; bounded ImageIO thumbnails; startup recovery/reporting; final-reference deletion; picker, drag/drop, clipboard image capture, pending states, timeline cards, Quick Look plus isolated open/reveal/copy presentations and exact-selected-URL export; filename and attachment/image search.
- **Schema migrations added:** `v3_create_managed_attachments` rebuilds `notes` without the text-only constraint while preserving the AUTOINCREMENT high-water mark, then adds `attachment_blobs`, `attachments`, and `draft_attachments`. `v4_index_attachment_filenames` rebuilds one-row-per-note FTS with aggregated filenames and note/attachment lifecycle triggers.
- **Managed file layout:** `attachments/originals`, `attachments/thumbnails`, and `staging` under the injected library root. Originals and <=512-pixel PNG thumbnails use opaque managed names; original user filenames remain logical attachment metadata.
- **Commands and checks run:** Full-source `swiftc -parse`; CLT SwiftPM full app-source build; the original temporary-root Phase 3 probe; and a focused release-blocker probe covering cleanup failure after manifest restoration, unreadable-manifest composition blocking, completed/active/removed-import whole-draft discard, latest-visible-text recovery after discard rollback, exact-destination export, managed-original export isolation, and pending-mutation guards during a 32 MiB send. `swift test --filter AttachmentPersistenceTests` remains unavailable because this Command Line Tools SDK has no importable `XCTest` module. Plist/XML/JSON/project/diff checks are rerun at handoff. No production or preview library was opened.
- **Accessibility checks:** Labels, values, hints, focusable native controls, progress, cancel/retry/remove, inline errors, card actions, and keyboard commands are implemented. XCUITest source covers clipboard attachment-only send/search and `Command-Shift-A`; XCUITest, keyboard-only, VoiceOver, Quick Look, drag/drop, export, and visual checks were not run because full Xcode and interaction are unavailable, so interaction-only acceptance remains unchecked.
- **Known issues or follow-up tickets:** Full Xcode must run the unit/UI suites and interactive acceptance before closing the phase. Missing thumbnails are reported and degrade to a generic/failed-thumbnail card; originals and metadata remain unchanged. Link behavior remains Phase 4 and no network entitlement was added.
