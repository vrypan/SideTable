# Window Attention and Unread Handling

Status: IMPLEMENTED, 2026-10-19. Implements the selected multi-window attention work after `a40fe43`.

## Behavior

Each conversation pane owns an independent attention registration keyed by server, account, and room. A pane counts as reading only when its owning window is key, the application is active, the window is visible and not minimized, and the transcript shows its latest messages. Search results, older-history loading, cached views, and disconnected sessions do not acknowledge reads. Parent conversations and thread panes register independently.

Opening a room no longer clears its unread badge. Entering an eligible reading state clears unread messages and advances the persisted read marker. Returning focus to the conversation catches up even without a new incoming message. Read cursors remain monotonic and respect server capability/settings. When no read marker exists, unread counts reflect other users' non-deleted messages in loaded history.

Notification suppression uses the same attention registry. Removing one pane does not remove another pane's registration. Window deactivation and teardown remove attention immediately. Server/account changes reset the relevant registrations, and conversation view identity includes the account and room.

## Implementation and verification

`ConversationAttention` is an imperative main-actor registry, deliberately not observable: registry mutation during a native window update must not trigger another SwiftUI render. `WindowAttentionReader` watches native window focus, occlusion, minimization, closure, and application activation. SwiftUI tracks whether the latest transcript edge is visible.

Regression tests in `AttentionAndCacheTests.swift` cover multiple registrations, closure/focus loss, server/account/thread isolation, navigation without acknowledgement, unread increments, focus return, persisted markers, and cached/disconnected exclusions. The native preview caught a redraw loop in an earlier observable registry implementation; removing observation fixed it.

Window navigation itself remains shared across windows in the existing app model. Independent per-window server/room selection and idle-status reporting are outside this change. Physical focus switching, minimization, sheets, and accessibility still need a manual GUI pass; unit tests exercise attention decisions without manipulating the user's windows.

Final validation: `make build` passed; `make test-app` passed 26 executed tests with the opt-in loopback upload test skipped (27 declared); `make test-core` passed all 24 tests; `git diff --check` passed. The final Xcode run succeeded after the native-preview redraw loop was fixed. Storage Settings was rendered and visually inspected with sample data.
