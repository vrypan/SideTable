# Testing and protocol verification

[Documentation](README.md) · [SideTable](../README.md)

```sh
make test-core   # Swift Testing: upstream replay fixtures and session/recovery tests
make test-app    # Storage, Markdown, HTTP, and upload lifecycle tests
make test-ui     # XCUITest preview navigation; requires a usable GUI automation session
make test-tools # Release/version and distribution tests; no credentials or uploads
make check      # Release/version tests, core tests, and application build
```

Run commands from the repository root after completing the [development setup](development.md).

For a repeatable transcript-derivation microbenchmark (5,000 messages, 10,000 reaction records, including initial cache construction):

```sh
mkdir -p build
swiftc -O Packages/ApronCore/Sources/ApronCore/Wire.swift Packages/ApronCore/Sources/ApronCore/Store.swift scripts/benchmark-transcript.swift -o build/benchmark-transcript
build/benchmark-transcript
```

It compares the previous repeated scans with cached derivation and checks equivalent results. Timings measure model lookups, not complete SwiftUI rendering.

For a history-cache export benchmark (100 rooms, 20,000 messages, ten exports), run:

```sh
SIDETABLE_HISTORY_BENCHMARK=1 swift test --package-path Packages/ApronCore --filter benchmarkManyRoomHistoryExport
```

The benchmark is skipped by default. Compare the same build configuration on an idle machine; fixture creation is outside the measured interval.

For a transcript rendering benchmark, which scrolls 150 real message rows (text, embeds, and mixed) through a lazy stack offscreen and reports per-step timings and text views created:

```sh
TEST_RUNNER_SIDETABLE_BENCHMARK=1 xcodebuild -project Sidetable.xcodeproj -scheme Sidetable -derivedDataPath build/bench \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- SWIFT_OPTIMIZATION_LEVEL=-O \
  '-only-testing:SidetableTests/renderBenchmarkRebuildsLoadedRows(corpus:)' test | grep BENCH
```

To measure main-thread time per live snapshot update with a populated conversation open (300 rooms, 2,000 users), run the same command with `'-only-testing:SidetableTests/renderBenchmarkLiveSnapshotUpdates()'`; `TEST_RUNNER_SIDETABLE_BENCHMARK_STEPS` sets the number of updates.

