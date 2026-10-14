# Shipwright TypeScript migration — design

- **Status:** Draft for review (revised 2026-10-14)
- **Date:** 2026-10-13
- **Decision:** Migrate Shipwright from ~120k lines of bash to TypeScript on Bun, incrementally,
  as a modular monolith with Clean Architecture boundaries enforced by tests.

## Revision 2026-10-14

The maintainer approved all 12 decisions in the 2027 strategy research. This revision applies them:

- **Deployment modes (goal 6).** Three first-class modes from one codebase: M1 local (zero-ops),
  M2 server, M3 multi-machine.
- **Durability contract (§6.1).** A run journal, a claimable queue with leases and fencing tokens,
  durable signals and a side-effect ledger, all behind ports. Adapters: SQLite for M1, Postgres for
  M2/M3. There is no external workflow engine; Temporal and DBOS are escape hatches with explicit
  triggers (§9). Recorded in ADR-0005 (§4.4).
- **Claims (§6.1).** Lease-and-fence claims replace label claims. The `claimed:<machine>` label
  becomes a display mirror.
- **Credentials and permissions (§5, F9, F10).** Credentials leave the agent's environment. Agents
  run with least privilege inside a sandbox. GitHub side effects go only through a fenced,
  idempotent adapter.
- **Verification (§6.3, §8).** One independent evaluator, holdout checks and a plan critic replace
  five self-graded reviewers. Delivery evals and an operational scorecard become the Wave 1 exit
  criterion.
- **Safety controls (§6.2).** Durable approval gates replace headless auto-approve. Also added: a
  review-WIP limit, a fix-loop cap, per-call budgets, and safety controls that read the shared
  journal.
- **Scope (§3.1, §7.5).** An approved don't-port list, and a keep-and-rebuild list for the
  multi-machine features.
- **Prerequisites (§10).** Two security fixes from this week are Wave 0 prerequisites: PR #8533 and
  the dashboard `/api/claim` hotfix. Dashboard hardening is a Wave 1 item.
- **Waves (§7.4).** The wave plan reflects all of the above. Wave 0 gains only ADR-0005, the port
  types and a contract suite.

Research, in `~/.claude/research_notes/shipwright-sota-2027/`:
- `00-synthesis.md`: the decisions;
- `01-temporal-and-durability.md`: only §0 applies;
- `02-competitive-gap-analysis.md`;
- `03-sota-2027.md`.

## 1. Why

Shipwright's recurring failures are characteristic of large bash codebases, not of any one feature:

- **Injection by interpolation.** On 2026-10-13 every pipeline run failed (199/199 in 24h) because
  issue titles were interpolated into workflow shell scripts; the same pattern let model output reach
  a shell. Bash has no data/code boundary.
- **Non-hermetic tests.** Suites drive the developer's live tmux server and write to the real
  `~/.shipwright`, which crashed an interactive session and polluted `events.jsonl`.
- **No enforced structure.** 283 scripts, ~110 subcommands, overlapping "intelligence" modules, state
  spread across Markdown, JSON and JSONL files, and a 1,229-line agent instruction file.
- **Autonomy without feedback.** Per-issue retry caps did not stop a global failure loop, and patrol
  filed ~721 open issues, many near-duplicates.

## 2. Goals and non-goals

**Goals**

1. Preserve every capability except those on the approved don't-port list (§7.5). This means
   capabilities, not every script or command name. Old command names remain as aliases, or as
   "removed" stubs that name the replacement.
2. Clean Architecture boundaries and Clean Code rules enforced mechanically (the ArchUnit equivalent).
3. An agent-ready repository: short instructions, path-scoped rules, one definition-of-done command,
   generated reference docs, machine-readable migration progress.
4. Typed, validated, budgeted Claude calls through the Claude Agent SDK; no `claude -p` text parsing.
5. Safety by construction: global circuit breaker, error fingerprinting, issue-flood caps, budget guard,
   hermetic tests.
6. Three first-class deployment modes from one codebase. The mode is configuration, not a fork.
   - **M1 local:** zero-ops, embedded SQLite.
   - **M2 server:** a long-running daemon and dashboard.
   - **M3 multi-machine:** pull workers on several machines and one shared Postgres.

**Non-goals**

- Supporting users without Bun. Shipwright is used by its maintainer and its own CI; breaking changes
  are acceptable. (A `bun build --compile` binary is produced in the last wave for Homebrew.)
- A big-bang rewrite. Also no new features during migration, except three: the safety items in §6.2,
  the durability contract (§6.1) and the evaluator (§6.3).
