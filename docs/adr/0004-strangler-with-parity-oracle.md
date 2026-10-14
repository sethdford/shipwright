# 0004. Strangler migration with bash suites as parity oracle

Status: accepted · Date: 2026-10-13

## Context
A big-bang rewrite would deliver nothing until the end and drift from the bash behavior it replaces.
The existing bash test suites already describe that behavior: arguments, exit codes, files written
and output.

## Decision
Port one command at a time.
- `scripts/sw` keeps dispatching. Porting a command changes one router line to `run_ts <cmd>`, which
  execs `bun src/cli.ts`.
- A command's bash suite is its black-box parity oracle. `bun run parity` runs it against the
  TypeScript command in a sealed sandbox.
- `docs/plans/port/progress.json` tracks every capability: `bash` → `porting` → `parity-green` →
  `bash-deleted`. `bun run port:check` fails if the router sends a command to TypeScript before
  `parity-green`.
- The bash script stays until `bash-deleted`; the router shim is removed in Wave 5.

## Consequences
- Every step ships and is reversible by one router line. `hello` is the first: routed to TypeScript,
  `parity-green`, with `scripts/sw-hello.sh` still present.
- Bash and TypeScript coexist for a while.
- Suites that assert implementation details are rewritten to assert behavior, and the change is
  noted in the port's progress entry. A suite that asserts buggy behavior is fixed in bash first.
