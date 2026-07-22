# Phase 6 — Accessibility, Resilience, and Release Polish

- **Status:** Needs review (implementation and CLT validation complete; full-Xcode and manual release gates pending)
- **Depends on:** Phases 0–5
- **Produces:** A release candidate suitable for daily personal use

## Goal

Audit the complete application as one experience, close accessibility and reliability gaps that component-level work could not expose, and prepare a trustworthy first release.

## Scope

### Accessibility audit

1. Complete every core workflow using only the keyboard.
2. Complete every core workflow with VoiceOver, including note capture, paging, search, result navigation, attachments, link cards, trash, backup, restore, and export.
3. Verify focus order, focus restoration, visible focus, announcements, rotor usefulness, action discoverability, and non-interference from background updates.
4. Verify system font sizing, window resizing, text reflow, light/dark appearance, increased contrast, reduced motion, and color-independent state communication.
5. Check that timestamps, filenames, links, progress, empty states, and errors are concise but unambiguous when spoken.
6. Review keyboard shortcuts for conflicts and provide an in-app shortcut reference.

### Resilience and integrity

1. Exercise abrupt termination during note save, draft save, attachment import, thumbnail generation, preview fetch, backup, and restore.
2. Run database integrity and managed-file consistency checks with user-actionable reporting.
3. Confirm staging cleanup never removes a valid referenced file.
4. Confirm low disk space, read-only destination, revoked folder access, offline mode, malformed data, and permission failures degrade safely.
5. Ensure diagnostic logging is useful while excluding note bodies, URLs, filenames, and other private content by default.
6. Add a safe support-information export containing versions and redacted diagnostics only.

### Performance and release readiness

1. Profile launch, timeline paging, composer responsiveness, search, thumbnail loading, memory use, and backup with representative large fixtures.
2. Remove avoidable main-thread file, hashing, parsing, database, and image work.
3. Verify app sandbox, entitlements, privacy descriptions, code signing, release configuration, and archive build.
4. Add onboarding that explains local storage, backups, link-preview privacy, and the absence of cloud sync.
5. Add an About/support surface containing app version, data location, backup status, and documentation links.
6. Document upgrade, rollback, data migration, and release-check procedures.

## Required workflows to audit

- Create, edit, copy, trash, restore, and permanently delete a text note
- Preserve and recover a draft
- Load older notes and return to newest
- Search, filter, select a result, and return to the timeline
- Select, drop, paste, remove, send, open, reveal, and export attachments
- View, disable, remove, retry, open, and copy link previews
- Create, verify, rotate, restore, and recover from a failed backup
- Export JSON and Markdown

## Non-goals

- New organizational features
- Multi-device sync
- OCR or semantic search
- iOS support
- Redesigning stable architecture without a measured problem

## Acceptance criteria

- [ ] Every required workflow is usable with keyboard only.
- [ ] Every required workflow is understandable and operable with VoiceOver.
- [ ] No background operation steals focus or unexpectedly changes timeline position.
- [ ] Text remains readable and controls remain operable across supported system accessibility appearances and practical window sizes.
- [ ] Forced interruption tests leave the active library valid or recoverable.
- [x] Integrity checks identify seeded database/file inconsistencies without damaging healthy data.
- [x] Logs and support exports contain no private note or attachment content by default.
- [x] Large-fixture performance budgets are documented and met on recorded hardware, or exceptions are explicitly accepted.
- [ ] All automated tests pass from a clean checkout.
- [ ] A signed release archive builds with production configuration.
- [x] README and in-app guidance explain storage, backup, restore, export, privacy, and limitations.
- [ ] A fresh installation and restore rehearsal succeeds before release.

## Verification

- Run the full automated suite and a clean release build/archive.
- Perform the required workflow matrix with keyboard, VoiceOver, increased contrast, reduced motion, light/dark mode, and larger text settings.
- Run large-library profiling and record launch, search, paging, memory, and backup measurements.
- Run fault-injection and fresh-install restore rehearsals.
- Complete a final privacy review of network requests, logs, exported support data, and entitlements.

## Completion notes

