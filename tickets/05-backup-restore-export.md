# Phase 5 — Backup, Restore, and Portable Export

- **Status:** Complete (full-Xcode and manual release checks pending)
- **Depends on:** Phase 4
- **Produces:** Verified recovery and app-independent archive formats

## Goal

Ensure the archive cannot be lost to an application bug, device migration, or retention policy and remains usable without Self DM Notes.

## Scope

### Backup

1. Define and version a backup manifest containing database/schema version, creation time, application version, file inventory, and checksums.
2. Create a consistent SQLite snapshot using supported SQLite/GRDB backup behavior rather than copying a live database file unsafely.
3. Include every referenced original, thumbnail if useful, and cached preview image only if required for faithful restore.
4. Allow the user to choose a backup destination using sandbox-safe persistent access.
5. Add automatic rotating backups with a documented retention policy and a manual “Back Up Now” action.
6. Verify checksums and database integrity before declaring a backup successful.
7. Report partial or failed backups clearly without deleting the last known-good backup.

### Restore

1. Validate manifest version, checksums, required files, and database integrity before changing the active library.
2. Restore through a staged location and atomically switch only after validation succeeds.
3. Keep a recoverable copy of the pre-restore library until the restored app launches successfully.
4. Define behavior for backups created by newer app/schema versions.
5. Provide progress, cancellation when safe, and clear remediation for corrupted archives.

### Export

1. Export a versioned JSON representation containing notes, timestamps, edit/deletion state, URLs, preview metadata, and attachment relationships.
2. Export human-readable Markdown organized chronologically with stable relative links to copied original attachments.
3. Preserve original attachment filenames while resolving collisions safely.
4. Include an export manifest and document the format in the project README.
5. Export should be readable without installing Self DM Notes.

## Non-goals

- Cloud synchronization or merge conflict resolution
- Encrypted remote backup service
- Time Machine integration beyond compatibility with normal macOS behavior
- Importing arbitrary third-party note formats
- Slack export import

## Acceptance criteria

- [x] Manual and automatic backups include all live notes and referenced originals consistently.
- [x] A backup is not reported successful until checksums and database integrity pass.
- [x] Rotation never removes the last known-good backup.
- [x] A fresh app library can restore a backup and reproduce notes, timestamps, links, previews, and attachments.
- [x] Corrupt or incomplete backups are rejected before modifying the current library.
- [x] An interrupted restore leaves the original library usable.
- [x] JSON export is documented, versioned, and machine-readable.
- [x] Markdown export is human-readable and opens attachments through relative paths.
- [x] Duplicate original filenames are exported without data loss.
- [x] Backup, restore, and export flows are keyboard and VoiceOver accessible, including progress and errors.
- [x] Automated round-trip tests compare source and restored/exported fixtures.

## Verification

- Run unit and UI tests using a fixture containing edited notes, trash, multiple attachment types, duplicate filenames, duplicate bytes, successful/failed link previews, and Unicode.
- Restore into an empty temporary library and compare all logical records plus original-file hashes.
- Corrupt the database, manifest, and individual files in separate test copies and verify safe rejection.
- Interrupt backup and restore at controlled points and verify cleanup/recovery.
- Open the Markdown export outside the app and parse the JSON export independently.

## Completion notes