- A dependency on an external workflow engine. Temporal, DBOS and Restate are escape hatches at the
  adapter level, with explicit triggers (§9).
- A direct Anthropic API adapter (deferred; see §5).

## 3. Architecture

### 3.1 Bounded contexts

The ~110 subcommands are rationalized into 10 contexts. Overlapping implementations merge; old names
are registered as CLI aliases. Names in *italics* are not ported (§7.5) and survive only as aliases
or "removed" stubs.

| Context | Capabilities from today's commands |
|---|---|
| `delivery` | pipeline, loop, stages, worktree; *checkpoint, durable* are replaced by the durability contract (§6.1) |
| `orchestration` | daemon, fleet, dispatch, remote, connect, launchd, all rebuilt on `WorkQueue` and `RunJournal`; *scale* |
| `planning` | triage, decompose (in-run feature DAG; it no longer files GitHub issues); *strategic, pm* |
| `quality` | the evaluator (§6.3), holdout checks, testgen, evidence, architecture; code-review, adversarial, security-audit, quality and oversight become aliases of the evaluator |
| `learning` | memory, discovery, one gated optimizer (Wave 4); *guild, self-optimize, adaptive, rl / bandit / policy* |
| `intelligence` | cost, and model-router as a static per-stage model and effort table retuned by delivery evals; *intelligence, predict* |
| `integrations` | github-*, tracker (thin intake port), webhook, ci, pr; *jira, linear* sync |
| `observability` | status, dora, vitals, logs, ps, activity, stream, replay, trace, otel, dashboard (over the journal); *widgets* |
| `teams` | session, team-stages, tmux (a viewer only), reaper; *swarm, recruit, standup* |
| `platform` | doctor, setup, init, prep, upgrade, cleanup, hygiene, release; docs becomes generated references (§4.4) |

The authoritative command → context mapping lives in `docs/plans/port/progress.json` (§7.3); this table
is the summary.

### 3.2 Layers

```
src/
  shared/kernel/   Pure types and helpers shared by every context: Result, shared ports, and the
                   durability ports (§6.1).
  contexts/<ctx>/
    domain/        Pure TypeScript: entities, state machines, policies, scoring. No I/O.
    application/   Use cases. Depend on domain and on this context's ports only.
    ports.ts       Interfaces the context needs (IssueTracker, AgentRunner, Terminal, Store, Clock, …).
    index.ts       The context's public API. Other contexts import only this file.
  adapters/        The only code that touches the outside world: gh/Octokit, git, Agent SDK, tmux,
                   bun:sqlite, Postgres, filesystem, clock, environment.
  cli/             Thin commands: parse args → call one use case → render output. Aliases registered here.
  main.ts          Composition root: builds adapters and wires them into use cases.
```

### 3.3 Fitness rules (enforced in `bun run check`)

Implemented with `dependency-cruiser` for import rules and `ast-grep` for code-shape rules. Each failure
message names the rule and how to fix it.

| # | Rule |
|---|---|
| F1 | `contexts/*/domain/**` imports only from its own `domain/`. |
| F2 | `contexts/*/application/**` never imports `adapters/**` or `cli/**`. |
| F3 | A context imports another context only through `contexts/<other>/index.ts`. |
| F4 | No import cycles. |
| F5 | I/O (`Bun.spawn`, `Bun.$` and every other runtime `Bun` member, `fetch`, `process.env`, and imports of `bun`, `bun:sqlite`, `node:fs`, `node:process`, `child_process` and network modules) appears only under `adapters/**`, `main.ts`, `cli.ts`, `testing/**` and tests. |
| F6 | `@anthropic-ai/claude-agent-sdk` is imported only by `adapters/agent/**`, and every call passes an output schema or a typed task spec. |
| F7 | Size budgets: files ≤ 300 lines, functions ≤ 40 lines. Existing violations are baselined in `arch-baseline.json` and may only decrease (ratchet). |
| F8 | Tests never resolve real user paths: adapters receive `HOME`, state directory and tmux socket from `TestEnv`. |
| F9 | Agents get no GitHub token and no permission bypass (see below). *Enforced from Wave 1.* |
| F10 | GitHub side effects go only through a fenced, idempotent adapter (see below). *Enforced from Wave 1 for the first GitHub-writing port method; covers every integration by the end of Wave 2.* |

**F9: no GitHub token and no permission bypass for agents.**
- *What:* `adapters/agent/**` builds the agent's environment from an explicit allowlist and never
  forwards `GH_TOKEN` or `GITHUB_TOKEN`. Every `runTask` passes a per-stage `allowedTools` list.
