# Sidetable Implementation Plan

Status: partially implemented; see [003](003-implementation-status.md) for the initial baseline and [004](004-conversation-polish.md), [005](005-profiles-and-avatars.md), [006](006-connection-recovery.md), and [007](007-incremental-history.md) for subsequent work. This plan implements [the macOS client design](001-macos-client-design.md). Each milestone should leave a runnable app or independently testable core. Keep subsequent plans and decision records under `plans/`.

## 1. Establish the project and compatibility harness

Create the macOS app target, shared `Sidetable` scheme, local `ApronCore` Swift package, unit/UI test targets, and README. Select an installed Swift 6-capable Xcode toolchain; record its exact version and the macOS 14 deployment target. Enable strict concurrency checking and basic sandbox entitlements.

Import or vendor protocol fixtures from commit `9e3094c0ca10ca23d228924c29537da959ace613`, preserving their license and provenance. Build a fake transport and controllable clock. Pin a Go server revision for local interop, inspect its actual startup commands, and document them rather than relying on the moving branch.

In parallel within this milestone's task sequence, perform two small prototypes: transcript selection/scroll anchoring with variable-height rows, and native passkey authentication against a controlled domain. Record passkey RP/origin/AASA requirements and whether tokens resume successfully. Failure of the passkey experiment does not block guest/token/email development; it blocks claiming support for passkey-only servers.

**Acceptance:** app opens an accessible empty shell; core tests run without a server; fixture revision and licensing are recorded; compatibility findings are documented.

## 2. Implement core protocol and live chat

Implement frame codecs, validated identifiers, server announcements, guest/token auth, token rotation, ordered processing, request correlation, errors, and application ping/pong. Implement pure reducers for messages, rooms, reactions, memberships, current identity, and transient notices. Preserve extension data and required absent/null/empty distinctions.

Add endpoint entry, authentication, one default conversation, plain-text rendering, and a composer. Use a separate pending-send model; resolve it from the result's message ID without creating a duplicate server row. Do not persist guest identities as resumable accounts unless an actual supported resume credential is issued.

**Acceptance:** exchange messages with a minimal server lacking optional capabilities; render unknown notifications safely; handle denial without a retry loop; pass reducer/decoder fixtures, including duplicate and out-of-order records.

## 3. Make history and reconnect correct

Implement per-room fixed-head recovery, compacted-page pagination, retention resets, buffer limits, request generations, backoff, and cancellation. Treat sleep/wake and network changes as reconnect scenarios. Add joined room listing and discovery, a sidebar, older-history loading, and stable scroll position.

Keep this milestone ahead of polished mutations: edits, deletions, moves, and reactions must already reduce correctly during replay even before their sending controls exist.

**Acceptance:** disconnect, change messages from another client, reconnect, and reproduce the server's final state. Test a retention bound advancing mid-page, empty/compacted pages, sparse IDs, stale replies, capability removal, and history-less reconnection. A deliberately dropped send result remains visibly uncertain and is never blindly resubmitted with a new ID.

## 4. Complete the native conversation workflow

Add native Markdown rendering, text selection, reply previews, mentions, reactions, edits/deletions, room creation/join/leave, members, and thread navigation. Keep a reply distinct from creating a thread. Add message moves only when source and destination reconciliation is tested. Add server commands and safe transient reply cards.

Wire menus, keyboard shortcuts, IME behavior, accessibility, both appearances, reduced motion, and minimum-window layout. Add persistent text drafts and local unread/read-cursor logic; gate network activity and status updates on advertised capabilities/settings.

**Acceptance:** keyboard-only and VoiceOver users can connect, switch rooms, send, reply, and open a thread. Drafts survive room changes and restart. Pagination and inspector resizing do not jump the transcript. Server policy denial leaves the UI and draft recoverable.

## 5. Add account continuity, files, and multiple servers

Implement email proposal/approval using the correct connection, Keychain-backed session restoration, explicit sign-out, and account-scoped cached launch views. Add multiple saved server sessions with capped concurrent history requests. Ensure selecting another server never changes the destination of an already initiated operation.

Implement file selection/drag-and-drop, pending embed creation, HTTP PUT, progress, cancellation, native image/file cards, and explicit downloads. Validate redirects and trusted media origins. Defer inline HTML and stream execution/rendering.

**Acceptance:** two local servers with overlapping user, room, and message IDs remain isolated. Account switching cannot display old private content. Email proposal loss prompts a new code request. Upload expiration, cancellation, failed PUT, and completion after a reconnect all converge to the authoritative snapshot.

## 6. Notifications, polish, and release candidate

Implement local notifications, attention tracking, optional advertised statuses and mute controls, notification-click navigation, and privacy settings. Closing the last window preserves sessions; explicit Quit stops them. Settings must describe alerts as available while the app is running, without implying APNs support.

Profile a seeded 10,000-message room with mixed content. Set budgets after recording hardware and release-build baselines; target responsive scrolling and typing, bounded media memory, and no growing task count across repeated reconnects. Verify cached data expiration and user-triggered deletion.

**Acceptance:** no duplicate alerts from history or restored cache; notifications open the correct server and room. All core/UI checks pass. Produce a signed/notarized build only once signing identity and distribution details are available. Document unsupported passkey/server configurations and known limitations.

## Verification and developer commands

The Swift project and command contracts are implemented. Use `make test-core`, `make test-app`, `make test-ui`, and `make build`, or the underlying commands:

```sh
swift test --package-path Packages/ApronCore
xcodebuild -project Sidetable.xcodeproj -scheme Sidetable -configuration Debug build
xcodebuild -project Sidetable.xcodeproj -scheme Sidetable -destination 'platform=macOS' test
```

Use Swift Testing for deterministic core/presentation tests and XCTest/XCUITest for application journeys. Add macOS CI for package tests and app build/tests. Use a local Go server for reproducible integration checks; treat the public demo as an optional manual compatibility check, not a fixture or CI dependency.

Release-blocking cases: protocol fixture failures, cross-account data leakage, duplicate send reconciliation, stale deleted messages reappearing, incorrect retention recovery, secret-bearing diagnostics, inaccessible composer input, or a mismatch between advertised and working authentication methods.

## Deferred work

Native passkeys ship only after milestone 1's compatibility gate succeeds. Remote push needs a separately designed server/relay integration. Multiple accounts per endpoint, streaming embeds, complete web-client feature parity, automatic updates, and App Store distribution each warrant a later plan. Recheck upstream protocol changes intentionally against the fixture suite before updating the pinned revision.
