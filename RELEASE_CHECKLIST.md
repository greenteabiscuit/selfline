# Self DM Notes Release Checklist

This checklist separates repository evidence from gates that require full Xcode, signed release credentials, Instruments, assistive technologies, and manual app interaction. Complete every pending gate on the intended release hardware before distributing a build.

## Protect the current library first

1. Do not profile, fault-inject, or rehearse restore against a real user library. Use a fresh macOS test account or an app build with a unique bundle identifier and a unique temporary Application Support root.
2. From the current production app, create a new manual `.selfdmbackup` package and wait for the app to report it verified.
3. Copy that package to a second physical volume or independently protected location. Keep at least one known-good package made by the currently installed app.
4. Create a portable JSON and Markdown export for app-independent inspection. Portable export is not a restorable backup and cannot currently be imported.
5. Record the releasing app version, build number, schema version, and migration identifiers. Never edit a shipped migration.

## Clean build, test, and archive — full Xcode required

Use an unmodified clean checkout and a newly created Derived Data directory. Do not reuse the repository’s local `DerivedData` folder.

```sh
git status --short
DERIVED_DATA="$(mktemp -d)"
xcodebuild \
  -project SelfDMNotes.xcodeproj \
  -scheme SelfDMNotes \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  clean test
```

Then create the production archive with the intended signing team and identity:

```sh
ARCHIVE_PATH="$(mktemp -d)/Self DM Notes.xcarchive"
xcodebuild \
  -project SelfDMNotes.xcodeproj \
  -scheme SelfDMNotes \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  clean archive
```

Before accepting the archive:

- Confirm the app and test targets resolved the checked-in GRDB 7.11.1 revision.
- Confirm Release uses the intended version/build, hardened runtime, App Sandbox, and distribution signing—not the repository’s ad-hoc development identity.
- Inspect the archived entitlements. Expected capabilities are App Sandbox, user-selected read/write files, app-scoped security bookmarks, and outbound network client access. No inbound network, contacts, calendar, photos-library, microphone, camera, location, or cloud entitlement is expected.
- Confirm ATS arbitrary loads remain present only because user-authored `http://` previews are supported and that automatic preview fetching still defaults off.
- Run signature and notarization validation required by the distribution channel. Launch the exported/notarized artifact, not only the development build.

## Automated and isolated fault gates

Run the complete XCTest and XCUITest suite from the clean build. Confirm every test root is unique and removed. In particular, retain coverage for:

- SQLite integrity/foreign-key/migration checks and missing, corrupt, unreadable, unexpected, and unsafe managed-file reporting.
- Redacted support JSON sentinel scans proving note bodies, drafts, URLs, preview metadata, original filenames, attachment bytes/hashes, absolute paths, and backup folder names are absent.
- Simulated `ENOSPC`, `EROFS`, and `EACCES` failures before support-file publication, with no destination or partial file left behind.
- Backup and restore interruption states, cancellation, rollback, stale bookmark/revoked access, package corruption, symlinks, traversal, and source changes.
- Attachment staging/import interruption, deduplication, missing/corrupt originals, presentation-copy isolation, and safe cleanup.
- Preview timeout/offline/malformed/size/redirect/DNS policy failures with injected transports only; automated tests must not contact public sites.

Run any executable probe only under a generated temporary root. Verify the root and all scratch build products are absent afterward.

## Manual accessibility and interaction matrix

Run every workflow listed in `tickets/06-accessibility-resilience-and-polish.md` with keyboard only, then with VoiceOver. Repeat practical window resizing and text reflow checks in light, dark, increased-contrast, Reduce Motion, and Differentiate Without Color configurations.

Explicitly verify:

- `Command-Return` sends, Return inserts a newline, and `Command-N` focuses the composer.
- Tab/Shift-Tab traversal, visible focus, menu/action discoverability, Escape behavior, sheet focus restoration, and the in-app shortcut reference.
- Status/error, search-result count, attachment completion/failure, and health-result announcements do not interrupt excessively or steal focus.
- Exact spoken creation/edit/deletion timestamps, filenames, URLs, progress, empty states, and actionable errors are concise and unambiguous.
- Loading older notes, preview completion, automatic backup, health checking, and thumbnail loading do not move keyboard/VoiceOver focus or timeline position.
- Controls remain operable and content reflows at the smallest supported main window and practical enlarged text settings. State remains understandable without color.
- Choose/drop/paste/remove/send/open/reveal/export attachment flows, Quick Look, native panels, settings, Trash confirmations, backup/restore/export, onboarding, About, and support export.

