# Architecture

Shipwright is a modular monolith in strict TypeScript on Bun, migrating command by command from
bash (`scripts/`) to `src/`. Full design:
[the migration spec](superpowers/specs/2026-10-13-shipwright-ts-migration-design.md). Agent
instructions: [AGENTS.md](../AGENTS.md).

## Contexts

Ten bounded contexts. The authoritative command → context mapping is
[`docs/plans/port/progress.json`](plans/port/progress.json); this table is the summary.

| Context | Responsibility |
|---|---|
| delivery | Pipelines, build loop, stages, worktrees; runs on the durability contract |
| orchestration | Daemon, dispatch, fleet, remote workers, connect, launchd, all on `WorkQueue` |
| planning | Triage, in-run decomposition (a feature DAG; it no longer files issues) |
| quality | One independent evaluator, holdout checks, test generation, evidence |
| learning | Memory, discovery, retros, one gated optimizer |
| intelligence | Cost, and a static per-stage model and effort table |
| integrations | GitHub, tracker intake, CI, webhooks, PR lifecycle |
| observability | Status, DORA, vitals, logs, traces, dashboard over the journal |
| teams | tmux sessions (a viewer only), team stages, reaper |
| platform | Doctor, setup, init, prep, upgrade, release |

Commands on the spec's don't-port list (§7.5) survive only as aliases or "removed" stubs that name
the replacement. Today only `platform` has code: `hello`, the end-to-end reference port.

## Layers and rules

    cli/ ──► contexts/<ctx>/index.ts ──► application/ ──► domain/
     │                                       │
    main.ts ──constructs──► adapters/ ──implement──► ports (kernel or context)

| Path | Holds |
|---|---|
| `src/shared/kernel/` | `Result`, shared ports (`ProcessRunner`, `AgentRunner`, …), durability ports; types only |
| `src/contexts/<ctx>/domain/` | Pure logic: entities, state machines, policies |
| `src/contexts/<ctx>/application/` | Use cases; depend on domain and ports only |
| `src/contexts/<ctx>/index.ts` | The context's public API; the only file others import |
| `src/adapters/` | The only code that touches processes, files, network, env, tmux or Claude |
| `src/cli/` | Thin commands: parse args, call one use case, render output |
| `src/main.ts` | Composition root: builds adapters and wires them into use cases |
| `src/testing/` | `createTestEnv()`, fakes and contract suites; never imported by production code |

Example path: `src/cli/commands/hello.ts` → `src/contexts/platform/index.ts` →
`application/hello.ts` → `domain/greeting.ts`.

### Fitness rules

Enforced by `bun run arch` (part of `bun run check`). Every failure names the rule and the fix.

| # | Rule | Tool |
|---|---|---|
| F1 | Domain (and the kernel) is pure: no I/O, no Node or Bun built-ins | dependency-cruiser |
| F2 | Application never imports `adapters/` or `cli/` | dependency-cruiser |
| F3 | Contexts meet only at `index.ts`; production code never imports `src/testing/` | dependency-cruiser |
| F4 | No import cycles | dependency-cruiser |
| F5 | `Bun.spawn`, `Bun.$`, `fetch`, `process.env`, `node:fs` only in adapters and `main.ts` | ast-grep |
| F6 | The Agent SDK is imported only by `adapters/agent/` | ast-grep |
| F7 | Files ≤ 300 lines, functions ≤ 40; the baseline may only shrink | size ratchet |
| F8 | Tests use `createTestEnv()` paths, never the real home or environment | ast-grep |

Planned, follow them now:
- **F9** (Wave 1): agents get no GitHub token and no permission bypass.
- **F10** (Waves 1–2): GitHub side effects go only through the fenced, idempotent `integrations`
  adapter, with an `IdempotencyKey` and a `FenceToken` in the signature.

Workflows: no `${{ }}` expression of any kind inside a `run:` script or an `actions/github-script`
`script:` body; values go through `env:`. This check is strict, with no baseline.

