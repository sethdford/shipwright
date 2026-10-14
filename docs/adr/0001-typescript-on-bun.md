# 0001. TypeScript on Bun

Status: accepted · Date: 2026-10-13

## Context
About 120k lines of bash produced recurring injection, quoting and test-isolation bugs, including a
CI loop of 199 failed runs in one day (2026-10-13). Bash has no boundary between data and code.
Shipwright is glue around gh, git, tmux and Claude; it is I/O-bound, not CPU-bound. The dashboard
already runs on Bun.

## Decision
Write Shipwright in strict TypeScript (`strict` plus `noUncheckedIndexedAccess`) on Bun, with Biome
for lint and format and zod at every boundary. Bun is a required dependency. A
`bun build --compile` single binary is produced in the final migration wave (Wave 5).

## Consequences
- Types and schemas replace string parsing; processes take argv arrays, never shell strings.
- The TypeScript Claude Agent SDK is usable directly (ADR-0003).
- One toolchain for the CLI and the dashboard.
- Contributors need Bun; users without Bun are not supported.
- Rejected: C adds memory-safety risk for no benefit in I/O-bound glue. Go would share no code with
  the dashboard or the TypeScript Agent SDK.
