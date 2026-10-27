# Protocol compatibility

[Documentation](README.md) · [Protocol snapshot](../PROTOCOL.md)

`PROTOCOL.md` is the unmodified upstream specification reviewed for this implementation:

- Repository: https://github.com/shazow/apron
- Revision: `6a3425f0b157e6cbb011190debc76ed636419df7`
- Protocol version: 9; document updated 2026-10-27.
- Previous reviewed revision: `dc137a11a20a6cb08efb0dfad6e9b1b64a76814f` (2026-10-26). The revision before that, `75a61490fdad2a38323a2cc65a6c167770d627c9`, is recorded in [the v9 migration](../plans/010-protocol-v9.md).
- License: CC0-1.0. The existing replay fixtures retain their separate revision and license in [third-party notices](../THIRD_PARTY_NOTICES.md).

## Changes since the previous review

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

- `make test-core`: 58 tests passed, including all pinned upstream replay fixtures and the new history scope test.
- The snapshot is byte-identical to `PROTOCOL.md` at the recorded revision.
- `git diff --check`: passed. No live-server verification was performed for this update.
