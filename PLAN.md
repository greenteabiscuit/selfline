# Self DM Notes — Product and Implementation Plan

## Vision

Self DM Notes is a private macOS note-taking app that feels like sending Slack direct messages to yourself. It keeps a permanent, searchable timeline of text, links, photos, and files without relying on an enterprise retention policy.

The first release should earn trust as a personal archive before adding organization, synchronization, or AI features.

## Product principles

1. **Capture must be effortless.** The composer stays at the bottom and sending a note takes one action.
2. **Time is part of the note.** Every entry has an exact creation timestamp and deterministic ordering.
3. **The archive belongs to the user.** Notes and attachments remain available until explicitly deleted and can be exported without the app.
4. **Search is a primary interaction.** Text, links, preview metadata, and attachment names must be searchable quickly.
5. **Accessibility is part of every phase.** Keyboard and VoiceOver behavior are acceptance criteria, not a final retrofit.
6. **Local reliability comes before cloud features.** The MVP is local-only, with backups and restore before synchronization.

## Initial product decisions

- Platform: macOS desktop application
- UI: SwiftUI, with narrowly scoped AppKit interoperability where SwiftUI cannot provide reliable editor, focus, or scroll behavior
- Persistence: SQLite through GRDB.swift, including SQLite FTS5 for full-text search
- Storage model: database for note metadata; managed files on disk for originals, thumbnails, and cached preview images
- Initial library model: one chronological self-conversation
- Sync: no multi-device synchronization in the MVP
- Attachments: images and ordinary files
- Deletion: recoverable trash rather than immediate permanent deletion
- Backups: automatic local backups plus manual export and restore
- Text format: plain text initially; Markdown may be rendered later without changing stored note text
- Proposed minimum system: macOS 14, to be confirmed against the installed Xcode and required APIs during Phase 0

## Core experience

```text
┌──────────────────────────────────────────────┐
│ Search notes…                       Settings │
├──────────────────────────────────────────────┤
│                                              │
│  Older notes                                 │
│  ┌────────────────────────────────────────┐  │
│  │ Photo / link / text           10:42 AM │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ Most recent note              11:06 AM │  │
│  └────────────────────────────────────────┘  │
├──────────────────────────────────────────────┤
│ ＋  Write a note…                     Send ↑ │
└──────────────────────────────────────────────┘
```

### Timeline behavior

- Newest notes appear at the bottom.
- The app opens at the newest note unless restoring an explicit navigation state.
- Scrolling upward loads older notes without changing the reader's visible position.
- Sending scrolls to the new note only when the user is already at or near the bottom.
- Date separators make chronology easy to scan.
- Each entry supports copy, edit, move to trash, and attachment actions.
- `Command+Return` sends; `Return` inserts a newline, matching Slack on the user's Mac. Both behaviors must also have discoverable controls.

### Search behavior

- `Command+F` focuses search from anywhere in the main window.
- Search covers note text, attachment filenames, URLs, and link-preview titles/descriptions.
- Filters cover date range, has attachment, has image, and has link.
- Selecting a result reveals and focuses the original note in context.
- Search must remain responsive with at least 100,000 representative notes.

### Attachment behavior

- Users can choose files, drag files into the composer, or paste images from the clipboard.
- Selected files are copied into app-managed storage; the app never depends on the original path remaining available.
- The timeline uses generated thumbnails and Quick Look or an equivalent native viewer for originals.
- A content hash supports deduplication without changing the logical attachment relationship.

### Link preview behavior

- Saving a note never waits for network preview generation.
- HTTP and HTTPS links are unfurled in the background using Open Graph metadata with safe fallbacks.
- Fetches have strict timeout and response-size limits, do not execute JavaScript, do not send browser credentials, and reject unsafe/local destinations.
- Failed previews leave the original URL intact and readable.
- Users can disable preview fetching globally or remove an individual preview.

## Architecture

