# Plan 004: Polish message rendering and attachment uploads

## Status and intent

- Status: IMPLEMENTED — Xcode-hosted tests passed; GUI interaction verification pending
- Priority: P1; effort: M–L; implementation risk: MED
- Category: direction
- Planned at: `698614f`, 2026-10-19
- Dependencies: existing initial client; extends milestones 4–5 of plan 002.

Make conversations easier to read and file transfers understandable and recoverable. Deliver native Markdown blocks and per-file progress, cancellation, and retry. This is a scoped design and implementation plan, not a broader reliability or security audit.

Before implementation, run `git diff --stat 698614f..HEAD -- Sidetable SidetableTests SidetableUITests project.yml Sidetable.xcodeproj README.md THIRD_PARTY_NOTICES.md`. Compare changed code with the excerpts below and revise assumptions if necessary. Read this entire plan before editing. Record implementation evidence and update the index when complete.

## Current state

The app targets macOS 14, uses Swift 6, SwiftUI feature views, AppKit platform integrations, and a local ApronCore package. Match four-space indentation, `@MainActor @Observable` model ownership, and Swift Testing tests using `@Test` and `#expect`; `SidetableTests/StorageTests.swift` is an example. Keep protocol changes separate from presentation.

- `Sidetable/Features/ConversationView.swift`, `MessageRow`: Markdown uses `AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`. Messages support selection, adjustable text size, safe HTTP(S) links, and Copy Text. The lazy transcript uses stable message IDs and reveals batches of 150.
- `Sidetable/App/AppModel.swift`, `deliver`: after `session.perform`, it calls `server.pending.removeAll { $0.id == message.id }`, then enumerates response embeds and uploads local files. Upload errors consequently become a generic server error. `retry` calls `deliver(message, files: [], server: server)`; the UI disables that retry for messages with embeds.
- `PendingMessage` retains RPC ID, room, account, parameters, text, error, and a sending flag, but no files. `StagedFile` retains a session-only URL. Upload uses an ephemeral URLSession, PUT, a security-scoped file URL, and a 120-second timeout.
- `Sidetable/Platform/MediaPolicy.swift` restricts automatic requests to the server origin and rejects redirects. `AttachmentView.swift` renders authoritative server embeds and handles downloads/Quick Look.
- `Sidetable/App/SidetableApp.swift` warns at quit only about files still staged in composers. Account changes/sign-out currently clear pending arrays without owning upload task handles.

Existing design decisions remain binding: native views, no executable HTML, a bounded tested CommonMark parser, and a focused parser/selection prototype before choosing a dependency. Upload descriptors precede PUT; a later server snapshot confirms attachment completion. Write URLs are credentials: never persist or log them. Staged files remain session-only.

## Scope

Allowed changes: `ConversationView.swift`, `AppModel.swift`, `SidetableApp.swift`, `AttachmentView.swift`; new Markdown components under `Sidetable/Features/` and upload components under `Sidetable/Platform/`; focused tests under `SidetableTests/` and `SidetableUITests/`; `project.yml`, generated `Sidetable.xcodeproj/` including dependency resolution, `THIRD_PARTY_NOTICES.md`, `README.md`, and this plan/index for evidence.

Keep ApronCore protocol/recovery behavior, authentication, persisted storage formats, media trust policy, composer IME behavior, notifications, and history pagination unchanged. Defer syntax highlighting, Markdown tables/extensions, autocomplete, HTML embeds, CDN trust configuration, persistent upload queues, and transcript replacement.

## Commands and workflow

| Command | Expected result |
| --- | --- |
| `make generate` | XcodeGen regenerates project after new files/dependencies |
| `make build` | Ad-hoc-signed macOS app builds, exit 0 |
| `make test-app` | App tests, including new behavior tests, pass |
| `make test-core` | Protocol/replay regression suite passes |
| `make preview` | Isolated sample app opens for manual review |
| `make test-ui` | UI assertions execute and pass on a working GUI host |

No install step is currently required. A selected Markdown dependency must be explicitly pinned, license-compatible, and recorded. Do not claim UI tests passed when the runner stalls; that happened in initial verification. Keep changes in logical units, with imperative commit subjects such as `Render native Markdown message blocks`; do not commit or push unless requested.

## Steps

### 1. Prove the Markdown rendering approach

Build a small native rendering prototype and choose a CommonMark parser after checking its official documentation, maintenance, license, Swift compatibility, and behavior. Do not build a regex-based Markdown parser. Record the exact dependency/version and selection rationale here; do not assume Foundation inline parsing provides block layout.

Use a fixture containing paragraphs, headings, nested ordered/unordered lists, quotes, fenced and indented code, links, emphasis, Unicode, malformed syntax, and raw HTML. Verify selectable text, wrapping at the app's minimum width, text-size changes, and light/dark appearance. Establish explicit input-size/nesting limits and readable plain-text fallback for over-limit input or unsupported nodes. Raw HTML remains inert; Markdown images must not trigger arbitrary network loads.

