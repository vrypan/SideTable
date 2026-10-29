# Changelog

## Unreleased

### Added

- Drop files and images anywhere on a conversation to attach them, not only on the composer. The conversation is outlined while a drop will be accepted. Images dragged from a browser, Photos, or Preview are attached in their original format.
- Add **View Source** to the message context menu. It shows the message record as formatted JSON and can copy it.

### Changed

- Keep the account's token in Keychain when signing out, so you can switch between several accounts on one server. The sign-in screen lists each account you signed out of, with **Continue as @account** and **Forget**. Guest identities are not kept, and removing the server deletes all its saved tokens.
- Explain how to get a sign-in token. For Apron's public server, the sign-in screen lists the steps (sign in at web.apron.chat and send `/invite-device <name>`) and links to the website; for other servers it mentions `/invite-device`.
- Accept the sign-in link that `/invite-device` replies with, as well as a bare token, in the token field. The link must be for the same host.
- Expand **Sign in with a token** when the server offers no email or browser sign-in.

### Fixed

- Stop pinging and reconnecting while the sign-in screen is idle. If the server closes the connection there, SideTable no longer shows a reconnection error; it reconnects when you sign in or request a code, and asks for a new code only if one was pending.
- Clicking an image or file could open Quick Look showing "No items selected" while the composer or a message's text had keyboard focus.

## 0.4.1 — 2026-10-29

### Changed

- Open the file chooser directly from the attach button, without first showing the server's upload limits. Hover over the button to see the limits; files the server would reject are still refused with an error.

## 0.4.0 — 2026-10-29

### Added

- Support the October 29 Apron protocol update, including server permissions, categorized rate limits, and media policies.

- Show servers' custom emoji in messages, reactions, the emoji picker, and `:name` completion. Animated emoji respect Reduce Motion, hidden emoji still render in history, and copying text keeps each emoji's shortcode.

- Manage a server from **Servers → Manage Server**: change its title, description, or icon, and add, replace, or remove custom emoji. Management opens in its own window. Emoji changes stay pending until **Save**, and can be undone or discarded first.

- Open **Server Details…** from the server icon or menu to see the server's description and address, copy the address, or share a server link.

- Reference rooms and threads with `#room_id`. Known references show the room or thread title and open that conversation; type `#` in the composer to search for one.

- Show `@user` and `#room` references in the composer and message editor as compact name tokens. Copying and sending keep the original IDs, and Backspace removes a whole token.

- Show a countdown when a server asks SideTable to wait. Send, Retry, and loading buttons become available again when it ends; blocked messages are never resent automatically.

- Show the server's accepted file types, size limits, and image resizing limits in the attachment picker, and check files before attaching them.

- Show private-room usage in Server Details, Browse Rooms, and the private-room form when a server limits private rooms.

### Changed

- Edit messages in the conversation's compose area instead of a separate sheet. Your unsent draft and attachments are kept and return after **Save Changes** or **Cancel**.

- Redesign the emoji picker: a compact ten-column grid with Favorites, All, Server, Unicode, and Recent tabs, keyboard navigation, details on hover, and pinned favorites. Hold Shift to choose several emoji without closing it.

- Refresh saved conversations at most once a minute while conversations are active, instead of every few seconds. This reduces CPU and disk use during busy chats. The first change is still saved within seconds, and anything newer than the saved copy is fetched on the next launch.

### Fixed

- Treat reactions that differ only by an emoji's presentation form, such as ❤ and ❤️, as the same reaction.

- Keep your account's permissions when the server updates only part of your profile, such as your status.

- Show names and avatars from room membership in the members list when a member's profile has not been loaded.

- Show completion suggestions only in the composer you are typing in, not in other open panels.

- Restore the normal pointer when a resize drag ends outside the divider.

- Limit simultaneous attachment downloads, and cancel downloads that are no longer needed.

- Save conversations for the next launch without blocking the interface, and skip servers with no changes.

- Download attachments, avatars, custom emoji catalogs, and link previews in network-sized chunks instead of one byte at a time. Downloads use far less CPU, and large attachments arrive much faster on fast connections.

- Open faster with saved conversations: restoring them at launch takes less than half the time, and messages from the server decode faster.

- Show photo thumbnails sooner when several appear at once. Images now decode in parallel, and reading a large downloaded file no longer delays other attachments.

- Reduce interface work on each live update in servers with many rooms and members. The room list, room titles, and composer suggestions are prepared once per update instead of by every message and view.

- Keep messages on screen formatted while scrolling long histories, instead of discarding and re-parsing their Markdown.

- Keep the room list in the same order across launches when rooms share a title, so the same room is selected by default.

