# 010 — Apron protocol v9

## Scope and source

Update SideTable from the reviewed v8 specification (`9e3094c0ca10ca23d228924c29537da959ace613`) to [v9, revision `75a61490fdad2a38323a2cc65a6c167770d627c9`](https://github.com/shazow/apron/tree/75a61490fdad2a38323a2cc65a6c167770d627c9). Compare `HISTORY.md`, the full protocol, schema, and replay fixtures. Keep compatibility with v8; reject unreviewed versions.

## Changes

- Accept v9 announcements and retain v8 support, including version-specific mention syntax.
- Implement advertised `external` sign-in using §4.11's code flow: propose without `return_url`, validate and open the returned URL in the default browser, then approve with the code on the proposing connection. Save the returned bearer token through the existing Keychain path.
- Permit HTTPS browser URLs and HTTP only on localhost/loopback; reject relative URLs, other schemes, missing hosts, and embedded credentials.
- Keep one pending email/external proposal in the session snapshot. A new proposal replaces code entry for the previous scheme. Disconnect clears local code entry because short codes cannot approve on another connection, even though v9 server proposals survive disconnect. Generation checks prevent stale responses from opening pages or changing a newer session.
- Parse complete mention IDs, including email addresses, plus tags, and federated `@`/`:` forms. Intersect with known users; never notify a user because their ID is a prefix of another ID.
- Refresh all 18 upstream replay fixtures and their provenance. Existing tombstone tie handling and recent-page startup already match v9.

## Deliberate limits

Native passkey ceremonies, callback/deep-link approval, and adding sign-in methods to an already authenticated account remain outside this update. Code entry needs no callback domain association or URL-state handler. Browser sign-in can use passkeys only when the server's page offers them. The current Go reference server advertises no `external` scheme; that flow is covered by scripted transport tests, not a real identity-provider integration.

The v9 `idle` field accepts `false` or elapsed seconds. SideTable does not emit idle reports, so no old boolean `true` remains to migrate. Empty strings used internally for the default conversation are local sentinels; no new empty room/user IDs are generated on the wire.

## Verification

- `make check`: passed; 33 core tests including all 18 upstream replay fixtures, followed by a successful native build.
- `make test-app`: passed; 26 executed tests and the existing opt-in upload integration test skipped.
- Pinned Go server `cfcd12a4cf60e072fe71feea244ef95b929b5f11`, disposable loopback memory store: guest authentication, room/thread creation, send/deduplication, reactions, edit/move/delete, reconnect, and history pagination all passed. A fresh reader loaded 199 recent messages and one older page, yielding 240 unique messages. The test server was stopped afterward.
- Public `wss://server.apron.chat/`: announced v9; guest sign-in and history loading passed (one joined room, 41 snapshots). No messages posted.
- Browser-code tests cover proposal replacement, safe URL handling, failed-code retry, token resume, unavailable schemes, and disconnect/stale completion. Live browser authentication remains unverified because the pinned server does not offer it.
- Native `--preview-sign-in` screenshot inspected: browser instructions, page button, code field, verification button, and alternative methods render clearly. Interactive browser/code entry and GUI automation were not run.
