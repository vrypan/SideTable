# Usage and storage

[Documentation](README.md) · [SideTable](../README.md)

## Connecting

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
- File staging and per-file upload progress, cancellation, and recovery controls; inline images, bounded downloads, and Quick Look. Media on origins not declared by the server remains an explicit browser link.
- Local mention/reply notifications, server status and mute controls, and account-scoped cached launch views.

## Room details and controls

The conversation header shows member counts and, for private rooms, participant avatars and a privacy notice. Expand the room or thread description to read its full Markdown content.

Use the **Room actions** (ellipsis) menu, or right-click a room or thread in the sidebar, to copy a room link, edit its title and description, mute notifications for one hour, eight hours, or until resumed, unmute, or leave. Leaving asks for confirmation. Editing preserves privacy and other room settings; the server decides whether the action is allowed. Shared links do not grant access to private rooms. Muted rooms and threads show a monochrome crossed-out bell and time remaining at the right of their sidebar row. Fixed-width labels keep the bells aligned, and indefinite mutes show ∞. Hover for the exact end time. Server-wide and parent-room mutes are included, and expired indicators disappear automatically.

## Private conversations

Open another person's user card from a message author, mention, or member list, then click **Message**. SideTable opens an existing private top-level room with just the two of you, or creates a private room and adds that person. The conversation appears in the room sidebar. Nothing is sent until you compose and send a message.

This requires an active, writable connection and a server that allows private rooms and adding other users. If adding the person fails, the card shows the server error; the newly created private room may remain in your room list. Group rooms and threads are not reused as one-to-one conversations.

## Messages and shortcuts

Return sends; Shift-Return inserts a line break. Command-K switches conversations, Command-F finds loaded messages, and Command-comma opens Settings. Hover over a message for Reply, React, Start Thread, and Copy Link; tooltips identify each button. The same actions remain available by right-clicking, alongside edit, move, and delete. Start Thread suggests a title and quotes the source in its description, then prepares a reply to that source in the new thread; it leaves the original message in place. Copy Link produces an Apron web link (recipients still need server access); it is unavailable for endpoints with query parameters to avoid sharing credentials. The emoji button and React open the full seven-column emoji picker directly. The first row remembers your seven most recent emoji selections across launches, filling unused slots with common choices. Scroll to browse, or search the full catalog. Emoji shortcode selections also update recents. Right-click a reaction badge to see the accounts that used it; select an account to open its profile. Left-click still toggles your reaction when posting is allowed. Type `@` for member completion, `#` for known rooms and threads, or `:name` for emoji. Arrow keys select a suggestion, Tab or Return inserts it, and Escape dismisses it. The `@` menu inserts a member reference at the caret. The smiley button opens a searchable emoji picker; reaction menus offer More emoji… for the same picker.

Edit your own message to rename uploaded files or remove attachments and link previews. Removing an uploaded file or stream asks for confirmation; changes apply only after Save Changes. Pending uploads cannot be removed or renamed. If the message changes elsewhere while the editor is open, reopen it before saving. Generated GitHub previews are labeled “Preview on this Mac”: hiding those is local to your account on this Mac and persists across launches; it does not alter the message for other clients.

## Reading conversations and threads

Room and member listings are reused for 30 seconds during conversation navigation, and identical in-flight listing requests are shared. If the server rate-limits these requests, SideTable shows a retry countdown and pauses further listings for the server's requested delay. History loading continues; room, member, or thread details may be stale until you reopen the conversation or retry the action after the countdown. Reconnecting does not bypass the cooldown.

A **New** divider marks the first unread message in a conversation or thread. It stays at the visit’s read boundary while you read, even after the unread badge clears, and resets when you reopen the conversation. It is hidden while filtering messages.

Unread badges clear when the key window is displaying the latest messages, including when focus returns. Background, minimized, filtered, and older-history views do not mark conversations read or suppress alerts. Each conversation pane tracks its own attention; closing one cannot clear another pane's registration. Window navigation remains shared across windows.

Settings → Storage shows saved-conversation sizes and offers per-server or global clearing. Clearing preserves live conversations, drafts, read markers, and sign-in, and prevents those saved copies from being recreated until the next launch. The saved-conversation size covers conversation files; downloaded media has a separate disk-usage display and clear control. Avatar memory is not included.

SideTable remembers the last selected server, room, and open thread for your account and restores them on the next launch. Unavailable threads fall back to their parent room. Exact scroll positions are not saved across launches.

