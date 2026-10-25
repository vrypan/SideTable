# Changelog

## Unreleased

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
