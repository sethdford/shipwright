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
the replacement. Code so far: `platform` (`hello`, the end-to-end reference port), `orchestration`
(the Wave 1a safety controls) and `integrations` (the incident writer port).

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
Why there are so many, and how ratchets work: [ADR-0008](adr/0008-fitness-functions-everywhere.md).
The current import graph is generated: [`docs/reference/dependency-graph.md`](reference/dependency-graph.md).

| # | Rule | Tool |
|---|---|---|
| F1 | Domain (and the kernel) is pure: no I/O, no Node or Bun built-ins | dependency-cruiser |
| F2 | Application never imports `adapters/` or `cli/` | dependency-cruiser |
| F3 | Contexts meet only at `index.ts`; production code never imports `src/testing/`; `src/` never imports `dashboard/` | dependency-cruiser |
| F4 | No import cycles | dependency-cruiser |
| F5 | I/O only in `src/adapters`, `src/main.ts`, `src/cli.ts` and `src/testing`: `Bun` members, `fetch`, `process.env`, `node:fs`, `node:os`, `node:process`, `node:vm`, `node:module` (`createRequire`), `bun:ffi`, network modules; also `Bun`/`process`/`globalThis` used as values, `globalThis?.x`/`global.x`, `window`/`self`/`globalThis` with a computed key (`window["fetch"]`), `import.meta.env`, `import.meta.require`, computed `import()`/`require()`, `eval`/`Function`, `new Worker`/`WebSocket`. Out of scope: a `Function` constructor reached through a value (`({}).constructor.constructor`) | ast-grep |
| F6 | The Agent SDK is imported only by `adapters/agent/` | ast-grep |
| F7 | Files ≤ 300 lines, functions ≤ 40; the baseline may only shrink | size ratchet |
| F8 | Tests use `createTestEnv()` paths, never the real home or environment | ast-grep |
| F9 | No permission-bypass spelling (in one string, template or `+` chain of literals) and no GitHub token name in `src/` or `dashboard/` (tests, `adapters/github` and `adapters/agent/privilege-guard.ts` excepted). Only `adapters/agent/agent-sdk-runner.ts` imports the SDK as a value, and it has exactly one `query` call, after `assertAgentOptions`. A `query` call takes options that are an object literal whose `env:` is a literal or a call such as `agentEnv()`, with a literal `permissionMode`, or a variable that `assertAgentOptions()` checks. `assertAgentOptions()` allowlists option keys, reads own data properties only (no getters, symbols or non-plain prototypes), requires `permissionMode: "dontAsk"` and refuses GitHub tokens in the env, compared case-insensitively. The runner asserts a frozen copy and passes that same object to `query`. `agentEnv()` drops the tokens. Bash: bypass flags, and `claude` (bare, quoted, behind an absolute path, after `command` or a wrapper such as `timeout`/`gtimeout`, or as `"$CLAUDE_BIN"`) without `env -u GH_TOKEN -u GITHUB_TOKEN` before it, ratcheted | ast-grep, unit tests, findings ratchet |
| F10 | `gh` write subcommands only in `src/adapters/github/gh-github-writer.ts`. Bash (ratcheted): `gh` writes (bare, quoted, absolute path or `$GH_BIN`; wrappers included), `gh api` writes, `git push` (bare or by path, `git stash push` excepted), and the verbs of `cache`, `project`, `ssh-key`, `gpg-key` and `codespace`. `curl` to `api.github.com` with a write method or a body is a separate ratcheted rule, `F10-bash-curl-github-writes` (one counted finding: the GitHub App token mint in `scripts/sw-github-app.sh`, debt for the TS port) | ast-grep, findings ratchet |
| F11 | Bash: no `eval`/`command eval`/`source /dev/stdin <<<` or `source /dev/stdin <<EOF` with an expansion; no `sh -c`, `"$SHELL" -c`, `/usr/local/bin/bash -c` (any directory), `python -c`, `node -e`/`-p`/`--eval=`, `perl -E`, a here-string or unquoted heredoc into a shell, `echo "$x" \| bash` (data piped into a shell), `xargs sh -c` with `{}` in the code, or `ssh host "cmd $x"` built from data; no download run as code (piped into a shell or an interpreter that reads stdin); no `${{`; no `grep -q` reading a pipe (SIGPIPE under pipefail; use `grep >/dev/null`, error, no baseline) | ast-grep (Bash), findings ratchet |
| F12 | Dashboard: browser bundle and server never import each other and neither imports `src/` (D1); `services/` is the bottom layer (D2); routes never import `server.ts` or each other (D3); no cycles (D4); processes are spawned only by allowlisted services (aliases of `Bun`, `createRequire`, `import … from "bun"` and computed `require` included), and an allowlisted service's raw command runner (`defaultRunner` in `claims.ts`) is never imported or exported; no shell command built from request data (`dashboard-no-shell-from-data`, ADR-0007) | dependency-cruiser, ast-grep, findings ratchet |

Bash rules cover `scripts/**/*.sh`, `scripts/sw`, `.claude/hooks`, `claude-code/hooks`,
`completions/*.bash` and `install.sh`.

**Ratchets.** Existing violations of F9–F12 are counted per rule and file in
[`findings-baseline.json`](../tools/arch/findings-baseline.json) by
[`ast-scan.ts`](../tools/arch/ast-scan.ts), which runs every ast-grep rule over the files git knows
(never a directory walk). Counts may only go down: a new file or a higher count fails, and so does a
count that dropped without tightening the baseline. A rule that reaches zero keeps an empty entry,
which fails the meta-test until the rule is promoted to `severity: error`. In CI,
`--against origin/<base>` also fails when this baseline or `arch-baseline.json` gained an entry or a
count against the merge base, so a baseline cannot be raised in the same PR that adds the debt. A rule
key that the merge-base baseline has and HEAD lacks also fails (a rename or removal would launder its
debt); a rule keeps its key, empty when it reaches zero.