Config: [`.dependency-cruiser.cjs`](../.dependency-cruiser.cjs), [`sgconfig.yml`](../sgconfig.yml)
with [`tools/arch/rules/`](../tools/arch/rules), [`tools/arch/size-ratchet.ts`](../tools/arch/size-ratchet.ts)
with [`arch-baseline.json`](../tools/arch/arch-baseline.json),
[`tools/arch/workflow-injection.ts`](../tools/arch/workflow-injection.ts).

## Claude access

All Claude calls go through the `AgentRunner` port, implemented once in
[`src/adapters/agent/`](../src/adapters/agent) on `@anthropic-ai/claude-agent-sdk` (pinned).
`decide<T>` is one-shot, tool-less and schema-validated; `runTask` is agentic with an allowlist of
tools. Untrusted text is passed only as delimited data. The child environment is built from an
allowlist, so `GH_TOKEN` never reaches an agent. See ADR-0003.

## Deployment modes and durability

One codebase, three modes; the mode is configuration (ADR-0005).

| Mode | Durability adapter | Services | Lands |
|---|---|---|---|
| M1 local | SQLite (`bun:sqlite`, in-process) | none | Wave 1 |
| M2 server | Postgres | one Postgres | Wave 2 |
| M3 multi-machine | Postgres; workers pull over outbound connections | the same Postgres, over TLS or Tailscale | Wave 2 |

Run state goes through four ports in
[`src/shared/kernel/durability.ts`](../src/shared/kernel/durability.ts), never through ad-hoc files:

- `WorkQueue`: atomic claim with a lease, heartbeat, complete (terminal for both outcomes); dedupe
  key; `notBefore` (the timer wake); per-pool `maxActive`.
- `RunJournal`: append-only, per run; a lease appends only to its own run.
- `Signals`: durable approvals, cancel and pause.
- `SideEffects`: a reconcile-then-act ledger keyed by `IdempotencyKey`.

Each claim increments the item's lease epoch, which is its fence token. Every journal append and
every side effect checks it, so a machine that lost its lease can no longer write, push or comment.

Every adapter must pass
[`src/testing/contracts/durability-contract.ts`](../src/testing/contracts/durability-contract.ts).
In Wave 0 the in-memory fake runs it, and the existing SQLite event-log store runs
[`event-log-contract.ts`](../src/testing/contracts/event-log-contract.ts). That `EventLog` port is
transitional: it is synchronous, so it cannot run on Postgres, and `RunJournal` absorbs it in
Wave 1 (ADR-0005). The SQLite durability
adapter joins in Wave 1; Postgres joins in Wave 2, nightly and on adapter changes.

### Delivery loop (Wave 1, planned)

Stages and transitions are data in `delivery/domain`. A pure `decide(state, event) → Command` picks
the next step: run a stage, perform a side effect, await a signal, sleep, or finish. The orchestrator
interprets each command against the ports above. Gates are `awaitSignal('approve:<stage>')`; nothing
is auto-approved. Because the domain is pure, an external engine could interpret the same commands
later (ADR-0005).

## Migration

Strangler via the router (ADR-0004). `scripts/sw` sends a command to `bun src/cli.ts` through
`run_ts` once its entry in `progress.json` is `parity-green`; reverting is one router line. Status
moves `bash` → `porting` → `parity-green` → `bash-deleted`, and a bash script is deleted only at
`bash-deleted`. `bun run port:check` blocks premature routing; `bun run parity` runs the bash
suites against the TypeScript command in a sealed sandbox. Tooling: [`tools/port/`](../tools/port).

## Decisions

- [0001 TypeScript on Bun](adr/0001-typescript-on-bun.md)
- [0002 Modular monolith with Clean Architecture](adr/0002-modular-monolith.md)
- [0003 Claude Agent SDK behind one port](adr/0003-claude-agent-sdk.md)
- [0004 Strangler migration with bash suites as parity oracle](adr/0004-strangler-with-parity-oracle.md)
- [0005 Durability contract and three deployment modes](adr/0005-durability-contract-and-deployment-modes.md)
- 0006 Credentials and capability separation (planned, Wave 1)

Generated reference: [`docs/reference/cli.md`](reference/cli.md) (`bun run docs:gen`).
