# SideTable Naming, Profiles, and Avatars

Status: implemented, 2026-10-19. Based on commit `4d4922b`.

## Scope

Use **SideTable** as the application name and provide read-only user profiles and image avatars in conversations, member lists, and the account area. Profile editing, direct messaging, and new server APIs are outside this change.

## Implementation

- The product, executable, bundle name, display name, window title, and user-facing application strings use SideTable. `make run` opens `SideTable.app`. The existing project/target/module identifiers and storage locations remain stable so the rename does not require an account or data migration.
- Clicking an author name/avatar, a member row, or the account identity opens a native profile sheet. Message context menus also offer View Profile. The sheet shows available name, canonical user ID, roles, current status, server, and a larger avatar, with Copy User ID and Done controls.
- `UserProfile` follows aliases, overlays current fields on recorded identity fields, and honors explicit empty/null values. Historical objects never modify the current-user store. Recorded presence is not displayed as current, and cached profiles are labeled as saved. There is no invented biography or profile-fetch RPC: Apron supplies identity through its existing user objects and room listings.
- `AvatarLoader` supports inline base64 PNG/JPEG/GIF/WebP and automatic server-hosted and external HTTPS image loading. Credentials in URLs, redirects, non-raster content, and arbitrary local-file URLs are rejected. Images are limited to 2 MiB and 16 million source pixels, and downsampled to 256 pixels. Unusable images retain the initials fallback.
- Each server shares an observable `AvatarCache` across conversations, member lists, account identity, and profile sheets. The in-memory cache retains up to 128 thumbnails; visible views keep their entries alive even after eviction. Concurrent requests for the same source are shared. Explicit avatar notifications refresh shared entries even when the URL is unchanged, and cancelled/obsolete loads cannot replace newer images. Network refreshes bypass the URL cache.
- Profile sheets dismiss and avatar caches clear on account changes/sign-out. Avatar images are not persisted to disk.

Protocol basis: Apron revision `9e3094c0ca10ca23d228924c29537da959ace613`, sections 3.3 (identity/current versus recorded fields) and 4.8.6 (avatars).

## Verification

- `make generate` and `make build` passed. The generated product and test-host paths agree on `SideTable.app/Contents/MacOS/SideTable`. Built Info.plist confirms `CFBundleName` and `CFBundleExecutable` are SideTable.
- `make test-app` passed: 20 tests executed successfully, including five profile/avatar tests; the opt-in loopback upload test was skipped (21 declared tests). `make test-core` passed all nine tests, including repeated same-URL avatar notifications.
- Tests cover current-field precedence, explicit clears/nulls, alias cycles, endpoint separation, recorded-presence handling, automatic external HTTPS loading, rejected schemes/content, image-size limits, native PNG decoding, shared request deduplication, same-URL invalidation, stale completion rejection, and cache reset.
- Native profile and conversation previews were rendered and inspected, including a generated inline raster avatar. Existing standalone-window sidebar/toolbar capture artifacts remain outside this change.
- A UI test for opening a profile from a conversation is included and compiles. GUI automation was not rerun because the preceding milestone established that this host times out enabling automation; profile click/keyboard/VoiceOver checks still need a working GUI automation host or manual pass.
- `git diff --check` passed. No public-server mutations were made.

Preview the sample account avatar in General, or render the standalone profile with `--preview --preview-profile --preview-light --render-preview profile.png`. Render output is written to the app container's temporary directory.
