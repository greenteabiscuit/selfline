# Phase 0 — Product Decisions and Project Bootstrap

- **Status:** Needs review
- **Depends on:** None
- **Produces:** A buildable macOS project and documented architectural decisions

## Goal

Create the smallest production-oriented macOS SwiftUI project that establishes the storage, testing, accessibility, and architectural conventions needed by later phases.

## Confirmed defaults

- Local-only MVP
- One self-conversation
- Images and ordinary file attachments
- Recoverable trash
- Automatic local backups in a later phase
- Plain-text notes
- SQLite through GRDB.swift
- SwiftUI with AppKit interoperability only when a demonstrated limitation requires it

The proposed deployment target is macOS 14. Change it only when the installed Xcode or a required API provides a concrete reason, and document that reason.

## Scope

1. Create the Xcode macOS application project within this directory.
2. Establish application, unit-test, and UI-test targets.
3. Add GRDB.swift through Swift Package Manager and verify SQLite FTS5 availability.
4. Define a modest folder structure for UI, domain models, persistence, and services. Avoid speculative layers that have no Phase 1 use.
5. Establish an application-support directory provider that supports test-specific temporary directories.
6. Add an empty database migrator and a test proving a fresh database can be created and reopened.
7. Add a minimal app window with accessible placeholder content and a bottom composer placeholder.
8. Configure code signing, sandbox capabilities, and network/file entitlements conservatively. Do not request capabilities before a phase needs them.
9. Add a project README with build, test, data-location, and architecture instructions.
10. Add a short decision record covering the database choice, local-only scope, storage boundaries, and deployment target.

## Architectural constraints

- UI code must not issue SQL directly.
- Persistence should expose behavior needed by a caller, not a generic repository abstraction for hypothetical models.
- Production paths must be injectable or overridable so tests never modify the user's real library.
- The app must not require network access to launch or create text notes.
- Database migrations are append-only once a version has shipped.
- Avoid global mutable singletons for the database and file store.

## Non-goals

- Implementing actual note creation or editing
- Search, attachments, link fetching, backup, restore, or synchronization
- Designing every future service protocol
- A complete visual design system

## Acceptance criteria

- [ ] The macOS application builds and launches from Xcode.
- [ ] Unit and UI test targets run successfully.
- [x] A temporary test database can be migrated, closed, and reopened.
- [x] FTS5 support is verified by an automated test or a documented runtime capability check.
- [x] The application-support path is deterministic in production and isolated in tests.
- [ ] The placeholder interface is keyboard reachable and has meaningful VoiceOver labels.
- [x] The README explains the exact local build and test commands.
- [x] Architectural decisions and deviations from the defaults are documented.

## Verification

Run the project's documented command-line build and test commands using a temporary Derived Data path. Launch the built app once and perform a basic VoiceOver and keyboard focus smoke test.

## Completion notes

Fill in when work finishes:

- **Implementation summary:** Added a native macOS SwiftUI Xcode project with app, unit-test, and UI-test targets; GRDB.swift 7.11.1 through Swift Package Manager; an empty `DatabaseMigrator`; deterministic/injectable Application Support paths; functional connection and FTS5 checks; an accessible placeholder timeline/composer; sandbox-only entitlements; documentation; and database/path/accessibility-focused tests. Hosted unit tests and UI-launched apps receive a safe process-specific temporary root before app startup.
- **Decisions or deviations:** Kept the macOS 14 deployment target and local-only boundary. Pinned GRDB 7.11.1 exactly because it is the current release and requires Xcode 16.3+/Swift 6.1+. Used a single `DatabaseQueue` for the Phase 0 lifecycle and no product schema. Created the `.xcodeproj` directly because no Xcode project generator is installed; no tooling was installed outside the workspace. The only entitlement is App Sandbox; network and user-selected-file capabilities remain absent.
- **Commands and checks run:** `swift build ... --product SelfDMNotes` with a temporary SwiftPM harness compiled and linked all app sources against GRDB 7.11.1 using Swift 6.3.2. A temporary executable over the production persistence sources passed isolated-root resolution, empty-migrator create/close/reopen, connection health, and a functional FTS5 `MATCH` query. The compiled SwiftUI executable launched with a process-specific temporary root and created an integrity-clean database (`PRAGMA integrity_check` returned `ok`). `plutil -lint`, `xmllint --noout`, `python3 -m json.tool`, `swiftc -parse`, project-reference checks, entitlement scans, and temporary-artifact scans passed. All validation-only files and processes were removed.
- **Known issues or follow-up tickets:** This machine has only `/Library/Developer/CommandLineTools`; `xcodebuild` reports that a full Xcode developer directory is required, and `xctest` is unavailable. Therefore the documented Xcode build/test commands, the actual app bundle/window launch, unit/UI target execution, keyboard focus UI test, and manual VoiceOver/focus-ring smoke test remain unverified. The SwiftPM executable registered with Launch Services and initialized storage but did not expose an inspectable app window, so it was not used to claim accessibility acceptance. Install/select Xcode 16.3 or later, run the README commands, then complete the documented manual accessibility smoke test before changing this ticket to `Done`.

## Orchestrator review

- **Review outcome:** No high-confidence source, persistence-boundary, test-isolation, accessibility-semantic, or project-wiring defect was found. Independent plist/XML/JSON parsing, Swift parsing, target/reference checks, entitlement inspection, and Markdown-link checks passed.
- **Disposition:** Implementation accepted as the baseline for Phase 1. Status remains `Needs review` until a full Xcode installation can run XCTest/XCUITest and the manual VoiceOver window smoke test.
