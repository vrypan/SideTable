# Changelog

## Unreleased

### Changed

- Upgrade the Sparkle update framework and release tools to 2.10.1.

- Keep app tests independent of macOS Keychain with in-memory credentials and an isolated preview host.
- Compute member profiles and sorting once per list render.
- Reuse emoji search results and precompute catalog search text.

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
