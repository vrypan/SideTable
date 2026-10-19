# Saved Conversation Cache Management

Status: IMPLEMENTED, 2026-10-19. Implements the selected cache-management work after `a40fe43`.

## Behavior

Settings → Storage shows total saved-conversation disk usage and per-server sizes. Clear removes one server's saved copies; Clear All Saved Conversations also removes recognized caches for servers no longer configured. The controls explain that clearing lasts until the next launch.

Clearing preserves live conversations, staged uploads, drafts, read markers, server configuration, and Keychain credentials. A cache-only launch view is removed immediately when its saved copy is cleared. There is no sign-out or server-side mutation. Avatar memory and downloaded files are not included in the saved-conversation size.

## Storage and lifecycle

`LocalStorage` recognizes only regular, non-symlink `cache-<UUID>.json` files for usage enumeration. Drafts, read markers, server profiles, and unrelated files are excluded. Missing cache files can be cleared repeatedly. Inspection and deletion failures are surfaced in Settings.

Clearing cancels the pending cache timer, changes its generation, and suppresses writes for cleared servers for the rest of this app launch. New snapshots cannot immediately recreate deleted copies. Other servers may continue saving, and a later launch resumes the existing cache policy. Sign-out now deletes its cache file instead of writing a JSON null placeholder. Existing seven-day launch-view expiry remains unchanged.

## Verification

Regression tests in `AttentionAndCacheTests.swift` cover exact file sizes, per-server deletion, unrelated files and symlinks, orphan cache removal, clearing cached launch views, retaining live state/drafts/read markers/account identity, cancelled and later writes, next-launch resumption, and I/O errors. Temporary directories isolate these tests from real saved data.

A network-free sample is available with `--preview --preview-storage --preview-light --render-preview storage.png`. GUI validation covers layout only; live Settings button interaction remains a manual check on the user's Mac.

Final validation: `make build` passed; `make test-app` passed 26 executed tests with the opt-in loopback upload test skipped (27 declared); `make test-core` passed all 24 tests; `git diff --check` passed. The final Xcode run succeeded after the native-preview redraw loop was fixed. Storage Settings was rendered and visually inspected with sample data.