- *Banned:* `bypassPermissions`, `allowDangerouslySkipPermissions` and
  `--dangerously-skip-permissions`, anywhere in `src/` and in workflow files.
- *How:*
  - an ast-grep rule over `src/**` and `.github/workflows/**`, which bans those names and the token
    names under `adapters/agent/**`;
  - the `agentEnv` unit test, which asserts that tokens are dropped.
- *Status:* the Wave 0 runner already uses an allowlist and `permissionMode: "dontAsk"`.

**F10: GitHub side effects only through a fenced, idempotent adapter.**
- *What:* every `integrations` port method that causes a GitHub side effect (push, PR, comment,
  label, merge) takes an `IdempotencyKey` and a `FenceToken` in its signature. Write calls through
  `gh` or Octokit appear only in `adapters/github/**`.
- *How:* an ast-grep rule on the port interfaces checks the signatures at the type level. F5 already
  confines process and network I/O to adapters.
- *Status:* enforced from the first GitHub-writing port method (Wave 1). It covers every integration
  by the end of Wave 2.

Workflow files get one extra rule: no `${{ … }}` expression that reads issue, PR, comment or step
output text inside a `run:` block (values go through `env:`). Until the dashboard is ported (Wave 3),
`dashboard/**` gets a matching interim rule: no `execSync`, `spawn` with a shell or `Bun.$` built from
request data. That rule lands with the dashboard hardening item (Wave 1).

### 3.4 Clean Code baseline

- TypeScript `strict` plus `noUncheckedIndexedAccess`.
- Biome for lint and format.
- `zod` schemas at every boundary: config, persisted state, GitHub payloads, model outputs.
- Expected failures are returned as typed results; exceptions are reserved for bugs.

## 4. Agent-ready repository

### 4.1 Instruction files

| File | Content |
|---|---|
| `AGENTS.md` | ≤ 150 lines; canonical, cross-tool. What Shipwright is, the 10 contexts, layer rules in one paragraph, the `check` commands, and links into `docs/`. |
| `CLAUDE.md` | `@AGENTS.md`, plus Claude-specific notes only if needed. Replaces today's 1,229-line file. |
| `.claude/rules/*.md` | Path-scoped and loaded only when relevant: `domain.md`, `adapters.md`, `cli.md`, `tests.md`, `workflows.md`. |

### 4.2 Definition of done

| Command | Runs | Time budget |
|---|---|---|
| `bun run check` | typecheck → Biome → fitness rules → unit + application tests → parity suites for ported commands | < 60 s |
| `bun run check:fast` | typecheck + fitness rules + all TypeScript tests (`src`, `tools`) | ~10–25 s today |

`check:fast` runs every TypeScript test for now. Selecting only the tests for changed contexts is a
later optimization, once the suite outgrows the budget.

The same commands run in CI. A change is done when `bun run check` passes.

### 4.3 Claude Code project setup

- **Subagents** (with frontmatter): `reviewer` (read-only; checks a diff against the fitness rules and
  the spec), `verifier` (runs `check`, tries to break the change, returns PASS/FAIL with evidence),
  `porter` (ports one bash command into its context until its parity suite passes).
- **Skills:** `add-command`, `add-adapter`, `port-bash-command`, `write-adr`.
- **Hooks:** Biome format after edits; a Stop hook runs `check:fast` and blocks completion while it fails.
- Of the six existing agent files in `.claude/agents/` (which have no frontmatter and never load),
  five were removed and replaced by the subagents above. `doc-fleet-agent.md` is kept because
  `scripts/sw-doc-fleet.sh` reads it; doc-fleet is on the don't-port list (§7.5), so the file goes
  when that script does.

### 4.4 Documentation

```
docs/
  architecture.md       Context map, layer rules, deployment modes, delivery-loop data flow.
  adr/NNNN-*.md          Decisions. 0001 TypeScript/Bun; 0002 modular monolith; 0003 Agent SDK;
                         0004 parity strategy; 0005 durability contract and deployment modes (Wave 0);
                         0006 credentials and capability separation (Wave 1).
  reference/cli.md       Generated from command metadata in cli/. Never hand-edited.
  reference/config.md    Generated from the zod config schema (Wave 1, with the config adapter).
  guides/                Quickstart, operating the daemon, writing a pipeline template, running M2/M3.
  plans/                 In-flight multi-session work (see §7.3).
```

Generated references replace the `AUTO:` section-sync machinery and its "docs: auto-sync" commits.

