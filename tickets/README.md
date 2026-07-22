# Implementation Tickets

These Markdown files are the implementation backlog for Self DM Notes. They are deliberately written so another coding agent can take one phase at a time without redesigning the product.

## Execution order

1. [Phase 0 — Product decisions and bootstrap](00-product-decisions-and-bootstrap.md)
2. [Phase 1 — Durable text-note MVP](01-durable-text-note-mvp.md)
3. [Phase 2 — Search and navigation](02-search-and-navigation.md)
4. [Phase 3 — Attachments](03-attachments.md)
5. [Phase 4 — Link previews](04-link-previews.md)
6. [Phase 5 — Backup, restore, and export](05-backup-restore-export.md)
7. [Phase 6 — Accessibility, resilience, and polish](06-accessibility-resilience-and-polish.md)

## Agent workflow

For each ticket:

1. Read `../PLAN.md`, this index, the selected ticket, and the completion notes from all prerequisite tickets.
2. Inspect the current code before changing it. Follow existing project conventions rather than introducing parallel architecture.
3. Keep work within the selected phase. Record newly discovered follow-up work instead of silently expanding scope.
4. Implement accessibility requirements alongside each UI change.
5. Run the ticket's focused verification and any narrower checks required by changed code.
6. Update the ticket before handoff:
   - Set `Status` to `Done`, `Blocked`, or `Needs review`.
   - Check only criteria that were actually verified.
   - Fill in the completion notes, including commands run and unresolved issues.
7. Do not begin the next phase in the same change unless explicitly requested.

## Definition of done for every ticket

- The intended behavior works without hard-coded demo-only paths.
- Persistence and error paths are handled where relevant.
- Keyboard and VoiceOver behavior is intentionally implemented.
- New logic has appropriate tests.
- The application builds from a clean checkout.
- No temporary files, generated debug data, or secrets are committed.
- User-facing failures explain the next available action.

## Status vocabulary

- `Ready`: prerequisites are met and work can begin.
- `In progress`: an agent is actively implementing the ticket.
- `Blocked`: progress requires a decision or external dependency documented in the ticket.
- `Needs review`: implementation is complete but acceptance or verification remains.
- `Done`: scope and acceptance criteria are complete and verified.
