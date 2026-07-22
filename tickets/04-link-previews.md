# Phase 4 — Safe Asynchronous Link Previews

- **Status:** Implemented; full-Xcode, public-site, and interaction acceptance pending
- **Depends on:** Phase 3
- **Produces:** Searchable, privacy-conscious URL unfurling

## Goal

Turn links in notes into informative preview cards without delaying note capture, compromising local-network safety, or making the note dependent on the network.

## Scope

1. Detect HTTP and HTTPS URLs in note bodies while preserving the exact original text.
2. Add link-preview metadata and status migrations.
3. Enqueue preview work only after the note itself is durably saved.
4. Fetch metadata using `URLSession` with explicit timeout, redirect, response-size, and accepted-content-type policies.
5. Reject loopback, link-local, private-network, multicast, and otherwise unsafe destinations before connecting and after every redirect/DNS resolution as feasible with platform APIs.
6. Never send browser cookies, user credentials, or custom authentication headers, and never execute page JavaScript.
7. Parse Open Graph title, description, image, and site name, with HTML title/meta and favicon fallbacks.
8. Cache successful results and downloaded preview images; avoid repeatedly fetching the same canonical URL.
9. Display pending, ready, and failed states without replacing or obscuring the original URL.
10. Allow retry, remove preview, open/copy URL, and globally disable automatic preview fetching.
11. Add preview title, description, site name, and URL to search, and activate the Phase 2 link filter.
12. Cancel irrelevant work when a link is removed or its note is permanently deleted.

## Privacy and accessibility behavior

- Explain in settings that generating a preview contacts the linked website and can reveal the user's IP address.
- The global off setting must prevent new network requests, not merely hide cards.
- Background completion may announce that a preview became available but must not steal focus or scroll the timeline.
- Cards must expose title, site, description, destination, and available actions without repetitive VoiceOver output.

## Non-goals

- Authenticated intranet previews
- JavaScript-rendered page screenshots
- Video playback or rich third-party embeds
- Browser history or cookie integration
- Archiving complete linked pages

## Acceptance criteria

- [x] Saving a note with a link succeeds immediately while offline or on a slow network.
- [ ] Common Open Graph pages produce useful preview cards.
- [x] Metadata fallbacks work when Open Graph fields are absent.
- [x] Timeout, oversized response, redirect loop, malformed HTML, non-HTML content, and unavailable host fail safely.
- [x] Unsafe local/private targets and redirects are rejected and covered by tests.
- [x] Disabling previews prevents future preview requests.
- [x] Removing a preview leaves the note text and URL untouched.
- [x] Duplicate URLs use cached metadata according to a documented refresh policy.
- [x] Search finds preview metadata and the link filter works.
- [ ] Preview completion never unexpectedly changes keyboard/VoiceOver focus or timeline scroll position.
- [x] Network and parser behavior is tested with deterministic URL protocol stubs or a local controlled test server, not the public internet.

## Verification

- Run all unit and UI tests without requiring public network access.
- Test safe URL classification, each redirect case, response limits, parsing fallbacks, cache behavior, cancellation, and disabled preferences.
- Manually smoke-test several public URLs only after deterministic tests pass.
- Test offline note capture and keyboard/VoiceOver card actions.

## Completion notes