- **Implementation summary:** Added first-run local-only/backup/no-sync/preview-privacy onboarding; About, data/privacy, keyboard-reference, library-health, and redacted-support surfaces; explicit focus restoration and VoiceOver announcements for stable status/search/attachment/health transitions; and asynchronous link-preview thumbnail decoding off the main actor. `Command-Return` send, Return newline, and `Command-N` composer focus remain on their existing paths. Health checking reads the already-open SQLite queue through the production archive inspector, checks database path identity, pauses/drains preview work behind the timeline mutation gate, and anchors all managed-directory/file reads to `openat` descriptors without following symlink components. Typed diagnostics accept only closed event/outcome enums, timestamps, and fixed aggregate metrics. Support JSON publishes owner-only to a new destination with exclusive rename and cannot represent note/draft text, URLs, filenames, paths, preview metadata, attachment bytes/hashes, or bookmarks. Added deterministic XCTest/XCUITest source and `RELEASE_CHECKLIST.md`; documented privacy, upgrade/rollback/migration, clean build/test/archive, profiling, and fresh-restore procedures.
- **Accessibility audit results:** Static code audit covered every current UI workflow. High-confidence gaps closed include editor and post-sheet focus, selected-result/note focus, exact complete spoken create/edit/delete/search-result timestamps, filename/link/status/error values, non-color state labels/symbols, grouped cards/banners, search/result and attachment announcements, progress announcement throttling, Reduce Motion preservation, native system fonts/controls, flexible support/settings sheet sizing, and discoverable menu/control alternatives. Manual keyboard traversal, visible-focus order, VoiceOver/rotor/action behavior, announcement interruption, larger text, practical reflow, light/dark, increased contrast, Differentiate Without Color, and reduced-motion acceptance remain unchecked because no GUI/assistive-technology run was available.
- **Performance measurements and hardware:** A removed-after-use SwiftPM/CLT executable compiled real production persistence/archive/support code against resolved GRDB 7.11.1 and used a generated temporary root. On Apple M1 Max, 64 GiB RAM, macOS 26.5.1 (25F80), Apple Swift 6.3.2, debug build: inserting 100,000 fixture notes took 19.089 s; newest 50-note page 0.002968 s; older page 0.002522 s. Seven-run searches: common 100,000-result query median 0.530736 s/worst 0.552781 s; rare query median 0.001700 s/worst 0.002211 s; Unicode query median 0.017826 s/worst 0.020762 s; emoji query median 0.208262 s/worst 0.267678 s. The documented deterministic database budget is under 1 s per bounded page/search probe and passed. This is not release profiling: launch, composer, scrolling, memory, backup/export/health throughput, and UI responsiveness still require a Release archive plus Instruments/manual evidence.
- **Fault-injection/recovery results:** The isolated production probe passed healthy read-only checking; checksum corruption, missing referenced file, unexpected file, managed-directory symlink, malformed database, and substituted database-path detection; unchanged inconsistent/external bytes; private-sentinel support JSON scan; existing-destination no-overwrite; and injected `ENOSPC`, `EROFS`, and `EACCES` pre-publication cleanup with no destination/partial left. New XCTest source additionally covers leaf and intermediate managed-directory symlinks, aggregate reporting, and active-database path substitution. Existing Phase 3–5 deterministic sources retain attachment staging, preview failure, backup, restore, interruption, and rollback coverage, but the complete XCTest suite was not executable on this CLT-only machine.
- **Release build details:** No release archive, signing, notarization, full-Xcode build, XCTest/XCUITest execution, Instruments trace, VoiceOver run, or manual GUI/fresh-install/restore rehearsal is claimed. The checked-in project statically retains App Sandbox, hardened runtime, user-selected read/write files, app-scoped bookmarks, outbound networking, macOS 14 deployment, ad-hoc development signing, and GRDB 7.11.1 resolution. Production distribution identity and archived entitlements remain a release gate.
- **Commands and checks run:** `swift run --package-path . --scratch-path <unique /tmp root> SelfDMNotesPhase6Probe` (compile/link/run passed with the measurements and faults above); `swift build --package-path . --scratch-path <unique /tmp root> --product SelfDMNotesCLTBuild` with every current production Swift source and resolved GRDB 7.11.1 (compiled and linked successfully); whole-production `swiftc -emit-module -parse-as-library -enable-testing ...` (passed); `find SelfDMNotes SelfDMNotesTests SelfDMNotesUITests -name '*.swift' ... swiftc -frontend -parse` (passed); `plutil -lint` for project/entitlements, Python JSON validation for the checked-in `Package.resolved`, `git diff --check`, temporary-root checks, and final status inspection. A semantic test-source typecheck was attempted after emitting the production module but CLT stopped at `no such module 'XCTest'`; source parsing passed, but no XCTest/XCUITest execution or semantic typecheck is claimed. The temporary manifests, probe source, temporary package resolutions, build scratch, and fixture roots were removed.
- **Accepted limitations and follow-up tickets:** Before release, use full Xcode to run the complete clean XCTest/XCUITest suite and Debug/Release builds; create and validate a signed/notarized archive; execute the entire required workflow matrix with keyboard and VoiceOver under all listed accessibility appearances/window sizes; run Instruments and release-build large-library profiling; inspect actual unified logs/network traffic/support JSON; perform abrupt-termination matrices; and complete a disposable fresh-install plus restore/rollback rehearsal. Source-only XCUITest and accessibility modifiers are not manual evidence. Portable export remains non-importable, automatic previews remain opt-in with the documented DNS-rebinding/platform limits, and rollback to an older schema remains unsupported except through a compatible verified pre-upgrade backup.