**Meta-checks** ([`meta.test.ts`](../tools/arch/meta.test.ts),
[`depcruise-rules.test.ts`](../tools/arch/depcruise-rules.test.ts)): every ast-grep rule has a rule
test with valid and invalid cases, a message that starts with its family and names a fix, an owner,
a docs anchor here, and `files` that match a tracked file; the rule set, the ratcheted set, every
`files` glob and every allowlist (`ignores`) are pinned; `bun run arch` is exactly the checkers joined by
`&&`, with no operator that can swallow a failure; the SDK runner has exactly one `query` call; no
`ast-grep-ignore` comment exists in any file a rule covers (the rules' `files` globs: `src/`, `dashboard/`,
`tools/` test files, `scripts/`, the Bash hooks and completions, `install.sh`) or in the rule and rule-test
YAML under `tools/arch/`; `docs/` is not scanned; every dependency-cruiser rule
fires on a fixture; `bun run arch` runs every checker. [`CODEOWNERS`](../.github/CODEOWNERS) puts
`tools/arch/`, `sgconfig.yml`, the dependency-cruiser configs, `package.json`, the TS check workflow,
this doc, `dashboard/tsconfig.server.json` and `privilege-guard.ts` under the maintainer's review.

F10 in full (run-scoped writes from Wave 1b; every integration by the end of Wave 2): GitHub side
effects go only through the fenced, idempotent `integrations` adapter, with an `IdempotencyKey` and a
`FenceToken` in the signature. The first method, `ensureIncident`, takes no fence (no lease covers a
system-wide incident; ADR-0007).

Workflows: no `${{ }}` expression of any kind inside a `run:` script or an `actions/github-script`
`script:` body; values go through `env:`. This check is strict, with no baseline. A second check
fails a workflow that pipes, `||`-defaults or discards stderr of `gates check`, `bot-comments.sh`,
`retry-state.sh` or `pipeline-active.sh`, runs `gates check --no-github`, or sets
`continue-on-error` on the safety gates (fail closed, ADR-0007).

Config: [`.dependency-cruiser.cjs`](../.dependency-cruiser.cjs),
[`.dependency-cruiser.dashboard.cjs`](../.dependency-cruiser.dashboard.cjs),
[`sgconfig.yml`](../sgconfig.yml) with [`tools/arch/rules/`](../tools/arch/rules) and
[`tools/arch/utils/`](../tools/arch/utils), [`tools/arch/size-ratchet.ts`](../tools/arch/size-ratchet.ts)
with [`arch-baseline.json`](../tools/arch/arch-baseline.json),
[`tools/arch/workflow-injection.ts`](../tools/arch/workflow-injection.ts),
[`tools/arch/workflow-fail-closed.ts`](../tools/arch/workflow-fail-closed.ts).

## Claude access

All Claude calls go through the `AgentRunner` port, implemented once in
[`src/adapters/agent/`](../src/adapters/agent) on `@anthropic-ai/claude-agent-sdk` (pinned).
`decide<T>` is one-shot, tool-less and schema-validated; `runTask` is agentic with an allowlist of
tools. Untrusted text is passed only as delimited data. The child environment is built from an
allowlist, so `GH_TOKEN` never reaches an agent. See ADR-0003. The bash agent launcher
([`scripts/lib/agent-exec.sh`](../scripts/lib/agent-exec.sh)) uses the same allowlist. Its limits: the
agent runs as the pipeline's own user, so same-user files (`~/.netrc`, gh and git config, keychain
items the user can unlock) and, on Linux, the parent's `/proc/$PPID/environ` stay readable. Real
isolation needs a separate user or a sandbox (the Wave 1c sandbox work, ADR-0006).

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

## Safety controls

Spec §6.2, ADR-0007. Pure policies in `orchestration/domain` (`breaker`, `pause`, `budget`, `flow`,
`intake`) over the ports in `orchestration/ports.ts`; read adapters over `gh` and the bash state
files in `src/adapters/{github,state}`. One composition, `shipwright gates check --retry N`
(pause → breaker → budget → review WIP → fix loop, first closed gate wins, fail closed), is the only
"go" for every dispatch:

| Caller | Where |
|---|---|
| Bash daemon | `scripts/lib/safety-gates.sh` (`safety_gates_ok`): once per poll cycle and per spawn; `patrol_issue_create` runs `intake check` before every auto-filed issue |
| `shipwright-dispatch.yml`, `shipwright-auto-retry.yml` | the composite action `.github/actions/safety-gates`; markers only from bot comments (`scripts/ci/`) |
| Dashboard and fleet workers | fleet token and request guard: [dashboard-exposure.md](dashboard-exposure.md) |

The breaker keeps no state: it folds the last 50 pipeline runs from GitHub Actions on every check,
so every machine and CI agree. Operating them: [safety-runbook.md](safety-runbook.md).

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
- [0007 Safety controls gate every dispatch](adr/0007-safety-controls.md)
- [0008 Fitness functions everywhere, with ratchets for legacy code](adr/0008-fitness-functions-everywhere.md)

Generated reference: [`docs/reference/cli.md`](reference/cli.md) and
[`docs/reference/dependency-graph.md`](reference/dependency-graph.md) (`bun run docs:gen`).