ADR-0005 records:
- the durability contract (§6.1) and the three modes;
- why no engine is adopted now;
- the triggers that would revisit that choice (§9).

A harness ablation on each model release is recorded as a new ADR. It asks whether the evaluator,
holdout checks and plan critic are still load-bearing.

## 5. Agent runtime

All Claude access goes through one `AgentRunner` port (rule F6) with two operations:

| Operation | Used by | Implementation | Defaults |
|---|---|---|---|
| `runTask(spec)` — agentic, with tools and files | build loop, evaluator, testgen, fix | Agent SDK `query()` running the Claude Code harness in the run's worktree | Model `claude-opus-5-5`; effort per stage (build/evaluate `xhigh`, plan/design `high`, mechanical stages `low`), always set explicitly because Opus 5.5 defaults to `medium`; `permissionMode: "dontAsk"` with a per-stage tool allowlist; `cwd` = worktree; `maxTurns`; wall-clock timeout; `maxBudgetUsd`; `AbortSignal` wired to SIGINT and the circuit breaker. |
| `decide<T>(schema, input)` — one-shot, typed | triage, risk scoring, commit quality, patrol dedup, plan critic | Agent SDK with no tools and a JSON-schema output | Model `claude-haiku-5-5`, effort `low`; escalate to `claude-sonnet-5-5` when the result's confidence is below threshold. |

Rules for every call:

1. Untrusted text (issue and PR bodies, comments) is passed as data in the user turn — never in the
   system prompt, never through a shell.
2. Outputs are validated with zod. Refusals, `max_tokens` truncation and schema failures become typed
   results the caller must handle; there is no "empty string means reject" path.
3. Each call appends one row to the run ledger: model, tokens, cost, latency, outcome. `cost`, `dora`
   and the evals read from it.
4. Every call sets `maxBudgetUsd` and `maxTurns`. There is no unbounded call.

**Untrusted-text stages.** Intake, triage, external-PR review and patrol read text that anyone can
write.
- They run with no write tools, no shell, no secrets and no egress, and emit only typed `decide<T>`
  output.
- A denied tool call is reported and the run continues. After 3 consecutive or 20 total denials, the
  run escalates.

**Credentials.** The agent's environment holds only what the model client needs.
- The model credential (`CLAUDE_CODE_OAUTH_TOKEN` in CI, or `ANTHROPIC_API_KEY` for local API-key
  users) is confined to the runner and orchestrator process. Tool subprocesses get a scrubbed
  environment.
- `GH_TOKEN` never enters the agent's environment (F9). The orchestrator's `integrations` adapter
  holds it, and it alone pushes, opens PRs, comments and labels, after gates pass and under the
  fence (F10).
- The bot identity is a GitHub App that cannot merge to `main`.
- A secret scan (gitleaks or trufflehog) gates every PR.
- M3 workers authenticate with per-worker enrollment credentials (§7.5).
- A direct Messages API adapter (cheaper batch triage) would need `ANTHROPIC_API_KEY` and is deferred.
- Details are recorded in ADR-0006 (Wave 1).

**Permissions and sandbox.**
- Runs use `permissionMode: "dontAsk"` with a per-stage `allowedTools` list. Plan, design, evaluate
  and triage are read-only stages.
- `bypassPermissions` is never used (F9).
- Tools run in the SDK's OS sandbox (Seatbelt or bubblewrap) on M1, and in a container on M2/M3
  workers and in CI. Egress is denied by default, with an allowlist.
- A `PreToolUse` denylist also denies edits to test and holdout paths during `build`.

**Runner placement.**
- Every mode runs the Agent SDK locally on the worker, which is the default `AgentRunner`.
- Claude Code cloud sessions and Managed Agents are optional runner adapters for M2/M3 execution
  only. They never replace Shipwright's orchestration, gates or multi-machine coordination.

**Verification items.**
- *Wave 0:* exact Agent SDK option names (structured output, budget, permission and hook options) are
  confirmed against the SDK documentation before the adapter is written.
- *Wave 1:* `runTask` loads `settingSources: ["project"]` (the Wave 0 runner), so a target repo's
  hooks and permissions run with the model token in the environment. That must change (no project
  settings, or the scrubbed sandbox below) before any untrusted-text or external-PR stage uses
  `runTask`.
- *Wave 1:* confirm `sessionStore`, `resume`, `'defer'` and token isolation.
  - *Open item:* can the SDK authenticate without exposing the model token to the agent's Bash
    subprocesses?
  - *Fallback if not:* one container per run, with the token only in the runner process and the
    sandbox environment scrubbed. `GH_TOKEN` is removed either way.

