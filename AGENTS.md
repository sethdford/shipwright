# Shipwright — agent guide

Shipwright orchestrates autonomous Claude Code agent teams: delivery pipelines from issue to PR,
a daemon that processes labeled issues, fleet operations, memory, and cost and DORA metrics.
It is being migrated from bash (`scripts/`) to TypeScript on Bun (`src/`). Design:
`docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md`.

## Definition of done

- `bun run check:fast` after each change (~10–25 s; a Stop hook runs it too).
- `bun run check` before you call work done (< 60 s). CI runs the same command.

A change is done when `bun run check` passes. Failure messages name the rule and the fix.

## Layout (TypeScript)

- `src/contexts/<ctx>/domain` — pure logic. No I/O, no Node/Bun built-ins.
- `src/contexts/<ctx>/application` — use cases; depend on ports only.
- `src/contexts/<ctx>/index.ts` — the only file other code may import from a context.
- `src/shared/kernel` — `Result`, shared ports and the durability ports (types only).
- `src/adapters` — the only code that touches processes, files, network, env, tmux or Claude.
- `src/cli` — thin commands; `src/main.ts` wires adapters into use cases.

Contexts: delivery, orchestration, planning, quality, learning, intelligence, integrations,
observability, teams, platform.

## Fitness rules (spec §3.3, ADR-0008)

`bun run arch` enforces: F1 pure domain · F2 application never imports adapters or cli · F3 contexts
only via `index.ts`; `src/` and `dashboard/` never import each other · F4 no cycles · F5 I/O (also
aliased globals, `node:os`, `node:vm`, `node:module`, `bun:ffi`, computed imports, `eval`) only in `src/adapters`, `src/main.ts`,
`src/cli.ts`, `src/testing` · F6 Agent SDK only in `adapters/agent` · F7 files ≤ 300 lines,
functions ≤ 40 · F8 tests use `createTestEnv()` · F9 no GitHub token or permission bypass for agents ·
F10 `gh` writes only in `src/adapters/github/gh-github-writer.ts` · F11 bash: no `eval`/`sh -c`/
`python -c` with expansions, no `curl | sh`, no `${{`, no `| grep -q`, no BSD `date -j`/`date -r` · F12 dashboard layers, subprocesses only in
allowlisted services, no shell string from data · workflows never swallow gate or marker errors.
Bash and `dashboard/server.ts` debt is ratcheted (`tools/arch/findings-baseline.json`): never add a
finding; after removing some, run `bun tools/arch/ast-scan.ts --write-baseline`. Never suppress a rule
in place. Enforced later: F10 in full (`FenceToken` on run-scoped writes, Wave 1b; all integrations, Wave 2).

## Deployment modes and state

One codebase, three modes; the mode is configuration: M1 local (embedded SQLite), M2 server
(long-running daemon and dashboard), M3 multi-machine (pull workers, shared Postgres).
Run state goes through the durability ports in `src/shared/kernel/durability.ts` (`WorkQueue`,
`RunJournal`, `Signals`, `SideEffects`; spec §6.1), never through ad-hoc files. Every write carries
the lease's fence token; a stale fence fails.

## Migration

- `docs/plans/port/progress.json` is the source of truth for what is ported. Pick the next `bash`
  entry and port it into its context. Make its parity suite pass and set its status to
  `parity-green` first; only then flip its router line in `scripts/sw` to `run_ts`.
- Use the `port-bash-command` skill and the `porter` subagent for this.
- Never route a command to TypeScript before its parity suite passes (`bun run port:check`, `bun run parity`).

## Safety

- No `${{ }}` expression of any kind inside a workflow `run:` script; use step `env:` or `$GITHUB_*` (#8533).
- Never build a shell command string from request, issue, PR or model data, anywhere. Pass an argv
  array (`ProcessRunner`, `execFileSync`) with validated input (#8534).
- Claude calls go through the `AgentRunner` port only; untrusted text is passed as data in the user turn.
- Agents never receive `GH_TOKEN`/`GITHUB_TOKEN`, `bypassPermissions` or `--dangerously-skip-permissions` (F9).
- GitHub side effects (push, PR, comment, label, merge) only through the `integrations` adapter, with an
  `IdempotencyKey` and a `FenceToken` (F10).
- Tests use `createTestEnv()`; never touch the real `HOME`, `~/.shipwright` or tmux server.
- Dispatch, retries and auto-filing pass `shipwright gates check --retry N` / `intake check` first;
  exit 0 is the only "go" and every gate fails closed. Workflows read `SHIPWRIGHT-*` markers only via
  `scripts/ci/bot-comments.sh`. Never run `gates check`/`breaker check` on the real repo to look
  (they write the incident issue); use `breaker status`. Operators: `docs/safety-runbook.md` (ADR-0007).

## Bash (until each command is ported)

Bash 3.2 compatible, `set -euo pipefail`. Run suites with `bash scripts/sw-test-all.sh --pattern <re>`;
the runner isolates tmux. Details: `.claude/rules/bash.md`. Legacy command reference:
`docs/reference/legacy-guide.md`.

## Docs

`docs/architecture.md`, `docs/adr/`, generated `docs/reference/` (`bun run docs:gen`).
