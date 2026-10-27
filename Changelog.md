# Changelog

## 0.3.3 — 2026-10-27

### Added

- Click a reply's quoted line to jump to and highlight the original message, loading older history when needed.

- Show same-server Apron link cards in messages, with conversation details, loaded message excerpts, and user profiles. Cards navigate directly and use local data without fetching previews.

- Sort sidebar threads by latest known activity, show summaries and unread counts, and group older threads under a disclosure. Keep recent, selected, and unread threads visible.

- Show reply and react buttons beside message timestamps after a 200 ms hover delay. Buttons hide when the pointer leaves; replying preserves the current draft.

### Changed

- Remember whether the members panel is expanded or collapsed across launches.

- Restore the members panel at the width you left it. Its divider now matches conversation panels: drag to resize, double-click for the default width.

- Open links to rooms, messages, and users on the same Apron server directly. Other-server links and sign-in links still show destination review.

- Widen discussion dividers’ drag targets and highlight them on hover to make resizing easier.

- Make the members panel resizable and extend it to the top-right edge of the window. Its people button collapses it to a narrow vertical strip and expands it again. Members continues to follow the active discussion.

### Fixed

- Show command replies where they arrive in the conversation, rendered as Markdown when sent that way, instead of above all history. Show a rejected command’s server error instead of reporting uncertain delivery. Send text starting with `//` as a message beginning with `/` rather than as a command.

- Keep transcript scrolling fast during long sessions. Message text views are reused instead of accumulating as rows are rebuilt.

- Show rebuilt Markdown messages at their final layout in the first frame, reusing parsed content instead of parsing again on each rebuild.

- Show inline images sooner after relaunch from small cached thumbnails, decode them off the main thread, and reserve their size while loading so rows no longer grow when images appear.

- Remove the extra top margin above discussion panels.
- Keep sent messages at the bottom while the composer resizes and message content finishes laying out. Pressing Return to send no longer cancels automatic scrolling; scrolling away still does.

## 0.3.2 — 2026-10-27

### Added

- Show members in one right-hand panel that follows the active discussion, replacing the modal members sheet.

- Show website images in composer link cards using macOS Link Presentation. Preview fetching is cancellable and never delays sending.

- Preview up to three web links while composing, remove or restore individual previews, and send selected links as embeds alongside attachments. Drafts remember omitted previews. Available GitHub titles and descriptions accompany the message as optional fallback metadata; sending never waits for a preview fetch.

### Changed

- Keep the room’s thread list in the sidebar and remove its duplicate from the top of the transcript.

- Remove the message hover toolbar; message actions remain available by right-clicking.

### Fixed

- Open message actions when right-clicking unselected message text. Selected text keeps its native menu with a Message Actions submenu. The whole message is highlighted while its menu is open.

- Include available OpenGraph image URLs and attributes in outgoing link embeds so the server can proxy or replace them. Read website metadata directly with a local HTML parser; no third-party preview service is used.

## 0.3.1 — 2026-10-27

### Added

- Rearrange conversation panels by dragging their headers, or with **Move Panel Left** and **Move Panel Right** in the header's context menu. The new order is saved with the panel layout.

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