## 6. Delivery loop and safety

### 6.1 State machine and durability

- Stages and transitions are data in `delivery/domain`. A pipeline template is a list of stages; gates
  are transition guards.
- The domain is a pure `decide(state, event) → Command`, interpreted by the orchestrator. Any engine
  could interpret it, which keeps a Temporal adapter a realistic escape hatch.
  - Each run pins `template_version` and `domain_version`.
  - Old reducers stay until their in-flight runs drain.
- **Durability ports** (types in `src/shared/kernel/durability.ts`; one store implements all four, so
  a fence check and its write share a transaction):

| Port | Contract |
|---|---|
| `WorkQueue` | `enqueue` (run, dedupe key, `notBefore`, pool), atomic `claim` returning a lease with a fence token, `heartbeat`, `complete`, `outcome`. `notBefore` is the timer wake. Per-pool concurrency (`maxActive`) is checked inside the claim transaction. A run has at most one unfinished item. `succeeded` and `failed` are both terminal; retries are new items. |
| `RunJournal` | Append-only per-run entries; every append checks the fence and writes to the fence's own run |
| `Signals` | Durable, exactly-once delivery: approvals, cancel, pause |
| `SideEffects` | Reconcile-then-act ledger keyed by `IdempotencyKey`, written under the fence |

- **Fencing.** Each successful claim increments the item's `lease_epoch`, which acts as the fence.
  - A write carrying a stale fence fails with `stale_fence`. A laptop that wakes after another
    machine took over can no longer append, push or comment.
  - Git pushes go to per-attempt branches or use `--force-with-lease`.
- **Adapters.** Both pass one contract suite (§8):

| Adapter | Modes | Mechanism | Wave |
|---|---|---|---|
| `adapters/durability/sqlite` | M1 | `bun:sqlite`, `BEGIN IMMEDIATE`, lease rows, `wake_at` timers | 1 |
| `adapters/durability/postgres` | M2, M3 | `FOR UPDATE SKIP LOCKED`, `LISTEN/NOTIFY`, `lease_epoch` fence; pg-boss optional underneath | 2 |

- **Deployment modes.** M1 needs no service. M2 and M3 need one Postgres instance, managed or
  self-hosted, reached over TLS or Tailscale.
  - M3 workers *pull* work over outbound connections only, so they work behind NAT.
  - Worker health is lease liveness, not an SSH probe.
- **Storage.** The same store holds runs, stages, the journal, memory and costs. It replaces
  `pipeline-state.md`, the scattered JSON files and `events.jsonl` (a one-time importer reads the old
  files). The Wave 0 `EventLog` port is transitional: its synchronous API cannot run on Postgres,
  so `RunJournal` absorbs it in Wave 1 (ADR-0005).
- **Checkpoints.** A checkpoint is a commit pushed to a per-attempt branch plus a journal entry.
  `resume` loads the run and re-enters its current stage.

### 6.2 Safety controls

Controls that count failures or spend read the **shared** journal, so in M3 one machine's failure
loop stops every machine.

| Control | Behavior | Addresses |
|---|---|---|
| Global circuit breaker | Opens when at least 5 of the last 8 completed runs (across all issues and machines) failed. While open, dispatch stops and one incident issue is opened (or updated). After a 30-minute cool-down one probe run is allowed (half-open); success closes the breaker, failure re-opens it. Thresholds are config values. | The 2026-10-13 199-failure loop |
| Error fingerprinting | Failures are normalized into fingerprints; an identical fingerprint is not retried; backoff depends on the error class (environment, code, flaky). A drop in test count is a failing fingerprint. | Issues #8438, #8524, #8155 |
| Patrol hygiene | Proposals are fingerprinted against open issues and deduplicated; open auto-filed issues are capped (default 25). | ~721 open auto-patrol issues |
| Budget guard | The daily dollar cap is checked before dispatch, not after spending; every call also carries `maxBudgetUsd` and `maxTurns` (§5). | Unbounded spend during failure loops |
| Kill switch | A `shipwright:pause` label or a pause flag in the store stops dispatch immediately; every worker checks it at claim time. | Today, stopping the system means disabling workflows by hand |
| Durable approval gates | A gate is `awaitSignal('approve:<stage>')`. The signal comes from the CLI, the authenticated dashboard, or a maintainer's label or `/approve` comment (authorized by author association; the text is not interpreted). A headless run parks; nothing is auto-approved. | Headless auto-approve of gated templates |
| Fix-loop cap | Evaluator gaps return to build at most 3 times, then the run escalates. | Unbounded review/retry loops |
| Review-WIP limit | No new dispatch while more than N agent PRs (default 3–5) await human review. | Review fatigue; review capacity is the bottleneck |
| Dashboard exposure | Binds `127.0.0.1` by default; every mutating route and all M3 worker traffic need a token; CORS is an allowlist, not `*`; no request data reaches a shell. In Wave 2, `/api/claim` is deleted in favor of `WorkQueue.claim`, and the dashboard reads the journal without shelling out. No M2/M3 deployment until this hardening (Wave 1) merges. | Unauthenticated `/api/claim` command injection |