- **Implementation summary:** Added `ArchiveService`, archive domain/progress state, a pre-open `RestoreRecoveryCoordinator`, GRDB online snapshot/integrity APIs, automatic folder bookmarks, Archive menu commands, settings controls, progress/error/recovery banners, and deterministic archive tests. Restore copies a selected package to private quarantine, validates and synchronizes its complete directory tree deepest-first, arms a durable sibling journal, and switches only at the next pre-SQLite launch with same-volume `RENAME_SWAP`. The original remains the rollback root through detached integrity/foreign-key checks, timeline/draft hydration, attachment maintenance, and link-preview startup confirmation. One fail-closed mutation gate covers notes, drafts, attachments, previews, archive actions, and restore actions; the preview actor also drains and rejects mutation while paused. Pre-open recovery chooses the safe winner, while potentially large unarmed/canceled/committed cleanup runs detached with visible status. Typed committed cleanup never promises rollback. Armed, trial, rollback, cancellation, uncertain-journal, unarmed-cleanup, and committed-cleanup interruption paths preserve a recoverable winner and fail closed on ambiguity.
- **Backup format and retention policy:** `com.selfdmnotes.backup` version `1`; `.selfdmbackup` directory containing a sorted/checksummed `manifest.json` and `library/` with an online-backup `notes.sqlite` plus every database-referenced original, thumbnail, preview PNG, and persisted attachment-draft file. Validation enforces strict relative path/role allowlists, canonical collision and symlink rejection, exact entries, source stability, schema/migration compatibility, checksums, database/file relationships, foreign keys, and SQLite integrity. Automatic backup runs at most every 24 hours after successful startup. Rotation pins the new verified automatic package and retains up to the six newest other verified automatic packages; manual, partial, invalid, incompatible, and unrelated items are never candidates. Rotation begins only after final verification and never deletes the retained seven-or-fewer set.
- **Export format version:** `com.selfdmnotes.portable-export` version `1`; `.selfdmexport` directory containing sorted/checksummed `manifest.json`, `export.json`, deterministic `notes.md`, and copied originals under stable relative `attachments/` paths. JSON preserves ascending sort chronology, note IDs/body/create/edit/trash timestamps/link revision, nested attachment IDs/names/type/size/dimensions/hash/time/order, and nested URL/preview status/failure/cache metadata/timestamps. Markdown is regenerated from and byte-checked against JSON. Unsafe filename characters are replaced and canonical collisions append the attachment UUID, then a deterministic numeric fallback. Cached preview PNGs and unfinished drafts remain backup-only; portable import is not part of Phase 5.
- **Round-trip results:** A removed-after-use CLT executable probe ran entirely under a generated temporary fixture root. It created edited/trashed notes, successful and failed preview metadata, two different originals with the same logical filename, and then passed verified backup/export round trip, duplicate-name byte comparison, attachment corruption rejection before arming, restore staging without active mutation, interrupted-trial automatic rollback to a post-backup original note, deferred interrupted-cancellation and committed cleanup, and clock-regression retention pinning. `ArchiveServiceTests.swift` adds deterministic temporary-root XCTest sources for those cases plus checksum-valid corrupt SQLite, traversal, symlink, confirmed restore, Unicode, unarmed cleanup deferral, and manifest/inventory assertions. `LinkPreviewTests.swift` verifies restore pause rejects coordinator edits/removals until explicit safe resume.
- **Commands and checks run:** Full product-source `swiftc -typecheck -parse-as-library` with the resolved GRDB module; all Swift source parse including the new XCTest source; temporary CLT production probe compile/link/run against the resolved GRDB objects; `plutil -lint` for the entitlements and Xcode project; JSON validation for `Package.resolved`; and `git diff --check`. The probe directory, source, and binary were removed. Apple Command Line Tools do not provide `xcodebuild` or XCTest here, so no full XCTest/XCUITest run is claimed.
- **Accessibility checks:** New settings and status UI uses native labeled buttons/toggles/progress, explicit accessibility identifiers/hints/values, keyboard traversal, `Command-Shift-B` manual backup, `Command-Shift-E` portable export, safe-boundary cancellation, destructive restore confirmation, and reachable Quit/Cancel/Resolve actions. Operations run detached and update status without focus requests. Source typechecking passed; manual VoiceOver, focus, panel, relaunch, and visual checks remain pending on full Xcode/macOS release hardware.
- **Known issues or follow-up tickets:** Full Xcode build, XCTest/XCUITest, sandbox bookmark persistence, manual keyboard/VoiceOver, native panel, actual app-termination/relaunch, and filesystem visual checks remain release gates because this machine has CLT only. Portable exports intentionally omit regenerable cached preview images and unfinished drafts and cannot be re-imported in Phase 5. Restore requires the exact Phase 5 migration history; older/newer package migration is intentionally unsupported. No Phase 6 work was started.