**Gate:** `make generate` and `make build` exit 0; record prototype observations and parser limits here. If no candidate preserves native selection and bounded rendering, report the constraint before expanding scope.

### 2. Integrate readable message blocks

Add a testable parsing/presentation boundary and a native `MarkdownMessageView`. Render paragraphs, headings, lists, quotes, thematic breaks, and code blocks. Code uses a monospaced font, horizontal scrolling when necessary, and an accessible Copy Code action that preserves whitespace. Inline links retain `MediaPolicy.safeLink` behavior. Preserve plain-text messages, source Copy Text, deletion placeholders, reply previews, and existing attachment cards.

Keep message IDs and scroll anchoring stable. Avoid reparsing unchanged content on every progress or snapshot update; any cache must be bounded and invalidated for edits, deletion, and account changes. Do not introduce a persistent cache of private message content.

**Gate:** `make test-app` and `make build` exit 0. Add parser/presentation tests for nested blocks, code whitespace, unsafe links, inert HTML/images, Unicode, edited content, and over-limit fallback. Review the fixture through `make preview` at minimum width and both appearances.

### 3. Own attachment delivery state independently

Introduce an observable upload coordinator/state model owned by the server model, with injectable message submission and byte-transfer interfaces for tests. Retain original operation ID, server/account/room identity, ordered local files, acknowledged message identity, and per-file state: waiting, uploading, awaiting server confirmation, complete, failed, or cancelled. Store byte counts and optional total size; unknown totals show indeterminate progress.

Keep message acknowledgement distinct from upload completion. Reconcile the local row with the authoritative message without duplicating message text. Missing write URLs or mismatched response descriptors must produce explicit per-file failures instead of silent skips. Capture immutable destination/account context and reject late callbacks from obsolete attempts.

Verify response mapping, duplicate-operation responses, write-URL expiration/reuse, and authoritative completion fields against the pinned reference server/protocol before promising retry. Use disposable loopback data only. Retry an uncertain message with its original RPC ID and retained files; never create another message automatically. Retry only the failed file when its upload URL is demonstrably reusable. If expired or ambiguous, show an actionable explanation and let the user explicitly reattach; do not invent a renewal protocol or claim byte-level resume.

**Gate:** `make test-app` passes deterministic fake-transport tests for lost acknowledgement, duplicate retry, missing descriptors, partial success, account isolation, and late callbacks. Record verified server retry semantics here before enabling upload retry.

### 4. Add progress, cancellation, and retry controls

Implement URLSession upload progress with bounded main-actor updates and owned cancellable tasks. Keep same-origin checks, redirect rejection, security-scoped resource lifetimes, and ephemeral credentials. Files must remain accessible through retry or show a clear reselect action. Do not load entire files into memory for progress reporting.

Render per-file name, progress, status, and accessible Cancel/Retry actions near the associated message. Cancelling stops queued/active local transfer; it does not delete the acknowledged message or promise remote rollback. A successful PUT enters awaiting-confirmation state until authoritative embed completion. Failed files remain individually recoverable while successful files are not reuploaded. Prevent overlapping retries.

Cancel and release tasks/files on sign-out, account replacement, and server removal. Room navigation must not cancel uploads. Update quit handling to cover active/unfinished transfers as well as staged attachments; make clear that transfers do not survive quitting. Never put signed write URLs in UI errors or logs.

**Gate:** `make test-app` and `make build` pass. Tests cover progress, cancellation, retry-only-failed-file, expired URLs, denied origin/redirect, missing local file, HTTP error, PUT success awaiting snapshot, stale callbacks after cancellation/account change, and resource cleanup. Use fake transports for deterministic races; test URLSession behavior with controlled responses where necessary.

### 5. Validate and document the complete flow

Expand isolated preview fixtures and UI checks for Markdown/code copying and representative upload states without network side effects. Manually test file picker and drag/drop, keyboard controls, VoiceOver labels, narrow windows, scrolling during progress updates, multiple files, cancellation, room switches, and server/account switches. Run a real upload against a disposable local server, including a failed transfer and retry according to the verified protocol behavior.

**Gate:** `make test-core`, `make test-app`, and `make build` pass. Run `make test-ui` on a usable GUI host and record actual outcome. Update README limits and this plan with commands, results, screenshots where useful, and unverified cases. Do not rewrite historical verification in plan 003.

## Done criteria

- [x] Final ordinary suite passes through `make test-app`; verified during 005 and 006. The opt-in loopback upload test remains covered by the earlier integration/harness run below.
- [x] `make test-core` and `make build` exit 0.
- [x] No Markdown message uses `.inlineOnlyPreservingWhitespace` as its entire block renderer.
- [x] Original-operation retry retains files; failed upload retry cannot resubmit message text.
- [x] Progress, cancellation, and account-lifecycle race tests pass.
- [x] Parser choice/limits and upload retry semantics are documented with evidence.
- [x] GUI/local-server verification results and remaining limitations are recorded honestly.
- [x] `git diff --check` passes; changed files remain within scope; index status updated.

## Stop conditions and maintenance