The same command also runs `'-only-testing:SidetableTests/renderBenchmarkLaunchRestoresSavedConversations()'` (main-thread time to restore one server's saved conversations, 20 rooms of 500 messages) and `'-only-testing:SidetableTests/renderBenchmarkConcurrentThumbnails()'` (wall time for twelve photo thumbnails requested together, on first view and after a relaunch).

It is skipped in normal test runs. Run one instance at a time on an otherwise idle machine; compare builds by alternating runs.

App tests use an in-memory credential store, never macOS Keychain. The test scheme sets `SIDETABLE_TESTING=1`, and the hosted app starts with preview data instead of loading real accounts. Tests may inject their own `CredentialStore`; normal app launches continue to use Keychain.

## Protocol probe

Without `--local-mutations` or `--local-history`, the probe only signs in as a guest and loads rooms/history. Mutation tests are restricted to loopback hosts. They create test rooms/messages in the local server, so use a disposable database or `--store memory`.

The command-line probe exercises the same protocol core as the app:

```sh
swift run --package-path Packages/ApronCore apron-probe wss://server.apron.chat/
swift run --package-path Packages/ApronCore apron-probe wss://server.apron.chat/ --inspect-threads
swift run --package-path Packages/ApronCore apron-probe ws://127.0.0.1:8080/ws --local-mutations
```

## Upload integration

The opt-in native upload test requires a disposable reference server listening on port 18080:

```sh
# From the reference-server checkout:
go run ./cmd/aprond --addr 127.0.0.1:18080 --store memory --upload.dir /tmp/sidetable-test-uploads
# From this repository:
TEST_RUNNER_SIDETABLE_UPLOAD_INTEGRATION=1 make test-app
```

This test posts only to loopback. It simulates a lost acknowledgement, verifies original-operation retry, uploads and downloads the file, and checks that the consumed write URL cannot be reused. The normal test suite skips it.

## History integration

The loopback-only `--local-history` probe additionally seeds 240 messages in a disposable public room and verifies that a fresh reader loads a recent page, then fetches the rest without duplicates:

```sh
swift run --package-path Packages/ApronCore apron-probe ws://127.0.0.1:8080/ws --local-history
```

## Preview fixtures

Use `--preview --preview-links --preview-composer` to inspect outgoing link cards with deterministic local image fixtures, without fetching metadata or sending messages. Composer UI regression tests verify image display and removal/restoration, preservation of the URL, and persistence of exclusions across conversation changes. To additionally verify the native website fetcher and submitted original OpenGraph image URL/dimensions against the public statusbar site, run `TEST_RUNNER_SIDETABLE_LIVE_LINK_PREVIEW=1 make test-app`; the live test is skipped by default.

Use `--preview --preview-sign-in` to inspect the v9 browser-code sign-in screen without connecting. Preview fixtures include Markdown in Development and sample upload states in Design. Launch with `--preview --preview-development` or `--preview --preview-uploads` to open either directly. `--preview --preview-history` displays the older-history control without making network requests. `--preview --preview-latest` opens a long conversation to verify that its latest message is visible by default. `--preview --preview-arrivals` adds three live messages after opening; add `--preview-reading` to check the badge while positioned in older history.

For isolated room layout screenshots, run the built app with `--preview --render-preview /tmp/room.png --preview-room-details --preview-private-room`. Replace `--preview-room-details` with `--preview-room-editor` to inspect the editor. Add `--preview-unread-divider` to `--preview-room-details` to inspect the unread-message boundary. Use `--preview-mute-timers` to inspect timed and indefinite sidebar indicators alongside an unread badge. Use `--preview-panels` for two conversations side by side; add `--preview-narrow` to check horizontal overflow. The renderer prints the actual output path inside the app's temporary directory.

## Reference-server compatibility

The reviewed protocol is saved verbatim in [PROTOCOL.md](../PROTOCOL.md), at revision [`b8f2b263`](https://github.com/shazow/apron/blob/b8f2b263a25f63deca549c6cd4740b41306ce7eb/PROTOCOL.md) (v9, reviewed 2026-10-29; upstream document date remains 2026-10-27), alongside [the extension definitions](../EXTENSIONS.md). See [the compatibility record](protocol.md) for implemented changes and optional features outside the client’s scope. Replay fixtures remain pinned to [`75a61490`](https://github.com/shazow/apron/tree/75a61490fdad2a38323a2cc65a6c167770d627c9) (v9); see [the update record](../plans/010-protocol-v9.md). Current v9 integration uses reference server `cfcd12a4cf60e072fe71feea244ef95b929b5f11`; earlier v8 checks used `067083815be6b113e7d35f6569fa35dee0052fd5`. From its checkout:

```sh
go run ./cmd/aprond --addr 127.0.0.1:8080 --store memory
```

Room/history handling also incorporates the later v9 delivery-field clarifications: omitted live delivery fields retain their values, delivery fields inside historical room records are ignored, and history response bounds still update pagination. Regression tests cover these rules; the replay-fixture pin above remains unchanged.

Unread panel regression: launch with `--preview --preview-restored --preview-unread-clear` to open an older position with 49 unread messages. Clicking **Latest** must clear the sidebar unread count and the New divider. Launch with `--preview --preview-restored-short` to reopen a short conversation at a saved position; **Latest** must not appear. Launch with `--preview --preview-latest --preview-unread-recent` to open at the latest message with two unread: the unread count clears but the New divider stays until you scroll away and return. Native clipping tests verify partially visible and offscreen panels do not qualify as readers.

Use `--preview --preview-panels --preview-members` to inspect the members column at the far right with different member lists in General and Development. The members UI test verifies focus changes, search reset, closing the active discussion, and column order and top alignment, and collapsing members to a narrow right-hand strip and expanding it with the persistent people icon.

Message context-menu UI coverage right-clicks plain text and Markdown directly, checks selected-text Copy and the Message Actions submenu, and verifies reply dispatch. Native text tests cover wrapping, selection preservation, Markdown styling, links, and menu availability.

Use `--preview --preview-threads` for eight threads with summaries and descending activity times. The sidebar UI test covers recent-thread ordering, summary display, older-thread disclosure, and keeping the selected thread visible.

Use `--preview --preview-apron-cards` for same-server room and profile cards. The UI test checks local details and direct profile navigation; app tests cover message excerpts, deleted and unloaded messages, account isolation, duplicate embeds, code blocks, and local-only preview removal.

## Custom emoji

Use `--preview --preview-custom-emoji --render-preview /tmp/sidetable-emoji.png` for local animated and static emoji in messages and reactions. The fixture includes adjacent keys, overlapping colons, links, code, hidden entries, and unknown-key fallbacks. Use `--preview --preview-emoji-picker --render-preview /tmp/sidetable-emoji-picker.png` to inspect categories and the combined picker. All fixture catalogs and images use data URLs; they make no network requests. Toggle macOS Reduce Motion to verify the static-image path.

Hosted tests cover catalog validation and URL policy, bounded raster decoding, cache isolation and stale-load cancellation, request concurrency, memory limits, text matching, copy/selection behavior, and completion.

Use `--preview --preview-server-details --render-preview /tmp/server-details.png` to inspect server information and sharing, `--preview --preview-custom-emoji --preview-server-management --render-preview /tmp/server-management.png` for management forms, and `--preview --preview-upload-guidance --render-preview /tmp/upload-guidance.png` for attachment guidance. Management actions are disabled in preview mode. Add `--preview-cooldown` to the normal preview to inspect the composer countdown.

Add `--preview-server-emojis` to the server-management renderer to inspect the slide-out emoji grid. Use it with `--preview-custom-emoji` for a local catalog, including hidden emoji. Save is disabled in preview mode.

Use `--preview --preview-room-references --render-preview /tmp/room-references.png` to inspect room and numeric thread references alongside unknown-ID and code fallbacks.

Use `--preview --preview-composer --preview-rich-composer --render-preview /tmp/rich-composer.png` to inspect reference tokens and Markdown styling in a draft. Use `--preview --preview-rich-editor --render-preview /tmp/rich-editor.png` for Edit Message. Hosted tests cover raw-text round trips, clipboard serialization, atomic deletion, undo/redo, input-method composition, and Unicode/CRLF source positions.

Use `--preview --preview-inline-edit --render-preview /tmp/inline-edit.png` to inspect message editing in the compose area. The UI test `testEditingUsesComposerAndCancelRestoresTheUnsentDraft` verifies that editing opens no sheet/window and Cancel restores the draft.