```text
┌──────────────── SwiftUI application ────────────────┐
│                                                     │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐  │
│  │ Timeline   │  │ Composer   │  │ Search       │  │
│  └──────┬─────┘  └──────┬─────┘  └──────┬───────┘  │
│         └──────────────┬─┴───────────────┘          │
│                        ▼                            │
│              ┌──────────────────┐                   │
│              │ Repository layer │                   │
│              └───────┬──────────┘                   │
└──────────────────────┼──────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
┌─────────────────┐       ┌─────────────────────┐
│ SQLite + FTS5   │       │ Attachment storage  │
│ Notes/metadata  │       │ Originals/thumbnails│
└─────────────────┘       └─────────────────────┘
          │
          ▼
┌───────────────────────────────────┐
│ Background services               │
│ Link previews · thumbnail creation│
│ backup/export · optional OCR       │
└───────────────────────────────────┘
```

### Storage layout

```text
SelfDMNotes/
├── notes.sqlite
├── attachments/
│   ├── originals/
│   └── thumbnails/
├── previews/
└── staging/
```

Attachments should be staged, committed to the database, and atomically moved into final storage. Startup maintenance should remove abandoned staging files and report database records whose files are missing.

### Initial schema

```text
Note
- id: UUID
- body: String
- createdAt: Date
- updatedAt: Date?
- deletedAt: Date?
- sortKey: Int64

Attachment
- id: UUID
- noteId: UUID
- originalFilename: String
- storedFilename: String
- mediaType: String
- byteSize: Int64
- width: Int?
- height: Int?
- contentHash: String
- createdAt: Date

LinkPreview
- id: UUID
- noteId: UUID
- url: String
- canonicalURL: String?
- title: String?
- summary: String?
- imageURL: String?
- localImageFilename: String?
- siteName: String?
- status: pending | ready | failed
- fetchedAt: Date?

Draft
- body: String
- updatedAt: Date
```

`sortKey` is monotonic so entries remain deterministically ordered even when timestamps collide. Schema changes must use explicit migrations from the first release.

## Accessibility baseline

Every phase must preserve these requirements:

- Complete core workflows using only the keyboard
- Predictable focus order and visible focus indication
- Semantic VoiceOver labels, values, actions, and grouping
- No unexpected focus movement when notes load or background work completes
- System fonts and text scaling
- Light, dark, increased-contrast, and reduced-motion appearances
- No state communicated by color alone
- No hover-only action
- Discoverable alternatives for keyboard shortcuts

Suggested shortcuts:

- `Command+F`: focus search
- `Command+N`: focus composer
- `Command+Shift+A`: choose attachment
- `Escape`: close transient UI or leave search
- `Command+Return`: send note
- `Return`: insert newline

## Delivery phases

| Phase | Outcome | Ticket |
|---|---|---|
| 0 | Decisions, repository, build, and architecture skeleton | [Phase 0](tickets/00-product-decisions-and-bootstrap.md) |
| 1 | Durable text-note timeline MVP | [Phase 1](tickets/01-durable-text-note-mvp.md) |
| 2 | Full-text search and reliable timeline navigation | [Phase 2](tickets/02-search-and-navigation.md) |
| 3 | Managed photos and file attachments | [Phase 3](tickets/03-attachments.md) |
| 4 | Safe asynchronous link previews | [Phase 4](tickets/04-link-previews.md) |
| 5 | Backup, restore, and portable export | [Phase 5](tickets/05-backup-restore-export.md) |
| 6 | End-to-end accessibility, resilience, and release polish | [Phase 6](tickets/06-accessibility-resilience-and-polish.md) |

Tickets are intended to run sequentially. A phase may start only after its dependency ticket is complete and its documented checks pass.

## Explicit non-goals for the first release

- iPhone or iPad application
- Windows or Linux support
- Cloud or peer-to-peer synchronization
- Accounts, collaboration, or sharing between users
- Rich-text editing
- AI summarization or semantic search
- OCR search within images
- Multiple channels, notebooks, tags, or folders
- Browser extension or global quick-capture workflow
- Slack import unless separately planned after the archive format is stable

## Later opportunities

- OCR for image text search
- Tags, stars, pinned notes, and multiple conversations
- Menu bar and global-shortcut capture
- Finder and Safari share extensions
- Import from Slack export archives
- Encrypted CloudKit synchronization
- Natural-language date search and periodic review views