Record macOS version, hardware, display/scaling, assistive settings, app version/build, and pass/fail evidence. Source modifiers and unexecuted XCUITest are not manual accessibility evidence.

## Profiling and performance gates

Use Instruments and a representative isolated fixture, including at least 100,000 notes plus attachment and preview examples. Record hardware, macOS, build configuration, fixture generation, and cold/warm conditions.

- Launch to usable timeline: inspect wall time, main-thread stalls, database work, and initial memory.
- Timeline: newest page, repeated older-page loads, scroll hitching, and memory growth.
- Composer: typing, multiline editing, draft debounce, attachment paste, and `Command-Return` responsiveness while background work runs.
- Search: common, rare, Unicode, emoji, date, attachment, image, and link filters. The deterministic database budget is under one second per bounded page/search probe on recorded reference hardware; manual UI responsiveness still requires profiling.
- Thumbnails/previews: confirm file reads and decode work remain off the main actor and memory drops after cards leave the working set.
- Backup/export/health: record duration, throughput, memory, cancellation latency, and composer/UI responsiveness for a large library with real managed files.

Do not “fix” a one-off debug-build measurement. Capture a repeatable release-build trace before changing stable architecture.

## Fresh-install and restore rehearsal

Use a disposable macOS account or separately identified app build. Never point the rehearsal at the production container.

1. Install and launch the signed artifact with no existing container. Complete onboarding and verify automatic previews and automatic backups start off.
2. Create text, multiline, attachment-only, Unicode, edited, trashed, successful-preview, failed-preview, and recoverable-draft examples. Exercise paging/search and create a verified backup plus portable export.
3. Quit. Preserve the disposable source root for comparison; do not manually copy it into the destination.
4. Reset only the disposable app/container, relaunch as a fresh installation, choose the verified backup, validate, stage, and choose **Quit and Restore**.
5. Relaunch and confirm startup acceptance, exact notes/timestamps/trash state, draft, attachments/hashes, preview state, search, and settings. Run Health Check and require a healthy result.
6. Separately interrupt an unconfirmed restore trial, relaunch, and confirm the original disposable library is automatically restored before SQLite opens.
7. Open the portable JSON/Markdown and duplicate-named attachments in independent tools. Confirm they remain usable without Self DM Notes.

## Upgrade, rollback, and migration policy

- Startup applies only registered forward GRDB migrations. Back up before first launch of a new schema version and verify migration on a copy during release qualification.
- A backup from a newer or different migration history is rejected. This release does not migrate backup packages during restore.
- Rolling the app binary back after it has migrated the active database is not supported unless the older binary is known to understand that exact schema. Do not open a newer active library with an older app merely to test rollback.
- To roll back safely, restore the pre-upgrade verified backup using a compatible app/recovery process in a disposable rehearsal first. Preserve the newer library and exports until comparison succeeds.
- Portable JSON/Markdown is an app-independent escape hatch, not an import or schema rollback mechanism.
- Any new migration requires fixture coverage from every previously shipped schema, backup/restore compatibility decisions, interruption testing, and an updated release rehearsal.

## Final privacy review

- Inspect support JSON and unified logs from capture, preview, backup, restore, export, health, and failure workflows. Typed diagnostics may contain event names, outcomes, timestamps, and aggregate counts only.
- Confirm support JSON does not contain note/draft text, URLs, preview title/summary/site, original or managed filenames, attachment bytes/hashes, absolute paths, user-selected folder names, or security-scoped bookmarks.
- Confirm backup and portable export are intentionally private-content-bearing user exports and are never confused with redacted support information.
- Inspect network traffic: only explicit open-link actions and enabled preview fetching may contact destinations. Preview requests must remain cookie-, credential-, script-, cache-, and proxy/PAC-free within the documented platform limits.
- Confirm no fixture, package, screenshot, trace, diagnostic file, signing secret, generated data, or scratch directory remains in the repository.

Release only when clean tests, signed archive, manual accessibility matrix, profiling, privacy review, and fresh restore rehearsal all have recorded passing evidence.
