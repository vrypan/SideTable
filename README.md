# Sidetable

A native macOS client for [Apron](https://github.com/shazow/apron), written in Swift 6 with SwiftUI and AppKit. Requires macOS 14 or later.

## Build and run

Open `Sidetable.xcodeproj`, choose the **Sidetable** scheme and **My Mac**, and run. The core is a local Swift package; the app has no external package dependencies.

```sh
make build
make run
```

The app is built at `build/Build/Products/Debug/Sidetable.app`. Development builds use ad-hoc signing. Distribution signing/notarization requires your own Apple Developer identity. Development was verified with Xcode 27.1 / Swift 6.4, targeting macOS 14.

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
- Messages, replies, explicit mentions, reactions, edits, deletion, moves, and server commands, subject to advertised capabilities and policy.
- Per-room text drafts, selectable text, adjustable message size, local find, and a keyboard conversation switcher.
- Ordered protocol processing, snapshot replay, fixed-head history recovery, retention resets, reconnect backoff, and uncertain-delivery handling.
- File staging, HTTP uploads, trusted-origin image thumbnails, bounded downloads, and Quick Look. Cross-origin attachments remain explicit browser links.
- Local mention/reply notifications, server status and mute controls, and account-scoped cached launch views.

Return sends; Shift-Return inserts a line break. Command-K switches conversations, Command-F finds loaded messages, and Command-comma opens Settings. Right-click a message for reply, reaction, edit, move, or delete actions. The `@` menu inserts a member reference.

Closing the last window keeps sessions running. **Quit** ends connectivity and notifications. Apron servers can read the messages they host; transport uses TLS, not end-to-end encryption.

## Tests

```sh
make test-core   # Swift Testing: upstream replay fixtures and session/recovery tests
make test-app    # App storage and media-origin tests
make test-ui     # XCUITest preview navigation; requires a usable GUI automation session
make check      # Core tests and application build
```

The checked-in Xcode project is generated from `project.yml`. After adding source files, run `xcodegen generate` (XcodeGen is needed only for regeneration).

The command-line probe exercises the same protocol core as the app:

```sh
swift run --package-path Packages/ApronCore apron-probe wss://server.apron.chat/
swift run --package-path Packages/ApronCore apron-probe ws://127.0.0.1:8080/ws --local-mutations
```

Without `--local-mutations`, the probe only signs in as a guest and loads rooms/history. Mutation tests are restricted to loopback hosts. They create test rooms/messages in the local server, so use a disposable database or `--store memory`.

Reference-server revision used for integration: `067083815be6b113e7d35f6569fa35dee0052fd5`. From its checkout:

```sh
go run ./cmd/aprond --addr 127.0.0.1:8080 --store memory
```

## Current limits

This is an initial working client, not complete web-client parity. Native passkeys, remote push/APNs, streaming/HTML embeds, full CommonMark block rendering, and multiple accounts on one endpoint are not implemented. Markdown currently supports native inline formatting with preserved line breaks. Attachment downloads are limited to 64 MiB and thumbnails to 8 MiB; automatic media loading is restricted to the server’s own origin.

History currently recovers complete available logs before enabling a session, while the transcript reveals messages in batches of 150. Very large logs need further profiling and incremental loading. UI automation and public native connectivity are environment-dependent; see the recorded verification results in [the implementation status](plans/003-implementation-status.md).

## Layout

`Sidetable/` contains the native application, feature views, and platform integrations. `Packages/ApronCore/` contains the independent wire models, reducer, transport, session, fixtures, and probe. App and UI tests live in `SidetableTests/` and `SidetableUITests/`. Design and implementation plans stay under [`plans/`](plans/001-macos-client-design.md).
