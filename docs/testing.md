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

The reviewed protocol is saved verbatim in [PROTOCOL.md](../PROTOCOL.md), at revision [`dc137a11`](https://github.com/shazow/apron/blob/dc137a11a20a6cb08efb0dfad6e9b1b64a76814f/PROTOCOL.md) (v9, updated 2026-10-26). See [the compatibility record](protocol.md) for implemented changes and optional features outside the client’s scope. Replay fixtures remain pinned to [`75a61490`](https://github.com/shazow/apron/tree/75a61490fdad2a38323a2cc65a6c167770d627c9) (v9); see [the update record](../plans/010-protocol-v9.md). Current v9 integration uses reference server `cfcd12a4cf60e072fe71feea244ef95b929b5f11`; earlier v8 checks used `067083815be6b113e7d35f6569fa35dee0052fd5`. From its checkout:

```sh
go run ./cmd/aprond --addr 127.0.0.1:8080 --store memory
```

Room/history handling also incorporates the later v9 delivery-field clarifications: omitted live delivery fields retain their values, delivery fields inside historical room records are ignored, and history response bounds still update pagination. Regression tests cover these rules; the replay-fixture pin above remains unchanged.

Unread panel regression: launch with `--preview --preview-restored --preview-unread-clear` to open an older position with 49 unread messages. Clicking **Latest** must clear the sidebar unread count and the New divider. Launch with `--preview --preview-restored-short` to reopen a short conversation at a saved position; **Latest** must not appear. Launch with `--preview --preview-latest --preview-unread-recent` to open at the latest message with two unread: the unread count clears but the New divider stays until you scroll away and return. Native clipping tests verify partially visible and offscreen panels do not qualify as readers.

Use `--preview --preview-panels --preview-members` to inspect the members column at the far right with different member lists in General and Development. The members UI test verifies focus changes, search reset, closing the active discussion, and column order and top alignment, and collapsing/expanding members with the people icon in the navigation header.

Message context-menu UI coverage right-clicks plain text and Markdown directly, checks selected-text Copy and the Message Actions submenu, and verifies reply dispatch. Native text tests cover wrapping, selection preservation, Markdown styling, links, and menu availability.