## 0.3.6 — 2026-10-28

### Changed

- List private rooms in their own **Private Rooms** sidebar section, below public rooms. The section appears only when you belong to a private room. Untitled private rooms keep the lock before their participants' avatars.

### Fixed

- Scroll long code blocks when scrolling over them, instead of the conversation. A gesture that starts where the block cannot move further still scrolls the conversation, and reaching a block's end no longer carries the same gesture into the conversation.

- Align **Other threads** with the thread rows under its room, and show its expanded threads at the same indent, instead of placing its arrow at the sidebar's edge.

- Prevent a crash in the members panel when a server reports an invalid or excessively large member count.

- Keep oversized Markdown messages within the display limit even when they contain multibyte characters or long combining sequences. Copy Text still provides the full source.

- Reduce memory retained by decoded images and parsed Markdown with byte budgets. Oversized message sources are no longer cached, and signing out or clearing saved conversations releases cached Markdown.

- Reduce memory growth during bursts of live updates by combining queued snapshots while preserving connection and account transitions, incoming messages, token changes, and avatar refreshes.

- Rebuild message timelines only for affected rooms, keeping cached timelines for other conversations available during live updates.

- Avoid scanning and sorting the entire media cache after every download. Track disk usage incrementally and remove old files in batches when the cache fills, preserving files open in Quick Look.

- Stop retaining unused incoming typing state and refreshing the interface for it. Outgoing typing and read notifications continue to work.

## 0.3.5 — 2026-10-28

### Changed

- Show untitled private rooms by their participants: the other members' avatars in the sidebar and conversation header, and their names wherever the room's title appears, leaving out your own unless you are the only member. Private chats started from the **Message** button no longer get an automatic title, and **Edit Room** lets you clear a private room's title. Public rooms and threads still require one.

### Fixed

- Keep the **New** divider above messages that arrived while SideTable was in the background or another window had focus, instead of moving it past them on return. An unfocused conversation keeps its reading position, and new messages collect below it with the new-messages button showing.

## 0.3.4 — 2026-10-28

### Added

- Click a reply's quoted line to jump to and highlight the original message, loading older history when needed.

- Show same-server Apron link cards in messages, with conversation details, loaded message excerpts, and user profiles. Cards navigate directly and use local data without fetching previews.

- Sort sidebar threads by latest known activity, show summaries and unread counts, and group older threads under a disclosure. Keep recent, selected, and unread threads visible.

### Changed

- Open threads like rooms: clicking a thread replaces the active panel's conversation instead of always adding a panel. Command-click or **Open in New Panel** opens a thread beside the current conversation.

- Show the conversation header’s room actions and the sidebar’s account options as plain three-dot buttons, without the circle and dropdown arrow. Offer **Open in New Panel** only for conversations that are not already open, so it no longer appears in a conversation’s own menu.

- Open links to rooms, messages, and users on the same Apron server directly. Other-server links and sign-in links still show destination review.

- Remember whether the members panel is expanded, and its width, across launches. Its divider now works like the conversation panels’: drag to resize, double-click for the default width.

- Widen discussion dividers’ drag targets and highlight them on hover to make resizing easier.

- Set code blocks two points smaller than message text and size them to their lines, leaving room for always-visible scroll bars but no empty space below. Give inline code a padded, rounded background in addition to its fixed-width font, at the message text size, fitted to each line when it wraps.

- Review compatibility with the 2026-10-27 revision of Apron protocol version 9, which defines history requests without a room. SideTable already requests history per room, so no client changes were needed.

### Fixed

- Show command replies in the conversation where the command was sent, after the latest message at the time and rendered as Markdown when sent that way, instead of above all history. Show private notices without a room, such as a server welcome, once below the conversations with a dismiss button instead of in every room. Show a rejected command’s server error instead of reporting uncertain delivery, and send text starting with `//` as a message beginning with `/`.

- Keep transcript scrolling fast during long sessions. Message text views are reused instead of accumulating as rows are rebuilt.

- Show rebuilt Markdown messages at their final layout in the first frame, reusing parsed content instead of parsing again on each rebuild.

- Show inline images sooner after relaunch from small cached thumbnails, decode them off the main thread, and reserve their size with a loading indicator so rows no longer grow when images appear.

## 0.3.3 — 2026-10-27

### Added

- Show reply and react buttons beside message timestamps after a 200 ms hover delay. Buttons hide when the pointer leaves; replying preserves the current draft.

### Changed

- Make the members panel resizable and extend it to the top-right edge of the window. Its people button collapses it to a narrow vertical strip and expands it again. Members continues to follow the active discussion.

### Fixed

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