Conversations reopen at the last viewed message, saved separately per server, account, and room or thread. SideTable loads older history when needed to restore that position. If the message is no longer retained, it uses the nearest available message; conversations without a saved position or read marker open at the latest message. Welcome notices and thread links appear above the messages. Browsing older history preserves your position and shows a count of new live messages. Choose that button to jump to the latest messages; sending also jumps to your outgoing message. At the bottom, new arrivals stay in view. Edits, reactions, and older-history pages do not add to the arrival count or force scrolling. Returning to the app preserves the current position; unread clears only in an active window displaying the latest messages.

Thread descriptions are shown as expandable Markdown above the replies, preserving quoted source messages and multiline context. Opening a thread loads its replies directly, without depending on member or child-room listings. Reopening it or reconnecting refreshes its history; the thread header also offers Refresh. Viewing a thread does not join it, so unjoined threads need refresh to fetch later replies.

History initially loads up to 200 log changes per top-level room. “Load earlier messages” fetches another page; “Show earlier messages” reveals records already loaded. Loading errors offer retry. Search covers loaded messages, and unread counts reflect loaded history rather than the full server archive. Reconnect recovery fills changes since the last checkpoint before enabling writes.

Connections suspend during system sleep or network loss and recover when both the Mac and network are available. Server retry delays are respected; denied connections require an explicit reconnect. Interrupted sends remain available for explicit retry with their original operation IDs.

## Profile bios

On servers advertising `ext:bio` or `ext`, profile cards show a short plain-text bio, with clickable HTTP(S) links. Open your own profile and choose Add Bio… or Edit Bio… to update it. The limit is 250 Unicode code points; clearing the field removes your bio. Save errors leave your draft open. Bios are read from current profile data, not old messages.

## Avatars and attachments

Inline raster avatars, server-hosted avatars, and external HTTPS avatars load automatically. A shared in-memory cache reuses images across conversations, member lists, and profiles. Avatar updates refresh every view, including when the URL stays the same. The cache clears on sign-out or account changes. Invalid or unavailable images show initials.

The members panel lists active members first, then sorts names alphabetically. A green dot marks active members, and role badges show server-provided roles such as admin. Search by name, user ID, or role. Hover over a member for status, roles, and bio; click to open the full profile. Presence indicators are hidden while disconnected or viewing saved data.

Paste a screenshot or copied file into the message composer to attach it to the current draft, with or without existing text. To capture a screenshot to the clipboard, press Control–Shift–Command–4 and select an area, then click the composer and press Command–V. Ordinary copied text stays text; pasted attachments are sent only when you send the message.

Attachment images appear inline within 420 × 300 points; click to open Quick Look. File cards offer Preview and Save, with additional actions in their context menu. Link cards show the server-provided Open Graph title, site name, description, and thumbnail. Preview metadata supplied by Apron takes precedence. For public GitHub PRs, issues, commits, and repositories without a preview, SideTable fetches a fallback from GitHub’s unauthenticated API (up to three links per message, excluding code). API results are cached for an hour; unavailable or private links fall back to their URL details. SideTable does not scrape linked web pages. Media loads from the chat server and its declared media origins.

Downloaded attachments and preview images are cached on disk across launches, separately for each server and account. Reopening or saving a cached attachment reuses its bytes. The cache keeps up to 256 MiB and evicts the least recently used files. Settings > Storage > Clear Downloaded Media removes these copies; signing out clears that server’s media. Automatic image downloads are capped at 8 MiB; explicit downloads at 64 MiB. Files already cached can display without another network request. The system may purge the cache when disk space is needed.

The Dock icon shows the total unread message count across all servers and conversations. macOS asks for badge permission when unread messages first appear; allow it to show the count. If badges are disabled, enable them in System Settings > Notifications > SideTable. This is separate from SideTable’s mention-and-reply alerts. The badge clears when no unread messages remain and keeps updating while SideTable is running with its windows closed.

Closing the last window keeps sessions running. **Quit** ends connectivity and notifications. Apron servers can read the messages they host; transport uses TLS, not end-to-end encryption.

## Sharing and opening links

Shared message links use Apron’s standard `https://link.apron.chat/#server=…&room=…&message=…` format; threads use their own room ID. Choose **File > Open Link…** (⌘L) to paste an HTTPS or `apron:?` link. Review the destination before opening it. SideTable can open rooms, threads, messages (loading older retained history as needed), and user profiles. Invite/sign-in links require an explicit **Sign In** action and cannot replace an already signed-in account. Links never automatically join rooms. SideTable registers `apron:` and `sidetable:` URL handlers. For example, `sidetable://open?server=wss://server.apron.chat/&room=general` opens the destination-review dialog. Install and launch the updated app before using links from a browser. See [browser link integration](deep-links.md) for the `link.apron.chat` setup.