### 6.3 Verification

- **Evaluator.** One `quality.evaluate` use case replaces the five self-graded reviewers.
  - *Inputs:* a fresh context, read-only tools, a rubric (spec criteria plus the code constitution),
    the diff and the running app. It never sees the builder's reasoning.
  - *Output:* zod-typed per-criterion `pass | gap`.
  - *Calibration:* against about 20 human-labelled PRs.
  - *Alternative:* Claude Code Code Review or ultrareview is an optional adapter for PR-level review.
- **Holdout checks.** `spec_generation` writes acceptance checks that are stored outside the
  worktree, which the builder cannot read.
- **Plan critic.** A `decide<T>` critic reviews the plan before build. Builder and evaluator agree on
  a sprint contract (what "done" means for this chunk) before code is written.
- **Run artifacts.** Structured artifacts replace `progress.md` and the restart heuristics:
  - `features.json`, where only the evaluator sets `passes`;
  - `plan.md`;
  - `status.md`.
- **Review brief.** The evaluator writes a review brief on each PR.
- **UI evidence (optional, Waves 3–4).** A `verify-ui` step uses Playwright and attaches the evidence
  to the PR.

## 7. Migration strategy

### 7.1 Strangler via the router

`scripts/sw` keeps dispatching. Porting a command changes one router line from
`exec "$SCRIPT_DIR/sw-x.sh"` to `exec bun "$REPO/src/cli.ts" x`. Reverting is the same one-line change.

### 7.2 Parity

