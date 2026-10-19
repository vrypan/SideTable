# Connection Recovery and Lifecycle

Status: IMPLEMENTED, 2026-10-19. Continues milestone 3 of [002](002-implementation-plan.md).

## Scope

Make interrupted connections safe across sleep/wake, network loss, explicit reconnect, and overlapping authentication. Keep existing fixed-head history recovery and uncertain-send behavior. Incremental backward history loading remains a separate step.

## Implementation

- Detach transport, pending requests, timers, buffers, and transient presence before awaiting socket shutdown. Old cleanup must not change a replacement connection.
- Own and cancel the announcement timeout alongside heartbeat and reconnect tasks. Check connection generations before queued sends, automatic sign-in, recovery cleanup, and state-changing RPC results.
- Suspend connections while the workspace sleeps or the network is unavailable. Reconnect once both are available, respecting `retry_after`. Explicitly stopped or denied sessions stay stopped until the user reconnects.
- Reject overlapping sign-ins. Ignore obsolete app-level authentication completions after replacing a session, and invalidate email proposals when their connection is lost.
- Never automatically replay an interrupted message operation. Preserve existing explicit retry with the original operation ID.

## Acceptance and verification

- [x] An old socket may finish closing after the replacement reaches ready without overwriting its state.
- [x] Pending requests fail promptly on interruption; replacement sockets never receive an automatic replay.
- [x] Sleep/network availability prevents new connections and resumes only active sessions.
- [x] Terminal denial and server retry delays survive availability changes.
- [x] Interrupted automatic sign-in cannot change a stopped/newer session.
- [x] Core and app regression suites and the app build pass.

Verification: `make test-core` passed all 14 tests (five new lifecycle regressions). `make test-app` passed 21 tests; the opt-in loopback upload test was skipped (22 declared tests). The app and UI-test sources compiled. `git diff --check` passed. No public-server requests or mutations were made.

Native sleep/wake and path events are wired through `NSWorkspace` and `NWPathMonitor`. Physical sleep/network switching requires a manual Mac check; deterministic tests exercise the corresponding session transitions without manipulating the host network.
