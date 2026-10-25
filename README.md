# SideTable

A native macOS client for [Apron](https://github.com/shazow/apron), written in Swift 6 with SwiftUI and AppKit. Requires macOS 14 or later.

## Build and run

Open `Sidetable.xcodeproj`, choose the **Sidetable** scheme and **My Mac**, and run. The core is a local Swift package. Native Markdown parsing uses pinned Swift Markdown and swift-cmark dependencies; in-app updates use Sparkle 2.10.0. Xcode resolves these dependencies.

```sh
make build
make run
```

The app is built at `build/Build/Products/Debug/SideTable.app`. Development builds use ad-hoc signing. Distribution signing/notarization requires your own Apple Developer identity. Development was verified with Xcode 27.1 / Swift 6.4, targeting macOS 14.

To see sample conversations without connecting or changing saved accounts:

```sh
make preview
```

## Versions and releases

**SideTable > About SideTable** shows the build version. Builds use the highest `vX.Y.Z` release tag reachable from the current commit:

- A clean tagged commit shows `0.1.0`.
- Later commits show `0.1.0-<commit>`; tracked changes append `-dirty`.
- Before the first tag, builds use the source plist’s `0.1.0` baseline plus the commit hash. Source archives without Git metadata use the plist version alone.

Both `CFBundleShortVersionString` and `CFBundleVersion` use the numeric release version, without an offset or manual build counter. The full development label is stored separately as `SideTableVersion`. Xcode and `make build` generate the versioned plist inside the build directory before signing; the tracked source plist stays unchanged. Build labels ignore untracked files, but release preparation requires a completely clean working tree. Fetch release tags and history when building from a shallow checkout.

To prepare a release, add notes under `## Unreleased` in [Changelog.md](Changelog.md), commit your work, then run:

```sh
make release VERSION=0.1.0
make build
```

`make release` requires a branch, a clean working tree, nonempty release notes, and an `X.Y.Z` version newer than all existing release tags. It dates the Unreleased section, commits it as `Prepare release 0.1.0`, and tags that commit `v0.1.0`. It leaves no empty Unreleased section; add one when starting the next changes. It does not build, push, or publish. Use a new release version for each distributed update; rebuilding a tag retains its version.

Version and release scripts require Git and Python 3.9 or later (`/usr/bin/python3`, supplied with the Xcode command-line tools). Project regeneration was verified with XcodeGen 2.46.0. `make test-tools` checks the release workflow in temporary repositories without changing this repository’s commits or tags.

## Binary distribution and updates

SideTable uses [Sparkle 2.10.0](https://sparkle-project.org/documentation/) for in-app updates. **SideTable > Check for Updates…** opens Sparkle’s update UI; **Settings > General > Updates** controls automatic checks. Distributed builds check automatically and ask before downloading/installing. Development, preview, and test builds never start the updater. No system profile is sent. Updates use signed archives verified before extraction; the app remains sandboxed using [Sparkle’s installer service](https://sparkle-project.org/documentation/sandboxing/).

Releases are universal macOS 14+ DMGs containing Apple silicon and Intel code. Downloads and `appcast.xml` are assets of the public [GitHub Releases](https://github.com/vrypan/SideTable/releases):

- Stable feed: `https://github.com/vrypan/SideTable/releases/latest/download/appcast.xml`
- Versioned download: `https://github.com/vrypan/SideTable/releases/download/vX.Y.Z/SideTable-X.Y.Z-universal.dmg`

GitHub’s [latest-release asset links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) require a published full release. Drafts and prereleases do not become the production update feed. Publish the DMG and its matching feed together; retain old release assets, since already-downloaded feeds may reference them.

### One-time setup

A Developer ID Application certificate with its private key must be available in the login Keychain. Packaging selects it automatically when exactly one is installed; otherwise set `SIDETABLE_SIGN_IDENTITY` to its name or SHA-1 from `security find-identity -v -p codesigning`. Xcode’s Archive/Export workflow signs the application and Sparkle’s nested helpers with the same team.

Create a dedicated Sparkle key:

```sh
make update-key
```

This downloads checksum-pinned Sparkle tools, creates or reuses the Keychain account `sidetable-ed25519`, and writes **only the public key** to `config/updates.json`. Commit that file before releasing. The private key stays in Keychain; back it up offline using Sparkle’s `generate_keys --account sidetable-ed25519 -x /secure/path/key` and keep the exported file out of this repository. The command refuses to replace a previously configured key. Follow Sparkle’s key-rotation guidance for a future rotation.

Store Apple notarization credentials once (the tool prompts for an app-specific password):

```sh
xcrun notarytool store-credentials sidetable-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Alternatively, reuse an existing notarytool Keychain profile by setting `SIDETABLE_NOTARY_PROFILE`, for example `scotty-notary`. Credentials are never stored in the repository. Install and authenticate GitHub CLI (`gh`) for draft uploads.

### Prepare and upload a release

After committing the code, public key, and Unreleased notes:

```sh
make check
make test-app
make release VERSION=0.1.0
make dmg
make notarize
make appcast
git push origin main v0.1.0
make github-draft
```

- `make dmg` requires a clean release tag and the matching Sparkle signing key. It archives and exports an optimized universal app, checks its identity, architecture, sandbox entitlements, and nested signatures, and creates a signed DMG with an Applications shortcut.
- `make notarize` submits that exact DMG to Apple, waits for acceptance, staples the ticket, and checks Gatekeeper. Apple’s result and diagnostic logs stay alongside the artifact.
- `make appcast` signs the final **stapled** bytes, embeds the version’s changelog notes, verifies the Sparkle signature, and checks feed URLs, versions, minimum macOS, and archive size. It does not upload anything.
- `make github-draft` verifies that GitHub’s tag matches the packaged commit, then uploads the DMG and appcast to a **draft** release using the generated notes. Review it on GitHub and publish it as the latest full release when ready.

Artifacts, the Xcode archive/dSYMs, notes, and logs live under `build/distribution/X.Y.Z/`. `build/distribution/release.json` identifies the current artifact and records checksums; later steps refuse modified or unnotarized files. Existing version directories are not overwritten. Inspect a failed packaging directory before removing it to retry; never replace an already published version. Do not edit a DMG after appcast generation.

Before the first public release, test the signed, notarized app on a clean Mac and exercise a real older-to-newer Sparkle upgrade, including canceling installation with unfinished attachments. Local tests cover updater gating, release preflight, metadata, and artifact validation; they do not substitute for that signed installation test. No binary is published by `make release` or `make dmg`.

## Connect

Click **Add Server**, enter a hostname or full WebSocket URL, then choose a sign-in method offered by the server. Explicit paths are preserved.

- Public demo: `wss://server.apron.chat/`. Guests can read; posting is controlled by the server. Native passkeys are not yet supported.
- Local reference server: `ws://127.0.0.1:8080/ws`.
- Remote endpoints require `wss://`. Unencrypted WebSockets are allowed only on loopback addresses.

Apron protocol versions 8 and 9 are supported. Guest, token, email-code, and v9 browser-code sign-in are supported when advertised by the server. For browser sign-in, choose **Open Sign-in Page**, sign in or create an account on the website, then enter its code in SideTable. The website may offer passkeys. Email and browser codes must be entered on the connection that requested them; request a new code after reconnecting. Saved tokens are kept in Keychain. Text drafts and a bounded recent-message cache stay in the app’s Application Support directory. Sign-out removes the server’s local account data. Staged attachments are not persisted.

## Features

- Multiple independently connected servers, room discovery/join/leave, private rooms, threads, and member management.
- User profiles with name, user ID, roles, presence, and avatars. Click a message author, a member, or your account to open a profile.
- Messages, replies, explicit mentions, reactions, edits, deletion, moves, and server commands, subject to advertised capabilities and policy.
- Per-room text drafts, selectable text, adjustable message size, local find, and a keyboard conversation switcher.
- Ordered protocol processing, recent-page startup, on-demand older history, fixed-head reconnect recovery, retention resets, reconnect backoff, and uncertain-delivery handling.
- Native Markdown paragraphs, headings, lists, quotes, and selectable code blocks with Copy Code. Raw HTML and Markdown images stay inert.
- File staging and per-file upload progress, cancellation, and recovery controls; trusted-origin image thumbnails, bounded downloads, and Quick Look. Cross-origin attachments remain explicit browser links.
- Local mention/reply notifications, server status and mute controls, and account-scoped cached launch views.

Return sends; Shift-Return inserts a line break. Command-K switches conversations, Command-F finds loaded messages, and Command-comma opens Settings. Hover over a message for Reply, React, Start Thread, and Copy Link; tooltips identify each button. The same actions remain available by right-clicking, alongside edit, move, and delete. Start Thread suggests a title and quotes the source in its description, then prepares a reply to that source in the new thread; it leaves the original message in place. Copy Link produces an Apron web link (recipients still need server access); it is unavailable for endpoints with query parameters to avoid sharing credentials. Right-click a reaction badge to see the accounts that used it; select an account to open its profile. Left-click still toggles your reaction when posting is allowed. The `@` menu inserts a member reference.

Unread badges clear when the key window is displaying the latest messages, including when focus returns. Background, minimized, filtered, and older-history views do not mark conversations read or suppress alerts. Each conversation pane tracks its own attention; closing one cannot clear another pane's registration. Window navigation remains shared across windows.

Settings → Storage shows saved-conversation sizes and offers per-server or global clearing. Clearing preserves live conversations, drafts, read markers, and sign-in, and prevents those saved copies from being recreated until the next launch. Sizes cover saved conversation files, not avatar memory or downloaded attachments.

SideTable remembers the last selected server, room, and open thread for your account and restores them on the next launch. Unavailable threads fall back to their parent room. Exact scroll positions are not saved across launches.

Conversations open at the latest message, including when initial history arrives after the view appears. Welcome notices and thread links appear above the messages. Browsing older history preserves your position and shows a count of new live messages. Choose that button to jump to the latest messages; sending also jumps to your outgoing message. At the bottom, new arrivals stay in view. Edits, reactions, and older-history pages do not add to the arrival count or force scrolling. Returning to the app preserves the current position; unread clears only in an active window displaying the latest messages.

Thread descriptions are shown as expandable Markdown above the replies, preserving quoted source messages and multiline context. Opening a thread loads its replies directly, without depending on member or child-room listings. Reopening it or reconnecting refreshes its history; the thread header also offers Refresh. Viewing a thread does not join it, so unjoined threads need refresh to fetch later replies.

History initially loads up to 200 log changes per top-level room. “Load earlier messages” fetches another page; “Show earlier messages” reveals records already loaded. Loading errors offer retry. Search covers loaded messages, and unread counts reflect loaded history rather than the full server archive. Reconnect recovery fills changes since the last checkpoint before enabling writes.

Connections suspend during system sleep or network loss and recover when both the Mac and network are available. Server retry delays are respected; denied connections require an explicit reconnect. Interrupted sends remain available for explicit retry with their original operation IDs.

Inline raster avatars, server-hosted avatars, and external HTTPS avatars load automatically. A shared in-memory cache reuses images across conversations, member lists, and profiles. Avatar updates refresh every view, including when the URL stays the same. The cache clears on sign-out or account changes. Invalid or unavailable images show initials.

Attachment images appear inline within 420 × 300 points; click to open Quick Look. File cards offer Preview and Save, with additional actions in their context menu. Link cards show the server-provided Open Graph title, site name, description, and thumbnail. Preview metadata supplied by Apron takes precedence. For public GitHub PRs, issues, commits, and repositories without a preview, SideTable fetches a fallback from GitHub’s unauthenticated API (up to three links per message, excluding code). API results are cached for an hour; unavailable or private links fall back to their URL details. SideTable does not scrape linked web pages. Media loads from the chat server and its declared media origins.

Downloaded attachments and preview images are cached on disk across launches, separately for each server and account. Reopening or saving a cached attachment reuses its bytes. The cache keeps up to 256 MiB and evicts the least recently used files. Settings > Storage > Clear Downloaded Media removes these copies; signing out clears that server’s media. Automatic image downloads are capped at 8 MiB; explicit downloads at 64 MiB. Files already cached can display without another network request. The system may purge the cache when disk space is needed.

Closing the last window keeps sessions running. **Quit** ends connectivity and notifications. Apron servers can read the messages they host; transport uses TLS, not end-to-end encryption.

## Tests

```sh
make test-core   # Swift Testing: upstream replay fixtures and session/recovery tests
make test-app    # Storage, Markdown, HTTP, and upload lifecycle tests
make test-ui     # XCUITest preview navigation; requires a usable GUI automation session
make test-tools # Release/version and distribution tests; no credentials or uploads
make check      # Release/version tests, core tests, and application build
```

The checked-in Xcode project is generated from `project.yml`. After adding source files, run `xcodegen generate` (XcodeGen is needed only for regeneration).

The command-line probe exercises the same protocol core as the app:

```sh
swift run --package-path Packages/ApronCore apron-probe wss://server.apron.chat/
swift run --package-path Packages/ApronCore apron-probe wss://server.apron.chat/ --inspect-threads
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

The loopback-only `--local-history` probe additionally seeds 240 messages in a disposable public room and verifies that a fresh reader loads a recent page, then fetches the rest without duplicates:

```sh
swift run --package-path Packages/ApronCore apron-probe ws://127.0.0.1:8080/ws --local-history
```

Use `--preview --preview-sign-in` to inspect the v9 browser-code sign-in screen without connecting. Preview fixtures include Markdown in Development and sample upload states in Design. Launch with `--preview --preview-development` or `--preview --preview-uploads` to open either directly. `--preview --preview-history` displays the older-history control without making network requests. Add `--preview-message-actions` to show the last message’s hover toolbar in previews. `--preview --preview-latest` opens a long conversation to verify that its latest message is visible by default. `--preview --preview-arrivals` adds three live messages after opening; add `--preview-reading` to check the badge while positioned in older history.

Without `--local-mutations` or `--local-history`, the probe only signs in as a guest and loads rooms/history. Mutation tests are restricted to loopback hosts. They create test rooms/messages in the local server, so use a disposable database or `--store memory`.

Protocol and replay fixtures are pinned to [`75a61490`](https://github.com/shazow/apron/tree/75a61490fdad2a38323a2cc65a6c167770d627c9) (v9); see [the update record](plans/010-protocol-v9.md). Current v9 integration uses reference server `cfcd12a4cf60e072fe71feea244ef95b929b5f11`; earlier v8 checks used `067083815be6b113e7d35f6569fa35dee0052fd5`. From its checkout:

```sh
go run ./cmd/aprond --addr 127.0.0.1:8080 --store memory
```

Room/history handling also incorporates the later v9 delivery-field clarifications: omitted live delivery fields retain their values, delivery fields inside historical room records are ignored, and history response bounds still update pagination. Regression tests cover these rules; the replay-fixture pin above remains unchanged.

## Current limits

This is an initial working client, not complete web-client parity. Native passkeys, remote push/APNs, streaming/HTML embeds, Markdown tables/extensions, syntax highlighting, and multiple accounts on one endpoint are not implemented. CommonMark blocks render natively. Parsing is limited to 64 KiB of input, 32 levels of nesting, and 4,096 nodes; over-limit content falls back to bounded plain text, with the full source available through Copy Text. Uploads are session-only: quitting stops transfers. Retry Same Operation retains files when acknowledgement is lost. Upload links are single-use, so an interrupted PUT offers Reattach to Composer rather than silently resending the message. Retry Upload is available only for a failure before any network transfer. A successful PUT waits for the server’s attachment snapshot; cancelling locally does not delete the message.

Attachment downloads are limited to 64 MiB and thumbnails to 8 MiB; automatic media loading is restricted to the server’s own origin.

History starts with a recent page and loads older pages on demand, while the transcript reveals messages in batches of 150. Very large logs still need further profiling. UI automation and public native connectivity are environment-dependent; see the recorded verification results in [the implementation status](plans/003-implementation-status.md).

## Layout

`Sidetable/` contains the native application, feature views, and platform integrations. `Packages/ApronCore/` contains the independent wire models, reducer, transport, session, fixtures, and probe. App and UI tests live in `SidetableTests/` and `SidetableUITests/`. Design and implementation plans stay under [`plans/`](plans/001-macos-client-design.md).

The app and Dock icon use `Sidetable/Resources/SideTable.icns`, copied directly from `brand/SideTable-Brand-Kit-v2/apps/macos/SideTable.icns`. The v2 icon uses an espresso-brown (`#3B2118`) symbol on golden yellow (`#FFD23F`), with transparent outer margins and reinforced artwork at small sizes. Follow the [v2 brand guide](brand/SideTable-Brand-Kit-v2/guide/SideTable-Brand-Guide-v2.md) for future updates. To repackage the supplied PNGs, run `iconutil -c icns brand/SideTable-Brand-Kit-v2/apps/macos/SideTable.iconset -o Sidetable/Resources/SideTable.icns`. Its bundle setting is maintained in `project.yml`; regenerate the Xcode project after changing that configuration. `assets/SideTable-dark.svg` is the previous monochrome variant and is no longer used by the app.

Shared message links use Apron’s standard `https://link.apron.chat/#server=…&room=…&message=…` format; threads use their own room ID. Choose **File > Open Link…** (⌘L) to paste an HTTPS or `apron:?` link. Review the destination before opening it. SideTable can open rooms, threads, messages (loading older retained history as needed), and user profiles. Invite/sign-in links require an explicit **Sign In** action and cannot replace an already signed-in account. Links never automatically join rooms. The system-wide `apron:` URL handler is not registered; paste links into Open Link.
