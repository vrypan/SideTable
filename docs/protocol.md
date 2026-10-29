# Protocol compatibility

[Documentation](README.md) · [Protocol snapshot](../PROTOCOL.md) · [Extension snapshot](../EXTENSIONS.md)

`PROTOCOL.md` is the unmodified upstream specification reviewed for this implementation:

- Repository: https://github.com/shazow/apron
- Revision: `b8f2b263a25f63deca549c6cd4740b41306ce7eb`
- Protocol version: 9; reviewed 2026-10-29. Upstream still labels the document updated 2026-10-27.
- Previous reviewed revision: `6a3425f0b157e6cbb011190debc76ed636419df7` (2026-10-27). Earlier changes are recorded below and in [the v9 migration](../plans/010-protocol-v9.md).
- License: CC0-1.0 for `PROTOCOL.md`; the upstream MIT license for `EXTENSIONS.md` is reproduced in [third-party notices](../THIRD_PARTY_NOTICES.md). The existing replay fixtures retain their separate revision and license in [third-party notices](../THIRD_PARTY_NOTICES.md).

## Changes since the previous review

[shazow/apron#100](https://github.com/shazow/apron/pull/100) adds server metadata, rendering and reaction rules, and publishes `EXTENSIONS.md`, without a version bump.

| Upstream change | SideTable implementation |
| --- | --- |
| Normalized server address is identity | Normalize default ports, percent-encoded unreserved characters, escape case, and dot segments, while retaining distinct paths and queries. Compare existing saved addresses through the same normalization without rewriting credentials or account storage. |
| Live server `title`, `description`, `avatar` | Show current title/avatar in the sidebar and sign-in view, and description on sign-in, with the address always visible when selecting/signing in. Descriptions and welcome text use bounded CommonMark. Missing title falls back to the address; replacement frames remove omitted metadata without dropping content. Avatar loading uses the existing bounded raster-only loader. |
| Text direction | Isolate displayed labels and inline mention names; discard U+202A–U+202E at native text rendering. Keep wire text, identifiers, link targets, and Copy Text source unchanged. Native text paragraphs use natural writing direction. |
| Reaction equivalence and keys | Aggregate and toggle reactions without U+FE0F, counting each user once. Preserve raw records and unrecognized keys in outgoing sets. Unknown keys appear as placeholders with their key on hover. |
| `ext:permissions` | Use typed `write`, `add_members`, and `move_any` with the documented defaults. Commands remain available with `write: false`. Keep legacy guest-posting fallback only when `ext:permissions` is absent. |
| `ext:settings` | Honor read-cursor suppression centrally and hide/disable restricted member/room actions. Count only joined, non-thread private rooms for `private_rooms`. |
| `ext:limits` | Enforce account-scoped cooldowns for write groups, new uploads, and individual read methods. Unsupported or mismatched categories fall back to method cooldowns. Reject locally during cooldown; never silently replay writes. |
| `ext:media` | Gate media origins by capability. Match MIME patterns case-insensitively, using only the most specific limits. Check staged upload type/size before submission and send the same explicit Content-Type on PUT. Avatar and emoji command uploads select their own limits. Image resizing remains server-side. |
| `ext:bio` | Existing bounded plain-text bios already match the definition. |
| `ext:emoji` | Load the catalog on demand in a separate server/account cache. Render known keys in messages, CommonMark descriptions/welcome text, and reactions; preserve code and copyable keys. Animate bounded raster images, honor Reduce Motion, exclude hidden entries from the searchable categorized picker and completion list, and preserve text/placeholder fallbacks for unknown or unavailable keys. |
| `/server` commands and avatar dimensions | Existing slash-command uploads can send the suggested commands. Recommended image dimensions are server-side guidance, not a new rejection rule for clients. |

## Earlier review: `dc137a1` to `6a3425f`

One upstream change, [shazow/apron#99](https://github.com/shazow/apron/pull/99), without a version bump:

| Upstream change | SideTable implementation |
| --- | --- |
| `history` without `room_id` queries the combined log of every room the connection receives. Servers SHOULD support it; others reply `unsupported`, and clients fall back to one request per room. | No change needed. Room-capable servers always receive an explicit `room_id`, for sign-in catch-up and older pages alike. Only servers without the `rooms` capability receive the room-less form, and their single conversation is the combined log. Covered by a session test of request scope with and without `rooms`. A single combined catch-up request would be an optional optimization, not a compatibility requirement. |
| The slice is of the log, not the room; compaction folds memberships per room; the combined log's lower bound is the server's | Editorial for per-room requests, which are the only scoped requests SideTable sends. |

## Earlier review: `75a6149` to `dc137a1`

| Upstream change | SideTable implementation |
| --- | --- |
| Chosen status versus shown presence; optional offline `seen` | Preserve the signed-in user's chosen status from `you`. Display valid current offline timestamps in profiles. Discard stale timestamps on presence transitions and sign-in; never use recorded message authors as presence data. |
| Reject unoffered authentication schemes | Already enforced before authentication/proposal requests, including automatic token and guest sign-in. |
| A.4 share links and security rules | Existing HTTPS sharing, form encoding, first repeated value, unknown-key tolerance, destination review, token restrictions, and explicit token-scheme sign-in remain in place. Message and thread-description links now resolve omitted servers against their source server. Opening a link does not itself send a message or join a room. |
| Room delivery fields survive omission; historical rooms cannot overwrite them | Already implemented and covered by history regression tests. |
| History without `room_id` follows server policy | Room-capable servers receive explicit room IDs. Minimal servers use the unscoped history path and accept returned room IDs. |
| `room_list` user filtering is optional; joins at sign-in need not notify | No reliance on user filtering or initial join notifications: bootstrap obtains a room listing. |
| RTC delivery `null`, sign-in reset, and `refresh_after` replacing `ice_expires` | RTC remains unsupported; no RTC requests or ICE expiry logic exist to migrate. |
| Protocol licensing and editorial/security clarifications | Exact CC0 specification retained locally. Transport and external sign-in URL validation remain enforced. |

## Scope

The snapshot records the reviewed specification, not a claim that every optional capability is implemented. Native WebAuthn, state-bearing sign-in callbacks, push registration, RTC, and the experimental actions extension remain outside this update. External sign-in continues to use browser code entry. Unsolicited HTTPS token links require explicit review and use the `token` scheme. Supported wire versions remain 8 and 9.

## Future updates

Compare upstream `PROTOCOL.md` against the checked-in snapshot, including changes that do not bump the protocol version. Implement applicable changes, add regression coverage, then replace the snapshot verbatim and update this revision and compatibility record together. Keep fixture provenance separate unless fixtures are also refreshed.

## Verification

- `make test-core`: 70 tests passed, including normalized addresses, reaction equivalence, permission defaults/enforcement, live metadata replacement, private-room limits, and cooldown scope.
- `make test-app`: 205 tests passed, including custom emoji catalog validation, account/catalog invalidation, bounded image concurrency/cache size, animation, native attachments/selection/copying, and completion.
- Both snapshots are byte-identical to the files at the recorded revision.
- Rendered and visually inspected the sign-in preview with server metadata. Custom emoji previews cover messages/reactions and the picker.
- `git diff --check`: passed. No live-server integration or UI automation was run for this update.
