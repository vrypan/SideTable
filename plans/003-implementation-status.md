# Initial Implementation Status

Date: 2026-10-18. This records implementation evidence and deliberate departures from [the design](001-macos-client-design.md); it does not mark every release milestone complete.

## Implemented

The repository now contains a native SwiftUI/AppKit app, generated Xcode project and its XcodeGen specification, independent Swift protocol package, replay/session tests, app tests, UI-test source, build commands, and a loopback-restricted integration probe.

Working workflows include multiple servers; guest/token/email-code authentication; Keychain token storage; rooms, threads, and membership controls; sending, replying, editing, deleting, moving, and reacting; server commands; local drafts; history/reconnect recovery; uploads and native file previews; status/mute controls; and local notifications. Capability checks hide unsupported controls. The preview mode uses sample data without connecting or modifying saved accounts.

## Verification

- The ad-hoc-signed app builds with Xcode 27.1 / Swift 6.4 targeting macOS 14, and the documented `make test-app` command passes.
- All 17 pinned upstream replay fixture files pass, including their variants and intermediate assertions.
- Deterministic session tests cover authentication against a minimal server, request timeout, pending-request shutdown, default-room discovery, and compacted recovery bounds.
- App tests verify account-separated draft serialization and media-origin restrictions.
- Against Go reference server `067083815be6b113e7d35f6569fa35dee0052fd5` on loopback: guest sign-in, listing/history, room/thread creation, send, same-ID deduplication, reactions, edit, move, deletion, and reconnect recovery passed. A deleted message remained deleted after reconnect and history replay.
- `server.apron.chat` accepted a standard WebSocket upgrade and sent a protocol-v8 announcement with guest access. The native URLSession probe timed out before its first frame in this environment; native guest sign-in there is **not verified**. No public messages were posted. The optional HTTP diagnostic reported availability.
- XCUITest source is included. Both unsigned and ad-hoc-signed runs stalled before executing UI assertions on this machine; neither is counted as a passing UI test. The isolated native preview was rendered separately for visual inspection.

## Implementation choices

- The transcript uses SwiftUI’s lazy stack and selectable native text, with stable message IDs and batches of 150 visible messages. The composer uses `NSTextView`. The planned `NSCollectionView` implementation is deferred until profiling establishes a need.
- The core fully recovers available history before declaring a session ready. Backward on-demand protocol pagination and parallel room recovery remain performance work; the UI’s “Show earlier messages” reveals already recovered records.
- Markdown uses Foundation’s inline parser and preserves line breaks. A full CommonMark block renderer remains future work.
- Native media fetching trusts only the server origin and rejects redirects. Configurable CDN origins remain future work; external attachments can be opened explicitly in the browser.
- The app uses versioned, atomic Codable storage. Cached conversations are presentation only and never advance protocol checkpoints.

## Remaining release work

Validate native passkeys with a signed app, associated domain, and compatible server origin policy. Complete email and token-rotation end-to-end tests against configured servers. Run GUI accessibility, IME, resize, multi-window, and 10,000-message profiling checks on a working automation host. Implement idle reporting and stronger multi-window attention coordination. Add upload progress/cancellation/retry UI, configurable media trust, and full Markdown rendering. Local read markers are persisted and restored per account.

Distribution signing, notarization, application artwork, automatic updates, remote push integration, and App Store submission are not configured. No developer identity or publication credentials were supplied. Advanced deferred features from the original plan remain deferred.
