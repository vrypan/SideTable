# Changelog

## Unreleased

### Added

- Remember conversation history across launches and download only what changed since, including edits, deletions, and reactions. Settings → Storage sets how many messages each conversation keeps (default 500) and how much missed activity to catch up on (default 5 × 200 updates) before starting again from the latest messages.

- Restore open conversation panels, their order, active panel, browsed server, and panel widths across launches, with account isolation and support for an empty workspace. Restored panels close once the server reports that their room no longer exists.

- Keep conversation headers compact and equal in height, with search and members controls in each panel and room details available by clicking its name.
- Open rooms and threads in resizable side-by-side panels, with independent drafts, search, and scroll positions. Command-click a sidebar room or choose **Open in New Panel**; ordinary navigation changes the active panel. Panels can span servers, and horizontally hidden panels do not mark messages read.

- Expose message editing with a pencil button on hover.

- Make bare web URLs clickable in plain-text and Markdown messages.

### Fixed

- Hide **Latest** in conversations that fit on screen after reopening at a saved position; previously the button stayed and clicking it did nothing.

- Keep already loaded images and link previews in rebuilt message rows, so scrolling back to them does not shrink and regrow the transcript.

- Keep the transcript at the bottom when message heights are recalculated as a scroll settles, instead of jumping a few messages up.

- Isolate hover state from message content and keep action overlays mounted to avoid relayout when the pointer settles over a message.

- Observe reading positions without a two-way scroll binding, preventing saved message anchors from pulling the transcript away from the bottom.

- Wait 500 ms before showing message hover actions, cancelling the delay when the pointer leaves.

- Avoid redundant scroll-position writes and unrelated panel visibility checks while scrolling; let live scroll tracking use a natural anchor.

- Clear the **New** divider when you scroll or jump back to the latest message, while preserving it in background, hidden, or filtered panels. Opening a conversation at its latest message keeps the divider visible.

## 0.3.0 — 2026-10-27

### Added

- Mark where unread messages begin with a stable **New** divider in conversations and threads.

- Open user cards by clicking mentions, displaying known users by their current display names.
- Start private conversations from the **Message** button on user cards, reusing existing two-person private rooms and verifying privacy and membership before opening.
- Copy room links, edit titles and descriptions, mute or unmute notifications, and leave rooms through the header menu or sidebar right-click menu.
- Show room member counts, private-room participant avatars and privacy details, and expandable room descriptions.
- Show aligned monochrome mute icons and remaining time beside sidebar rooms and threads, including inherited mutes and indefinite durations.
- Display last-seen timestamps for users whose current presence is offline.
- Keep a local Apron protocol snapshot and compatibility record for future updates.

### Changed

- Give each conversation panel its own width, 430 points by default. Resizing a panel no longer takes space from its neighbours; the panels scroll horizontally when wider than the window, settle on panel edges, and the last panel fills leftover space. Double-click a divider to restore the default width. Widths are saved with the panel layout.

- Show display names without an additional user ID in message author headers.
- Reuse recent room and member listings and share identical in-flight requests to reduce server load.

### Fixed

- Resolve server-relative Apron links against the server that supplied the message or thread description.
- Respect room-list rate limits, show a retry countdown, and keep message history available while room details cannot refresh. Reconnecting also respects the cooldown.
- Clear stale last-seen timestamps when presence changes and prevent historical message authors from supplying current presence information.
- Keep sidebar edit dialogs stable during live room updates and open newly created threads under the room targeted by the context menu.

## 0.2.2 — 2026-10-26

### Changed

- Upgrade the Sparkle update framework and release tools to 2.10.1.

- Keep app tests independent of macOS Keychain with in-memory credentials and an isolated preview host.
- Compute member profiles and sorting once per list render.
- Reuse emoji search results and precompute catalog search text.
- Share one message timeline across transcript rows, counts, and observers per render.
- Batch conversation-state saves and write only changed files; flush pending changes when quitting.

### Fixed

- Wait for in-flight room and history loads when opening message links.
- Stop missing-message searches once history has passed the target.
- Open validated Apron links in Markdown messages and thread descriptions through destination review.

## 0.2.1 — 2026-10-25

### Added

- Show the total unread message count across servers on the Dock icon, including when all windows are closed. Request badge permission independently of mention notifications.
- Open `sidetable://open?…` and standard `apron:?…` links from other apps, reusing an existing window and going directly to destination review.

### Changed

- Restore the last viewed message when reopening a conversation or relaunching. Save positions per server, account, and conversation, load older history when needed, and fall back to an available message if the saved one is missing.

### Fixed

- Keep **Latest** aligned with the actual end while message rows finish layout, and stop following the bottom when you scroll away.
- Determine whether the conversation is at the bottom from the actual scroll viewport, rather than whether the bottom marker has been rendered.

## 0.2.0 — 2026-10-25

### Fixed

- Enable screenshot paste in the plain-text composer.
- Keep pasted files as attachments when the composer contains an active text composition, preserving the draft text.

### Added

- Display profile bios with website links and edit your own bio on servers supporting `ext:bio` or `ext`.

- Rename and remove attachments while editing messages, with deletion confirmation and local hiding for generated GitHub previews.

- Complete people, rooms, and emoji at the composer caret; browse a searchable emoji picker for messages and reactions.

- Paste clipboard screenshots and copied files into the message attachment queue.

- Repository, author, and MIT license links in the About window.

## 0.1.1 — 2026-10-25

### Changed

- Cache downloaded attachments and preview images across launches, with a 256 MiB limit and a Settings > Storage clear control.
- Render link previews using server-provided Open Graph titles, descriptions, site names, and images, with public GitHub API previews when metadata is missing.

- Show image attachments inline with bounded previews and click-to-Quick-Look; add file-type icons, download buttons, and attachment context menus.
- Allow attachment previews and downloads from server-declared media origins.

## 0.1.0 — 2026-10-25

### Added

- Native macOS Apron client with multiple servers, rooms, threads, Markdown messages, reactions, profiles, and attachments.
- Account-scoped drafts, cached conversations, unread notifications, and restored room/thread navigation.
- Standardized Apron sharing links and File > Open Link… (⌘L).
- Git-derived build versions in About SideTable and a `make release VERSION=X.Y.Z` workflow.

- Sparkle in-app updates, universal Developer ID DMG packaging, notarization, and GitHub Release drafts.

### Fixed

- Preserve current room delivery state when applying room updates and historical records.
