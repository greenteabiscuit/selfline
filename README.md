# selfline

Selfline is a local-first macOS SwiftUI application for keeping a durable, chronological personal archive. Phase 6 supports text and attachment-only notes, one-level Slack-style reply threads, app-managed photos and ordinary files, recoverable attachment drafts, full-text/filter search, opt-in asynchronous link previews, verified whole-library backup and staged restore, app-independent JSON plus Markdown export, read-only library health checks, and redacted support-information export. First-run onboarding explains that there is no account or cloud sync, backups are essential, and preview generation has network privacy implications. Preview metadata and static thumbnails are cached locally, but generating them contacts the linked website. Automatic preview fetching is off by default and can be changed from **Settings**. Backup, restore, portable export, health checking, and support export are user-controlled local file operations and add no network behavior. Multiple conversations remain later-phase work.

## Requirements

- macOS 14 or later
- Xcode 16.3 or later
- Internet access the first time Swift Package Manager resolves GRDB.swift

The project pins GRDB 7.11.1 exactly and checks in Swift Package Manager's resolved revision for reproducible builds.

## Build and test

From the repository root, use a temporary Derived Data directory so build products never enter the source tree:

```sh
DERIVED_DATA="$(mktemp -d)"
xcodebuild \
  -project SelfDMNotes.xcodeproj \
  -scheme SelfDMNotes \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build
```

Run both unit and UI tests with:

```sh
DERIVED_DATA="$(mktemp -d)"
xcodebuild \
  -project SelfDMNotes.xcodeproj \
  -scheme SelfDMNotes \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  test
```

Open `SelfDMNotes.xcodeproj` in Xcode to build, test, or run interactively. Targets use ad-hoc local signing, the hardened runtime, and the App Sandbox so local tests exercise sandboxed path behavior without a developer certificate.