Reassess if the live code has materially drifted, server semantics cannot safely support the proposed retry, a dependency requires a newer deployment target, or implementation requires protocol/storage/trust changes outside scope. Report persistent verification failures rather than weakening checks. Review cancellation/resource ownership and stale callbacks closely: future account handling and attachment persistence will interact with them. History pagination must preserve the renderer's message identity and edit invalidation behavior.


## Implementation evidence — 2026-10-19

### Rendering decision

Selected [swift-markdown 0.7.3](https://github.com/swiftlang/swift-markdown/tree/0.7.3), an AST parser backed by cmark rather than a UI framework. Its Swift 6.2 manifest builds with the repository’s Swift 6.4 toolchain and macOS 14 target. Xcode resolves swift-cmark 0.9.0; both exact revisions are recorded in Package.resolved. Upstream license texts are reproduced in THIRD_PARTY_NOTICES.md. No WebKit or network image loader was introduced.

`MessageMarkdown` limits parser input to 64 KiB, checks a maximum AST depth of 32 and 4,096 nodes before recursive rendering, and provides bounded plain-text fallback. `MarkdownMessageView` retains parsed blocks only for its own view/source lifetime, reparses edits, and is keyed by account/message identity. No global or persistent Markdown cache exists. Code blocks preserve whitespace for copying and scroll within a bounded viewport. Text is selectable per native block; Copy Text retains access to the entire original message. HTML is literal text; Markdown images display their alt text without fetching.

### Upload semantics and implementation

Verified against Apron protocol revision `9e3094c0ca10ca23d228924c29537da959ace613`, §4.8.3–4.8.4, and Go reference server `067083815be6b113e7d35f6569fa35dee0052fd5`, `internal/server/embeds.go` (`resolveEmbedsLocked`, `handleWrite`, `writeUpload`). Response descriptors follow request order. The server consumes write URLs at PUT start; a failed, cancelled, expired, or consumed write cannot safely be retried. Consumed URLs are omitted from later dedup responses. A completed upload gains `url` in an authoritative message snapshot; failed/expired embeds disappear.

`UploadCoordinator` retains original operation IDs and files across lost acknowledgements, validates descriptor mappings, owns cancellable tasks, and rejects obsolete callbacks after cancellation/account changes. Retry Upload is limited to local preflight failure before any network request; actual transfer failures offer an explicit Reattach to Composer action without resending message text. Sign-out/removal clears tasks and ephemeral credentials. File leases last through staging and recoverable failures. Successful message uploads wait for the server snapshot; command uploads complete on successful PUT because commands have no message snapshot. Closing a window does not cancel transfers; quitting warns about unfinished files.

### Verification and limits

- `make build`: passed, ad-hoc signed app, macOS 14 deployment target.
- `make test-core`: 8 tests passed, including all upstream replay fixture cases.
- `TEST_RUNNER_SIDETABLE_UPLOAD_INTEGRATION=1 make test-app`: 14 tests passed before the final two recovery tests and account guard were added. Later invocations built successfully but stalled before launching their test host, even after restarting the session’s idle test service. Final verification used `SIDETABLE_UPLOAD_INTEGRATION=1 swift test --package-path /tmp/sidetable-004-harness`: **all 16 tests passed**. That temporary package symlinks the unchanged `Sidetable/` and `SidetableTests/` sources, excluding only the app entry point/resources, and uses the same ApronCore and Swift Markdown dependencies. This proves the final test behavior but is not a passing Xcode-hosted rerun. App tests cover Markdown, storage, HTTP responses, upload state/races, per-file retry, reattachment, and a real loopback upload. The integration test deliberately loses the first acknowledgement, retries the original operation, verifies one message, uploads/downloads matching bytes, and verifies rejection of the consumed write URL. It is skipped in ordinary test runs; README records setup.
- Reference-server tests `TestUploadsAreHostedWithOpenGraph`, `TestFailedAndExpiredWritesDropTheEmbed`, `TestRequestDeduplication`, and `TestWritesArePUT`: passed against disposable loopback servers.
- Native preview renders inspected in dark appearance and narrow/light appearance, plus per-file progress/failure/confirmation controls. Inspection caught and corrected clipped code-block height and a vertical thematic separator. Preview fixtures reside in Development and Design.
- `make test-ui`: **not passing on this host**. The initial runner had a signing mismatch; disabling hardened runtime only for the UI-test target fixed bundle loading. The runner then timed out enabling automation mode before assertions. Source assertions were added, but keyboard interaction, clipboard clicks, VoiceOver, drag/drop, live resizing, and multi-window attention still need an automation-capable Mac/manual pass. Standalone NSHostingView captures also have pre-existing sidebar-vibrancy and clipped-toolbar artifacts; they are not proof of complete window rendering.
- No public messages were posted. No release signing or protocol/storage changes were made.

Follow-up verification during 005 and 006: the ordinary Xcode-hosted app suite now passes, including the final recovery tests and account guard. The opt-in loopback integration test is skipped in these ordinary runs. GUI interaction checks remain a validation limitation. History optimization, autocomplete, syntax highlighting, Markdown extensions, and persistent uploads remain outside this milestone.
