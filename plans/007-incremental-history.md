# Incremental History Loading

Status: IMPLEMENTED, 2026-10-19. Continues milestone 3 of [002](002-implementation-plan.md), after connection recovery in [006](006-connection-recovery.md).

## Behavior

- Initial authentication requests one recent page of up to 200 log changes per joined top-level room. Threads load on opening. Room requests remain sequential, so history concurrency is bounded at one during bootstrap.
- “Show earlier messages” reveals locally loaded rows. Once those are visible, “Load earlier messages” requests another server page, with progress and retryable errors. Search and unread counts cover loaded history only.
- Views use stable scroll targets and retain the visible message anchor during prepends. Page completion has a separate identity so fast responses and repeated errors still finish the UI operation.

## Protocol and lifecycle

Apron protocol revision `9e3094c0ca10ca23d228924c29537da959ace613`, §4.2, defines inclusive log bounds and pre-compaction slice limits. Backward requests omit `after` and continue at `first_log_id - 1`; they never infer progress from message IDs or returned array lengths. Compacted pages without messages can still advance the cursor.

The backward cursor is separate from the live-recovery checkpoint. Reconnect pages forward from the checkpoint to a fixed head before enabling writes. Snapshot version ordering preserves newer edits, moves, and deletions while older records load. Initial state is a recent window, not a claim to have loaded the entire archive.

Retention invalidating forward recovery rebuilds a recent window. An advancing retention bound observed during backward loading also triggers a conservative rebuild. Failed rebuilds remain retryable. Concurrent requests for the same room are suppressed. Connection generations and room membership epochs reject late responses after disconnect, account replacement, or leaving a room. Servers without `rooms` use the default-room history cursor even after learning its actual room ID.

## Verification

- `make test-core`: 24 tests passed, including ten new history regressions and the adapted compacted forward-recovery test.
- `make test-app`: 21 tests passed; one opt-in upload integration test skipped (22 declared tests). App/UI-test targets compile.
- `make build` and `git diff --check`: passed.
- Pinned Go server `067083815be6b113e7d35f6569fa35dee0052fd5`, disposable memory store on loopback: existing mutation/reconnect probe passed. New `--local-history` probe loaded 199 recent messages, then one older page, yielding exactly 240 unique seeded messages. No public-server mutations.
- Native light preview inspected with `--preview --preview-history --preview-light --render-preview history.png`; the older-history control and transcript render. Existing standalone capture toolbar/sidebar artifacts remain.

Interactive scroll/resize/keyboard checks still need a working GUI automation host or manual pass. A single initial page per room bounds archive traversal, but startup still visits all joined top-level rooms; priority scheduling, large-room profiling, and eviction of loaded transcript data remain future work. Reconnect recovery intentionally traverses all missed changes needed for correctness.