Release qualification requires more than a development build. Follow [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for clean full-Xcode test/archive commands, signing and entitlement review, manual accessibility, Instruments profiling, upgrade/rollback policy, privacy review, and the fresh-install restore rehearsal.

## Local data

The sandboxed app stores its library at:

```text
~/Library/Containers/com.selfdmnotes.SelfDMNotes/Data/Library/Application Support/SelfDMNotes/notes.sqlite
```

The logical location is always the user-domain Application Support directory plus `SelfDMNotes`. Unit tests inject a unique temporary root directly. Hosted unit tests and UI tests pass a safe identifier through `SELF_DM_NOTES_TEST_APPLICATION_SUPPORT_DIRECTORY`; the launched app resolves that identifier beneath its temporary directory. The stable identifier lets relaunch tests reopen the same isolated archive without ever opening the production path.

```text
SelfDMNotes/
├── notes.sqlite
├── attachments/
│   ├── originals/
│   └── thumbnails/
├── previews/     # Regenerable static preview PNGs
└── staging/
```

Selected files are streamed into staging and never remain dependent on their source URL. Completed staged drafts are recorded in SQLite until send or whole-draft discard commits. Managed originals are immutable and may be shared by SHA-256 while each note keeps its own attachment name. Open, reveal, and copy use independent presentation copies so another application cannot edit a managed deduplicated blob; export streams to the exact user-selected destination. See ADR-006 and ADR-007 in [ARCHITECTURE.md](ARCHITECTURE.md) for the database/filesystem recovery boundary.

Link-preview work, failures, cache metadata, refresh times, and the automatic-fetch setting are persisted in SQLite. Body edits transactionally invalidate old URL associations, and production edits are serialized with the coordinator's final pre-fetch check. Startup remains fail-closed until every active note has been reconciled. Successful metadata is reused for seven days; failed stale refreshes persist a shared request-key-wide 24-hour backoff while the old card remains visible. Cached preview images live under `previews`, use a strict lowercase UUID `.png` contract, and are safe to regenerate. Removing a preview never changes the URL in the note. Preview transport has strict DNS/redirect, timeout, content-type, body-size, image-size, cookie, credential, and proxy policies described in ADR-008 and ADR-009 in [ARCHITECTURE.md](ARCHITECTURE.md). macOS does not expose a way to bind URLSession to a separately validated DNS address, so the documented DNS-rebinding limitation still applies.

The main timeline contains root notes only. **Reply** opens a right-side thread inspector containing the root and its direct replies; reply search results navigate to that root inspector. A reply cannot itself become a thread root. Moving a root to Trash transactionally moves its currently active replies with the same deletion timestamp, and restoring the root restores exactly those replies. A reply deleted separately remains independently deleted and appears in Trash whenever its root is active. Permanently deleting a root removes every reply and their note-owned relationships, so threads cannot become orphaned.

## Health checks, diagnostics, and support

Open **About Self DM Notes** from the app menu or choose **About, Health, and Support** in Settings. This surface shows the app/build version, exact local data location, automatic-backup status, the data/privacy guide, and the in-app keyboard reference.

**Run Health Check** performs a read-only SQLite `integrity_check`, foreign-key and migration-history validation, then compares database-owned managed-file requirements with the `attachments`, `previews`, and `staging` directories. Referenced originals and completed draft copies are checked against database size and SHA-256; thumbnails and preview images are checked for safe regular-file existence. Missing, unreadable, size-mismatched, checksum-mismatched, unexpected, unsafe, and unreadable-directory counts are reported in aggregate. The check never repairs, removes, replaces, or quarantines data. If it reports an issue, preserve the Application Support folder, create a new verified backup if possible, and investigate before deleting anything. Run it again after active imports or archive operations finish to rule out a transient boundary.

Diagnostics use closed event/outcome enums and aggregate integer counts. They do not accept arbitrary error messages, note-derived strings, URLs, filenames, or paths. Unified-log messages contain only the typed event and outcome. The in-memory diagnostic ring retains at most 200 records for this process.

**Export Redacted Support Information** creates a new `com.selfdmnotes.support-information` version `1` JSON file without overwriting an existing file. It contains app/build/OS/architecture versions, schema and migration identifiers, local-only and automatic-backup summaries, the latest aggregate health report, and typed redacted diagnostics. It intentionally excludes:

- note and draft bodies
- original, managed, and user-selected folder/file names
- original, canonical, image, and other URLs
- preview titles, summaries, site names, images, and cached text
- attachment bytes and hashes
- absolute library/destination paths and security-scoped bookmarks

Backups and portable exports intentionally contain private archive content and must not be confused with redacted support information.

## Keyboard reference

Choose **Help → Keyboard Shortcuts** or press `Command-Shift-?` for the in-app reference. Core shortcuts are:

- `Command-N`: focus the note composer
- `Command-F`: find notes
- `Command-Return`: send the note
- `Return`: insert a composer newline
- `Command-Shift-A`: choose attachments
- `Command-Shift-B`: create a manual backup
- `Command-Shift-E`: export JSON and Markdown
- `Escape`: close the current transient view where supported
- `Tab` / `Shift-Tab`: move through controls

The Slack-compatible composer behavior is intentional and unchanged: `Command-Return` sends; Return alone inserts a newline.

## Backup and restore

Open **Settings** or the **Archive** menu to create a manual backup. **Settings** also accepts a sandbox security-scoped folder bookmark for automatic backups. An automatic backup is attempted after successful startup at most once every 24 hours. Every backup is first built at a unique hidden partial path, then published without overwriting another item only after full verification.

A `.selfdmbackup` package has format identifier `com.selfdmnotes.backup`, format version `1`, and this layout:

```text
Self DM Notes … .selfdmbackup/
├── manifest.json
└── library/
    ├── notes.sqlite                 # GRDB/SQLite online-backup snapshot; no copied WAL
    ├── attachments/
    │   ├── originals/
    │   └── thumbnails/
    ├── previews/
    └── staging/                     # Persisted attachment-draft files
```

`manifest.json` records the format/version, backup UUID and manual/automatic kind, UTC creation milliseconds, app/build versions, database schema version and ordered migration identifiers, and a lexicographically sorted file inventory. Every inventory record contains a safe relative path, byte count, lowercase SHA-256, and role. Verification rejects unknown or missing entries, traversal, aliases/symlinks, canonical filename collisions, incompatible/newer schemas, checksum mismatches, database/file inventory disagreements, broken foreign keys, and any SQLite `integrity_check` failure. Managed originals and draft files must also match the hashes and sizes stored in SQLite. Before publication, every file is synchronized and every modified package directory is synchronized deepest-first, followed by the package and destination directories. A backup is never reported successful before the final published package passes those checks again.

**Automatic retention policy:** retain the newly created verified automatic backup plus up to the six newest other verified automatic backups (at most seven total). Pinning the new package means clock regression or equal timestamps cannot immediately rotate it away. Rotation starts only after the new package verifies; manual, partial, corrupt, incompatible, and non-package items are not candidates. A rotation failure never removes any of those seven-or-fewer retained packages. Existing packages are not changed when automatic backup is disabled.

Restore treats the selected package as hostile. It validates the manifest and exact package shape, copies each file through `O_NOFOLLOW` into a private sibling quarantine while rechecking size/hash and source stability, then repeats SQLite and relationship validation. Only then is `library/` moved into same-volume restore staging and an fsynced versioned recovery journal armed. The running library has not changed at this point; **Cancel Pending Restore** removes staging through a resumable cancellation state, while **Quit and Restore** lets the next launch perform the atomic switch.

Before any SQLite connection opens, startup uses same-volume `RENAME_SWAP` to exchange the active and staged directory in one filesystem operation and moves the original to a rollback location. The restored library then performs its full SQLite integrity/foreign-key scan, timeline/draft hydration, attachment maintenance, and link-preview startup maintenance in the asynchronous startup gate before a committed journal permits rollback deletion. If that trial fails or a process exits before confirmation, the next launch atomically restores the original before opening SQLite. Pre-open recovery validates and chooses the safe winner; potentially large unarmed, canceled-staging, and committed-counterpart deletions are resumed afterward on detached work while every library mutation remains disabled. Cleanup failure requests another relaunch and preserves the typed outcome: a durable `committed` state never promises that the retained counterpart can be rolled back. Armed, trial, rollback-requested, cancellation-requested, unarmed-cleanup, and committed-cleanup states are idempotent across interruption. Ambiguous state fails closed, pauses preview/background mutation, and preserves both copies. A backup from a newer or different migration history is rejected; Phase 5 does not migrate backup packages during restore.

## Portable export format

**Export JSON and Markdown** creates a `.selfdmexport` directory with format identifier `com.selfdmnotes.portable-export`, version `1`:

```text
Self DM Notes Export … .selfdmexport/
├── manifest.json
├── export.json
├── notes.md
└── attachments/
    └── copied original files
```

The sorted manifest checksums and assigns a role to `export.json`, `notes.md`, and every copied original. `export.json` contains `formatIdentifier`, `formatVersion`, `exportID`, `exportedAtMilliseconds`, and notes in ascending SQLite `sortKey` chronology. Each note preserves its UUID, nullable thread-root UUID, body, creation/edit/deletion milliseconds, sort key, link-preview revision, nested attachment relationships, and nested preview relationships. Attachments preserve UUID, original filename, exported relative path, media type, byte size, dimensions, SHA-256, creation milliseconds, and order. Preview records preserve UUID, original/canonical/remote-image URLs, request key, status/failure, created/updated/next-fetch/fetched/retry timestamps, reconciled revision, title, summary, and site name.

`notes.md` represents the same chronology with explicit Active/Trash state, timestamps, note and thread-root IDs, fenced note text, attachment links and hashes, and URL/preview metadata. Original attachment names remain in JSON and Markdown labels. Filesystem-unsafe characters are replaced only in copied filenames; canonical collisions receive the stable attachment UUID, with a deterministic numeric fallback, so no bytes are overwritten. Cached preview PNGs and unfinished drafts are intentionally omitted from the portable export: preview images are regenerable remote derivatives, while drafts are not notes. They remain included in restorable backups. Phase 5 does not import the portable format.

## Project structure

```text
SelfDMNotes/
├── App/          # SwiftUI application entry point
├── Domain/       # Product-facing state with no storage dependency
├── Persistence/  # Application Support paths, GRDB connection, migrations
├── Services/     # Application composition and startup
├── UI/           # SwiftUI views
└── Resources/    # App Sandbox entitlements
```

UI code does not access SQL. `AppEnvironment` owns the database, attachment store, link-preview coordinator, restore-recovery coordinator, and archive service for the application lifetime, while tests construct them with isolated paths and injected transports. Restore recovery runs before `AppDatabase` is constructed. Add migrations only through `DatabaseMigrations.makeMigrator()` and never modify a migration after it has shipped.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the Phase 0 decisions and boundaries.

## Accessibility smoke test

After launching the app:

1. Press `Command-N` to focus **Write a note**, type multiple lines with `Return`, and send with `Command-Return`. Repeat with the visible **Send** button.
2. Press `Command-F`, search ordinary text, punctuation, Unicode, emoji, and a no-results query, then select an older result and use **Newest note** to return. Confirm `Escape` closes search and returns composer focus.
3. Use Tab and Shift-Tab to reach search sorting/date controls, **Trash**, note action menus, draft controls, and paging controls. Confirm visible focus in light, dark, and increased-contrast appearances.
4. With VoiceOver enabled (`Command-F5`), confirm search counts, match labels, selected-result context, date separators, note text, exact creation timestamps, action menus, status errors, the composer help text, and Trash controls have meaningful announcements.
5. Complete edit, copy, move-to-Trash, restore, and permanent-delete confirmation using only the keyboard. Confirm background paging, search, and sending while reading older notes do not move keyboard or VoiceOver focus unexpectedly.
6. Enable Reduce Motion and confirm newest-note navigation does not animate.
7. Press `Command-Shift-A`, choose image and ordinary files, cancel a large import, retry a failed import, remove a pending item, and send an attachment-only note. Repeat by dropping files and pasting a clipboard image.
8. Use only the keyboard and VoiceOver to preview, open, reveal, export, and copy timeline attachments. Confirm malformed images use a generic file card, missing originals announce an actionable error, and attachment/image search filters are understandable without color.
9. Open **Settings** and confirm automatic previews are initially off and the network privacy explanation is clear. Enable them, save HTTP/HTTPS links, then exercise pending, ready, failed, Retry, Remove preview, Open link, and Copy link states using keyboard and VoiceOver. Confirm the original URL remains readable and removing a card does not edit the note.
10. Disable automatic previews while requests are pending and confirm no new cards fetch until re-enabled. Search preview title/description/site/URL text and use **Has Link**. Confirm background completions do not move keyboard/VoiceOver focus or timeline scroll.
11. In **Settings**, use Tab/Shift-Tab and VoiceOver to choose an automatic backup folder, disable automatic backup, run **Back Up Now…**, run **Export JSON and Markdown…**, and cancel a long operation at its next safe boundary. Confirm progress and completion/error banners update without moving focus. Verify `Command-Shift-B` and `Command-Shift-E` invoke the menu actions.
12. Choose a corrupt backup and confirm it is rejected before any quit prompt. Stage a valid backup, verify **Quit and Restore** and **Cancel Pending Restore** are keyboard/VoiceOver reachable, cancel once, then stage again and relaunch. Confirm the restored archive appears; separately interrupt an unconfirmed trial and verify the original library is recovered on the following launch. Inspect JSON and Markdown plus duplicate-named attachments in Finder or another editor without Self DM Notes.
13. On a fresh isolated installation, review onboarding with keyboard and VoiceOver. Confirm it explains local-only storage, no cloud sync, backups, preview privacy, restore, health checks, and redacted support export before focusing the composer.
14. Press `Command-Shift-?`, traverse the complete shortcut reference, close it with Escape, and confirm composer focus returns. Open **About Self DM Notes**, verify version/data location/backup status, run Health Check, and confirm the aggregate result is announced without exposing filenames.
15. Export redacted support information to a new file, parse the JSON independently, and scan it for known sentinel note text, URLs, original filenames, preview metadata, attachment bytes/hashes, and absolute paths. Confirm an existing destination is not overwritten and low-disk/read-only/revoked-access failures leave no partial destination.

XCUITest sources include the earlier timeline/search workflows plus clipboard attachment-only capture, filename search, the attachment-picker shortcut, link-preview settings, link actions, **Has Link** search, onboarding, shortcut reference, About, and health-check discovery. Network unit tests use injected DNS and `URLProtocol` stubs only; they never require public internet access. Archive and support tests use unique temporary fixture roots and never production Application Support. A full-Xcode run and manual keyboard, Quick Look, drag/drop, archive panels, restore relaunch, export, link-card, visual, announcement, reflow, onboarding, support, and VoiceOver smoke test remain required for release verification.
