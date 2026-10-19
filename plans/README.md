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
| [007](007-incremental-history.md) | Recent-page startup and on-demand older history | DONE — interactive scroll validation pending | 006 |
| [008](008-window-attention.md) | Per-window attention and unread handling | DONE — native focus interaction checks pending | 007 |
| [009](009-cache-management.md) | Saved-conversation usage and clearing controls | DONE — Settings interaction checks pending | Initial client |

## Execution order

004 and 005 are committed at `4d4922b` and `5807b6a`. Their full ordinary app suite now passes through Xcode; GUI interaction checks remain. 006 implements connection-lifecycle hardening and is committed at `7704ef6`. 007 adds incremental backward history loading and bounds initial loading to one recent page per top-level room. Both have deterministic test coverage; 007 also passed a real loopback pagination probe. 007 is committed at `a40fe43`. The selected follow-ups are implemented in 008 (attention/unread handling) and 009 (cache controls). Broader native interaction testing and large-room profiling remain next. The broader release work in 002 is still incomplete.

Implementation statuses: TODO, IN PROGRESS, DONE, or BLOCKED with a reason. Update the relevant row and record verification evidence in the plan.

## Deferred directions

Configured-server email/token interoperability, broader native interaction testing, large-room profiling, passkeys, and distribution remain separate milestones. No additional code audit findings are asserted by this scoped planning pass.
