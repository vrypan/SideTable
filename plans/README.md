# Implementation Plans

Plans remain in this directory. The initial client is committed at `698614f`; the historical status report records its verification and limitations. The conversation-polish plan was prepared using the improve skill on 2026-10-19.

| Plan | Purpose | Status | Dependencies |
| --- | --- | --- | --- |
| [001](001-macos-client-design.md) | Native client architecture and design | Reference | — |
| [002](002-implementation-plan.md) | Original implementation milestones | Partially implemented; see 003 | 001 |
| [003](003-implementation-status.md) | Initial implementation evidence and remaining work | Historical report | 002 |
| [004](004-conversation-polish.md) | Native Markdown blocks and attachment progress/cancel/retry | IN PROGRESS — implementation complete; Xcode-hosted/GUI verification pending | Initial client |

## Execution order

004 is implemented; its evidence records the remaining test-host/GUI validation limits. Prove Markdown rendering before selecting its dependency; verify upload retry semantics before exposing retry controls. The plan extends the conversation/file milestones in 002 without declaring the broader release work complete.

Implementation statuses: TODO, IN PROGRESS, DONE, or BLOCKED with a reason. Update the relevant row and record verification evidence in the plan.

## Deferred directions

Connection/authentication hardening, incremental history loading, broader native interaction testing, passkeys, and distribution remain separate milestones. No additional code audit findings are asserted by this scoped planning pass.
