# SideTable

A native macOS client for [Apron](https://github.com/shazow/apron), written in Swift 6 with SwiftUI and AppKit. Requires macOS 14 or later.

## Build and run

Open `Sidetable.xcodeproj`, choose the **Sidetable** scheme and **My Mac**, and run. The core is a local Swift package. Native Markdown parsing uses pinned Swift Markdown and swift-cmark dependencies resolved by Xcode.

```sh
make build
make run
```

The app is built at `build/Build/Products/Debug/SideTable.app`. Development builds use ad-hoc signing. Distribution signing/notarization requires your own Apple Developer identity. Development was verified with Xcode 27.1 / Swift 6.4, targeting macOS 14.

To see sample conversations without connecting or changing saved accounts:

```sh
make preview
```

## Connect

Click **Add Server**, enter a hostname or full WebSocket URL, then choose a sign-in method offered by the server. Explicit paths are preserved.

- Public demo: `wss://server.apron.chat/`. Guests can read; posting is controlled by the server. Native passkeys are not yet supported.
- Local reference server: `ws://127.0.0.1:8080/ws`.
- Remote endpoints require `wss://`. Unencrypted WebSockets are allowed only on loopback addresses.

Guest, token, and email-code sign-in are supported. Email codes must be entered before their connection is lost; request a new code after reconnecting. Saved tokens are kept in Keychain. Text drafts and a bounded recent-message cache stay in the app’s Application Support directory. Sign-out removes the server’s local account data. Staged attachments are not persisted.

## Features

- Multiple independently connected servers, room discovery/join/leave, private rooms, threads, and member management.
- User profiles with name, user ID, roles, presence, and avatars. Click a message author, a member, or your account to open a profile.
- Messages, replies, explicit mentions, reactions, edits, deletion, moves, and server commands, subject to advertised capabilities and policy.
- Per-room text drafts, selectable text, adjustable message size, local find, and a keyboard conversation switcher.
- Ordered protocol processing, snapshot replay, fixed-head history recovery, retention resets, reconnect backoff, and uncertain-delivery handling.
- Native Markdown paragraphs, headings, lists, quotes, and selectable code blocks with Copy Code. Raw HTML and Markdown images stay inert.
- File staging and per-file upload progress, cancellation, and recovery controls; trusted-origin image thumbnails, bounded downloads, and Quick Look. Cross-origin attachments remain explicit browser links.
- Local mention/reply notifications, server status and mute controls, and account-scoped cached launch views.

Return sends; Shift-Return inserts a line break. Command-K switches conversations, Command-F finds loaded messages, and Command-comma opens Settings. Right-click a message for reply, reaction, edit, move, or delete actions. The `@` menu inserts a member reference.

Connections suspend during system sleep or network loss and recover when both the Mac and network are available. Server retry delays are respected; denied connections require an explicit reconnect. Interrupted sends remain available for explicit retry with their original operation IDs.

Inline raster avatars, server-hosted avatars, and external HTTPS avatars load automatically. A shared in-memory cache reuses images across conversations, member lists, and profiles. Avatar updates refresh every view, including when the URL stays the same. The cache clears on sign-out or account changes. Invalid or unavailable images show initials.

Closing the last window keeps sessions running. **Quit** ends connectivity and notifications. Apron servers can read the messages they host; transport uses TLS, not end-to-end encryption.

## Tests

```sh
make test-core   # Swift Testing: upstream replay fixtures and session/recovery tests
make test-app    # Storage, Markdown, HTTP, and upload lifecycle tests
make test-ui     # XCUITest preview navigation; requires a usable GUI automation session
make check      # Core tests and application build
```

The checked-in Xcode project is generated from `project.yml`. After adding source files, run `xcodegen generate` (XcodeGen is needed only for regeneration).

The command-line probe exercises the same protocol core as the app:

```sh
swift run --package-path Packages/ApronCore apron-probe wss://server.apron.chat/
swift run --package-path Packages/ApronCore apron-probe ws://127.0.0.1:8080/ws --local-mutations
```

The opt-in native upload test requires a disposable reference server listening on port 18080:

```sh
# From the reference-server checkout:
go run ./cmd/aprond --addr 127.0.0.1:18080 --store memory --upload.dir /tmp/sidetable-test-uploads
# From this repository:
TEST_RUNNER_SIDETABLE_UPLOAD_INTEGRATION=1 make test-app
```

This test posts only to loopback. It simulates a lost acknowledgement, verifies original-operation retry, uploads and downloads the file, and checks that the consumed write URL cannot be reused. The normal test suite skips it.

Preview fixtures include Markdown in Development and sample upload states in Design. Launch with `--preview --preview-development` or `--preview --preview-uploads` to open either directly.

Without `--local-mutations`, the probe only signs in as a guest and loads rooms/history. Mutation tests are restricted to loopback hosts. They create test rooms/messages in the local server, so use a disposable database or `--store memory`.

Reference-server revision used for integration: `067083815be6b113e7d35f6569fa35dee0052fd5`. From its checkout:

```sh
go run ./cmd/aprond --addr 127.0.0.1:8080 --store memory
```

## Current limits

This is an initial working client, not complete web-client parity. Native passkeys, remote push/APNs, streaming/HTML embeds, Markdown tables/extensions, syntax highlighting, and multiple accounts on one endpoint are not implemented. CommonMark blocks render natively. Parsing is limited to 64 KiB of input, 32 levels of nesting, and 4,096 nodes; over-limit content falls back to bounded plain text, with the full source available through Copy Text. Uploads are session-only: quitting stops transfers. Retry Same Operation retains files when acknowledgement is lost. Upload links are single-use, so an interrupted PUT offers Reattach to Composer rather than silently resending the message. Retry Upload is available only for a failure before any network transfer. A successful PUT waits for the server’s attachment snapshot; cancelling locally does not delete the message.

Attachment downloads are limited to 64 MiB and thumbnails to 8 MiB; automatic media loading is restricted to the server’s own origin.

History currently recovers complete available logs before enabling a session, while the transcript reveals messages in batches of 150. Very large logs need further profiling and incremental loading. UI automation and public native connectivity are environment-dependent; see the recorded verification results in [the implementation status](plans/003-implementation-status.md).

## Layout

`Sidetable/` contains the native application, feature views, and platform integrations. `Packages/ApronCore/` contains the independent wire models, reducer, transport, session, fixtures, and probe. App and UI tests live in `SidetableTests/` and `SidetableUITests/`. Design and implementation plans stay under [`plans/`](plans/001-macos-client-design.md).