A command's existing bash test suite is its black-box parity oracle: arguments, exit codes, files
written and output. A command's bash script is deleted only after its parity suite passes against the
TypeScript command in CI. Where an old test asserts an implementation detail rather than behavior
(e.g. greps a script's source), the test is rewritten against behavior and the change is noted in the
port's progress entry.

Rebuilt multi-machine commands (§7.5) keep their user-facing behavior. Their transport changes from
SSH and labels to the queue, so suites that assert transport details are rewritten against behavior.

### 7.3 Progress tracking

`docs/plans/port/progress.json` lists every capability with its context, its old command names, its
parity suite, and a status: `bash` → `porting` → `parity-green` → `bash-deleted`. CI checks that the
router points at TypeScript only for `parity-green` or later entries. Agents choose their next item from
this file.

### 7.4 Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| 0 | Foundation: Bun project layout, `check` commands, fitness rules F1–F8, `TestEnv`, core adapters (paths, process, store/events, gh, git, tmux, agent), AGENTS.md / rules / subagents / skills, ADRs 1–5, durability port types and contract suite (fake + SQLite store), progress.json, parity harness in CI | `bun run check` green in CI; one trivial command (`hello`) ported end to end |
| 1 | Delivery loop: loop, pipeline + stages, triage, daemon / dispatch, memory, cost. The zod config adapter and generated `reference/config.md`. Safety controls (§6.2) come first; then the SQLite durability adapter with the `decide()` interpreter, durable approvals, credential scrubbing and sandbox (F9), GitHub writes only through the fenced adapter (F10, enforced from the first GitHub-writing port method), the evaluator, holdout checks and plan critic (§6.3), delivery evals and the scorecard (§8), dashboard hardening, ADR-0006, and an optional 1–2 day Temporal-on-Bun spike | Shipwright's own CI pipeline runs on TypeScript with the breaker on, **and** pass^3 is at least the bash baseline at no more than its cost per merged PR; dispatch / watchdog / auto-retry re-enabled |
| 2 | Integrations: GitHub modules (F10 extended to every integration, reconcile-then-act), trackers (intake only), CI, PR lifecycle. Multi-machine: Postgres adapter live, pull workers with leases and fences, worker enrollment, and `remote` / `fleet` / `connect` rebuilt on `WorkQueue` | Parity green; the contract suite is green on Postgres |
| 3 | Observability: status, dora, vitals, logs, …; one authenticated dashboard over the journal (SQLite or Postgres) replaces fleet-viz and the team dashboard; OTel GenAI span adapter; replay from the journal | Parity green |
| 4 | Remaining commands, parallelized across `porter` agents (skipping the don't-port list); the gated optimizer; `prep` emits agent-ready scaffolding | All entries `parity-green` or on the don't-port list |
| 5 | Delete bash scripts, remove the router shim, `bun build --compile` single binary carrying both durability adapters, Homebrew formula; review the engine triggers (§9) | No `.sh` under `scripts/` except installers; the binary runs M1–M3 by configuration |

Harness ablation (§4.4) recurs on every model release, and components that aren't load-bearing are
removed.

### 7.5 Don't-port and keep-and-rebuild lists

Approved 2026-10-14. Porter agents skip the first list. Old names stay as aliases or "removed" stubs
that point to the replacement.

| Not ported | Replacement |
|---|---|
| recruit, guild, standup, pm, swarm, scale, strategic, developer simulation | One planner, one builder, one evaluator; SDK subagents |
| intelligence, predict, adaptive, self-optimize, rl / bandit / policy learner / reward aggregator, model-router learning | A static per-stage model and effort table, retuned by delivery evals; one gated optimizer (Wave 4) |
| Patrol auto-filing, decompose filing GitHub issues, `autonomous` controller | Capped, deduped proposals (§6.2); an in-run feature DAG |
| code-review, adversarial, oversight, quality, security-audit as separate engines | The evaluator (§6.3) |
| jira, linear, bidirectional tracker sync | Native tracker agent integrations; a thin tracker intake port if used |
| docs AUTO-sync, docs-agent, doc-fleet | Generated references (§4.4) |
| eventbus, durable, file heartbeat, file checkpoint, SSH rebalance, SSH event tail, `machine-health.json` failover, rsync code deploy, `/api/claim` | The durability contract (§6.1); workers pull releases |
| widgets, ux, incident, release-manager, e2e-orchestrator, deps | Dashboard views; the breaker's incident issue; Renovate or Dependabot (`release` and `version` stay) |
| tmux plugin management, the 25 team templates, tmux as the agent runtime, `--max-restarts` and context-exhaustion briefings | A tmux viewer of the journal; SDK compaction plus structured run artifacts |

| Kept and rebuilt | Rebuilt as | Wave |
|---|---|---|
| daemon | A worker loop calling `WorkQueue.claim`, the same in every mode | 1 / 2 |
| fleet, fleet discover, `fix --repos` | Per-pool and per-repo concurrency in the claim transaction; work items enqueued across repos | 2 |
| remote | Worker registry rows and heartbeats in the store; workers pull releases | 2 |
| connect, invite tokens | Authenticated worker enrollment: a join token is exchanged for a per-worker credential | 2 |
| Team dashboard, `dashboard --fleet`, fleet-viz, public-dashboard | One authenticated, localhost-default dashboard over the journal; public view read-only, redacted, opt-in | 3 |
| launchd | Supervisor for the M2 daemon and M3 workers | 2 |
| Breaker, budget guard, kill switch | Read and write the shared journal | 1 / 2 |

## 8. Testing

| Layer | What | Speed |
|---|---|---|
| Domain unit | Pure functions and state machines with `bun test` | Majority of tests; milliseconds |
| Application | Use cases with in-memory fakes (`FakeTracker`, scripted `FakeAgentRunner`, `FakeTerminal`, in-memory durability) | Fast |
| Adapter contract | One spec run against the fake and the real adapter, so fakes cannot drift | Real side runs nightly or on adapter changes |
| Durability contract | Claim atomicity under concurrent claimers, per-pool limits, lease expiry and takeover, stale-fence rejection, run-bound appends, terminal outcomes, idempotent side effects, crash between steps, signal delivery, timer wake (`notBefore`) | In `check`: the fake from Wave 0 (with the existing SQLite store held to its event-log contract), the SQLite adapter from Wave 1. Postgres (container) runs nightly and on adapter changes from Wave 2 |
| Parity | Old bash suites against ported commands (§7.2) | Per ported command |
| Delivery evals | 20–50 past issues with known-good merged diffs, run at k=3. Reported: pass^3, cost per success and a mergeability proxy. Resources are pinned, and 5 transcripts are read per run. Triage and dedup evals are a subset. | Nightly and on prompt, model, effort or harness changes |
| Crash injection | Kill a run between a side effect and its ledger write, then resume; assert exactly one PR | With the durability contract |

**Operational scorecard.** These are computed from the journal:
- merged-without-rework rate;
- cost per merged PR;
- 14-day revert or reopen rate;
- time to PR.

Every model, effort, harness or self-optimization change must hold the delivery evals and the
scorecard. Differences under 3 percentage points are treated as noise.

Every test runs inside `TestEnv`: a temporary `HOME`, state database and tmux socket (rule F8).

## 9. Risks

| Risk | Mitigation |
|---|---|
| Long hybrid period with two implementations | Router flip is per command and reversible; progress.json makes status visible; waves ordered by value. |
| Parity suites encode bugs | A suite that asserts buggy behavior is fixed first in bash (with a note), then used as the oracle. |
| Agent SDK API differs from the assumed options | Wave 0 verification item; the `AgentRunner` port isolates the rest of the code from SDK changes. |
| Rationalization loses a little-used behavior | Aliases keep every old command name; capability entries in progress.json list each old command's flags; §7.5 names every deliberate drop. |
| Migration stalls after Wave 1 | Waves 2–4 are mechanical and parallel; the `porter` subagent and skill exist to make them cheap. |
| Homegrown-engine creep: the journal grows into a half-built Temporal | Keep the ports to steps, signals, timers and leases. Two triggers force an engine evaluation: more than 2 correctness incidents, or more than ~2,000 LOC. |
| Lease or fence bugs in M3 (double PRs, lost work) | The durability contract and crash-injection tests pass on both backends before pipeline code depends on them. Every side effect is reconcile-then-act. |
| Postgres is unreachable from laptops (NAT, TLS) | Pull model; documented managed-Postgres and Tailscale recipes; otherwise the Temporal Cloud trigger below applies. |
| Bun's Postgres client is immature | The driver stays behind the adapter, and the contract suite runs nightly on Postgres. |
| Credential isolation is not achievable through the SDK | Wave 1 verification item (§5), with a container-per-run fallback. |
| Evaluator leniency or reward hacking | Holdout checks the builder can't read; calibration against human-labelled PRs; a drop in test count is a failing fingerprint. |
| Scope pressure delays the urgent safety work | Wave 1 orders the safety controls first. Postgres stays in Wave 2. |
| The dashboard stays exposed between the hotfix and the hardening | Bind to localhost with or right after the hotfix. No M2/M3 deployment until hardened (§6.2). |
| Eval cost and noise | Pinned resources, k=3, 20–50 tasks; differences under 3 points are noise. |
| TypeScript and bash disagree on locations | `resolvePaths` uses tmux socket `shipwright` (`tmux -L`, override `SHIPWRIGHT_TMUX_SOCKET`) and honors `SHIPWRIGHT_STATE_DIR`; bash uses the default tmux server and always `~/.shipwright`. Reconcile both before porting any tmux-touching command (session, ps, fleet) or any command that shares state files with bash; this is a Wave 1 prerequisite for those ports. |

**What would change the engine decision** (ADR-0005; reviewed in Wave 5 and whenever a trigger fires):

- **Temporal (Cloud first).** Adopt it if:
  - M3 grows past ~10 machines or spans organizations;
  - runs need intra-stage sagas or fan-out;
  - the creep thresholds above trip;
  - or Temporal ships GA Bun workers *and* a TypeScript Agent SDK integration.
- **Temporal Cloud as the M3 service in Wave 2** if a Postgres reachable from every machine won't be
  run.
- **DBOS** if its SQLite support merges *and* it runs on Bun.
- **Restate** if it ships a self-hosted pull or outbound-tunnel mode.
- **Managed Agents** as the execution runner if it supports the subscription path and becomes
  ZDR-eligible. The orchestration contract stays either way.

## 10. Prerequisites (outside this spec)

- PR #8531 (workflow expression-injection fix) merged.
- PR #8533 (workflow script-injection fix) merged. *Wave 0 prerequisite.*
- The `fix/dashboard-claim-injection` hotfix merged, with a regression test. It removes request data
  from `execSync` in `/api/claim`. *Wave 0 prerequisite.*
- Dashboard hardening scheduled as a Wave 1 item: default bind `127.0.0.1`, tokens on mutating routes,
  and a CORS allowlist. No server (M2) or multi-machine (M3) deployment until it merges.
- `fix/hermetic-tests` branch (private tmux server for tests, jq wrapper) merged.
- The 2026-10-13 bug audit completed; its confirmed bugs become Wave 0/1 regression tests.
