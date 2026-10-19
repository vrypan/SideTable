# Implementation Plans

Plans remain in this directory. The initial client is committed at `698614f`; the historical status report records its verification and limitations. The conversation-polish plan was prepared using the improve skill on 2026-10-19.

| Plan | Purpose | Status | Dependencies |
| --- | --- | --- | --- |
| [001](001-macos-client-design.md) | Native client architecture and design | Reference | — |
| [002](002-implementation-plan.md) | Original implementation milestones | Partially implemented; see 003 | 001 |
| [003](003-implementation-status.md) | Initial implementation evidence and remaining work | Historical report | 002 |
| [004](004-conversation-polish.md) | Native Markdown blocks and attachment progress/cancel/retry | DONE — GUI interaction validation pending | Initial client |
| [005](005-profiles-and-avatars.md) | SideTable naming, user profiles, and avatars | DONE — GUI interaction validation pending | Initial client |
| [006](006-connection-recovery.md) | Connection lifecycle, sleep/wake, and network recovery | DONE — physical sleep/network checks pending | 002 milestone 3 |

## Execution order

004 and 005 are committed at `4d4922b` and `5807b6a`. Their full ordinary app suite now passes through Xcode; GUI interaction checks remain. 006 implements connection-lifecycle hardening from milestone 3 and is verified with deterministic tests. Incremental backward history loading and bounded room recovery are the next implementation steps. The broader release work in 002 is still incomplete.

Implementation statuses: TODO, IN PROGRESS, DONE, or BLOCKED with a reason. Update the relevant row and record verification evidence in the plan.

## Deferred directions

Configured-server email/token interoperability, incremental history loading, broader native interaction testing, passkeys, and distribution remain separate milestones. No additional code audit findings are asserted by this scoped planning pass.