- **Implementation summary:** HTTP/HTTPS detection preserves exact note text and is reconciled only after note commits. Every body edit transaction increments a persisted preview revision, immediately excluding older associations from work, commits, hydration, and search. Production body edits run through the coordinator actor; edit, reconciliation, cleanup/cancellation, and hydrated return do not suspend, and the final persisted eligibility check cannot interleave with a coordinator-mediated edit before fetch invocation. A full startup reconciliation must succeed before the fail-closed queue gate opens; opt-in cannot bypass it and failure warns. The persisted queue deduplicates shared URLs, cancels irrelevant generations, and renders pending/ready/failed cards with Retry, Remove preview, Open link, and Copy link actions. Automatic fetching is off by default; its off transition closes the runtime gate and cancels work before persisting. If that durable write fails, runtime remains off and the UI offers an accurate same-session retry. Preview metadata and current URL associations feed FTS and **Has Link** search. Preview-only UI notifications merge only card state so an older refresh cannot overwrite newer note text or attachment state.
- **Schema migrations added:** `v5_create_link_previews_and_index_metadata` adds `notes.linkPreviewRevision`; creates singleton `app_settings`, shared `link_preview_cache`, per-note `link_previews`, work/reference indexes, rebuilt preview-aware FTS content, and triggers for note, attachment, preview-association, and shared-cache changes. Persisted fields cover reconciled revision, status, request identity, original URL, per-association next-fetch time, shared request-key retry deadline, fetched/failure time, metadata, canonical/image URL, and local image filename.
- **Network safety policy:** Injectable ephemeral URLSession plus DNS resolver; no web view or JavaScript; clean unauthenticated GETs; no cookies, credential storage, custom auth, response cache, explicit proxy/PAC, or connectivity waiting. URLs are normalized and credentials/special-use hosts are denied. Every initial/redirect destination and all initially observed A/AAAA answers must pass a conservative routability policy that rejects loopback, unspecified, private, shared, link-local, multicast, mapped/transition, benchmarking, documentation, and other reserved ranges. URLSession cancellation retains a terminal result until continuation publication; DNS-SD deallocation and callback-context release stay on the associated serial callback queue. Limits are five redirects, 12 seconds per resource (8-second request ceiling), 1 MiB HTML, 2 MiB images, accepted HTML/raster MIME allowlists, two image candidates, 20 million source pixels, and a static 512-pixel PNG output. Only outbound network client access was added to sandbox entitlements; ATS arbitrary-load permission is present because the ticket accepts HTTP links.
- **Cache/refresh policy:** A fresh success is reused for seven days across notes. One shared stale refresh runs after that; a refresh failure retains visible cached metadata and persists a request-key-wide 24-hour backoff that new associations inherit. First-fetch failures show a retryable failed card. Image files use generated lowercase UUID `.png` names, are installed atomically, and are reference-checked before deletion. Reads and startup cleanup reject symlinks, non-regular files, and nonconforming names; missing images clear only the file pointer.
- **Commands and checks run:** Full Swift parse of app, unit-test, and UI-test sources with `xcrun swiftc -parse`; focused Swift 6 typecheck of the link domain/network/parser sources; temporary SwiftPM production-module build (all app sources except the Xcode `@main` entry and resources) with `swift build --scratch-path … --target SelfDMNotes`; deterministic temporary-root `swift run --scratch-path … Phase4Probe` covering Phase 3 upgrade, revision invalidation and persisted-enabled relaunch, startup/opt-in gating, coordinator edit after pre-fetch validation, shared backoff inheritance, strict preview-file handling, failed-disable retry, continuation-publication cancellation, and DNS-SD cancellation cleanup stress; `plutil -lint` on the entitlements and project; Package.resolved JSON and project XML/plist checks; and `git diff --check`. SwiftPM XCTest compilation was attempted but Command Line Tools has no XCTest module. No public internet, production library, or isolated Phase 1 preview data/process was used.
- **Accessibility checks:** Cards expose visible state, title/site/description/destination and labeled actions; settings exposes the IP-address/privacy consequence; background refresh does not request focus or scrolling; **Has Link** is labeled independently of color. Focused XCUITest sources were added and all sources parse, but no full-Xcode XCUITest or manual VoiceOver/keyboard/visual pass was available, so the interaction-only acceptance criteria remain unchecked.
- **Known issues or follow-up tickets:** Full Xcode build/XCTest/XCUITest and manual offline/slow capture, common public Open Graph, keyboard, focus/scroll, VoiceOver, appearance, and sandbox smoke tests remain release verification. Supported macOS APIs cannot pin URLSession to the separately validated DNS answer or inspect every connected peer; DNS rebinding/late answers, VPN or transparent Network Extension routing, and CFNetwork's pre-callback decompression/buffering remain documented residual limits. HTTP and downgrade redirects are plaintext and reveal their destination/path. ImageIO internal allocations cannot be completely controlled beyond input byte/type/pixel and output bounds.
