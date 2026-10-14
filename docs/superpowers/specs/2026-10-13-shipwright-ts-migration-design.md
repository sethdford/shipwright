# Shipwright TypeScript migration — design

- **Status:** Draft for review
- **Date:** 2026-10-13
- **Decision:** Migrate Shipwright from ~120k lines of bash to TypeScript on Bun, incrementally,
  as a modular monolith with Clean Architecture boundaries enforced by tests.

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

1. Preserve every capability (not every script or command name) — old command names remain as aliases.
2. Clean Architecture boundaries and Clean Code rules enforced mechanically (the ArchUnit equivalent).
3. An agent-ready repository: short instructions, path-scoped rules, one definition-of-done command,
   generated reference docs, machine-readable migration progress.
4. Typed, validated, budgeted Claude calls through the Claude Agent SDK; no `claude -p` text parsing.
5. Safety by construction: global circuit breaker, error fingerprinting, issue-flood caps, budget guard,
   hermetic tests.

**Non-goals**

- Supporting users without Bun. Shipwright is used by its maintainer and its own CI; breaking changes
  are acceptable. (A `bun build --compile` binary is produced in the last wave for Homebrew.)
- A big-bang rewrite, or new features during migration beyond the safety items in §6.
- A direct Anthropic API adapter (deferred; see §5).

## 3. Architecture

### 3.1 Bounded contexts

The ~110 subcommands are rationalized into 10 contexts. Overlapping implementations merge; old names
are registered as CLI aliases.

| Context | Capabilities from today's commands |
|---|---|
| `delivery` | pipeline, loop, stages, worktree, checkpoint, durable |
| `orchestration` | daemon, fleet, dispatch, scale, remote, launchd |
| `planning` | triage, decompose, strategic, pm |
| `quality` | code-review, adversarial, security-audit, testgen, quality, oversight, evidence, architecture |
| `learning` | memory, discovery, guild, self-optimize, adaptive, rl / bandit / policy |
| `intelligence` | intelligence, predict, model-router, cost |
| `integrations` | github-*, tracker, jira, linear, webhook, ci, pr |
| `observability` | status, dora, vitals, logs, ps, activity, stream, replay, trace, otel, widgets, dashboard API |
| `teams` | session, team-stages, swarm, recruit, standup, tmux, reaper |
| `platform` | doctor, setup, init, prep, upgrade, cleanup, hygiene, docs, release |

The authoritative command → context mapping lives in `docs/plans/port/progress.json` (§7.3); this table
is the summary.

### 3.2 Layers

```
src/
  contexts/<ctx>/
    domain/        Pure TypeScript: entities, state machines, policies, scoring. No I/O.
    application/   Use cases. Depend on domain and on this context's ports only.
    ports.ts       Interfaces the context needs (IssueTracker, AgentRunner, Terminal, Store, Clock, …).
    index.ts       The context's public API. Other contexts import only this file.
  adapters/        The only code that touches the outside world: gh/Octokit, git, Agent SDK, tmux,
                   bun:sqlite, filesystem, clock, environment.
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
| F5 | `Bun.spawn`, `Bun.$`, `fetch`, `process.env` and `node:fs` appear only under `adapters/**` and `main.ts`. |
| F6 | `@anthropic-ai/claude-agent-sdk` is imported only by `adapters/agent/**`, and every call passes an output schema or a typed task spec. |
| F7 | Size budgets: files ≤ 300 lines, functions ≤ 40 lines. Existing violations are baselined in `arch-baseline.json` and may only decrease (ratchet). |
| F8 | Tests never resolve real user paths: adapters receive `HOME`, state directory and tmux socket from `TestEnv`. |

Workflow files get one extra rule: no `${{ … }}` expression that reads issue, PR, comment or step
output text inside a `run:` block (values go through `env:`).

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
| `bun run check:fast` | typecheck + fitness rules + tests for changed contexts | < 10 s |

The same commands run in CI. A change is done when `bun run check` passes.

### 4.3 Claude Code project setup

- **Subagents** (with frontmatter): `reviewer` (read-only; checks a diff against the fitness rules and
  the spec), `verifier` (runs `check`, tries to break the change, returns PASS/FAIL with evidence),
  `porter` (ports one bash command into its context until its parity suite passes).
- **Skills:** `add-command`, `add-adapter`, `port-bash-command`, `write-adr`.
- **Hooks:** Biome format after edits; a Stop hook runs `check:fast` and blocks completion while it fails.
- The six existing agent files in `.claude/agents/` (which have no frontmatter and never load) are
  replaced by the subagents above.

### 4.4 Documentation

```
docs/
  architecture.md       Context map, layer rules, delivery-loop data flow.
  adr/NNNN-*.md          Decisions. First four: TypeScript/Bun; modular monolith; Agent SDK; parity strategy.
  reference/cli.md       Generated from command metadata in cli/. Never hand-edited.
  reference/config.md    Generated from the zod config schema.
  guides/                Quickstart, operating the daemon, writing a pipeline template.
  plans/                 In-flight multi-session work (see §7.3).
```

Generated references replace the `AUTO:` section-sync machinery and its "docs: auto-sync" commits.

## 5. Agent runtime

All Claude access goes through one `AgentRunner` port (rule F6) with two operations:

| Operation | Used by | Implementation | Defaults |
|---|---|---|---|
| `runTask(spec)` — agentic, with tools and files | build loop, review, testgen, fix | Agent SDK `query()` running the Claude Code harness in the run's worktree | Model `claude-opus-5-5`; effort per stage (build/review `xhigh`, plan/design `high`, mechanical stages `low`), always set explicitly because Opus 5.5 defaults to `medium`; per-stage tool allowlist; `cwd` = worktree; max turns; wall-clock timeout; per-run dollar cap; `AbortSignal` wired to SIGINT and the circuit breaker. |
| `decide<T>(schema, input)` — one-shot, typed | triage, risk scoring, commit quality, patrol dedup | Agent SDK with no tools and a JSON-schema output | Model `claude-haiku-5-5`, effort `low`; escalate to `claude-sonnet-5-5` when the result's confidence is below threshold. |

Rules for every call:

1. Untrusted text (issue and PR bodies, comments) is passed as data in the user turn — never in the
   system prompt, never through a shell.
2. Outputs are validated with zod. Refusals, `max_tokens` truncation and schema failures become typed
   results the caller must handle; there is no "empty string means reject" path.
3. Each call appends one row to the run ledger: model, tokens, cost, latency, outcome. `cost`, `dora`
   and the evals read from it.

**Credentials.** CI has only `CLAUDE_CODE_OAUTH_TOKEN`; routing both operations through the Agent SDK
keeps that single credential. `agentEnv` also passes ANTHROPIC_API_KEY when set (local API-key users); CI provides only CLAUDE_CODE_OAUTH_TOKEN. A direct Messages API adapter (cheaper batch triage) would need
`ANTHROPIC_API_KEY` and is deferred.

**Verification item.** Exact Agent SDK option names (structured output, budget, permission and hook
options) are confirmed against the SDK documentation in Wave 0 before the adapter is written.

## 6. Delivery loop and safety

### 6.1 State machine and storage

- Stages and transitions are data in `delivery/domain`. A pipeline template is a list of stages; gates
  are transition guards.
- One `bun:sqlite` database with versioned migrations holds runs, stages, events, memory and costs. It
  replaces `pipeline-state.md`, the scattered JSON files and `events.jsonl` (a one-time importer reads
  the old files).
- Every step is idempotent. A checkpoint is a git commit plus a state row; `resume` loads the run and
  re-enters its current stage.

### 6.2 Safety controls

| Control | Behavior | Addresses |
|---|---|---|
| Global circuit breaker | Opens when at least 5 of the last 8 completed runs (across all issues) failed. While open, dispatch stops and one incident issue is opened (or updated). After a 30-minute cool-down one probe run is allowed (half-open); success closes the breaker, failure re-opens it. Thresholds are config values. | The 2026-10-13 199-failure loop |
| Error fingerprinting | Failures are normalized into fingerprints; an identical fingerprint is not retried; backoff depends on the error class (environment, code, flaky). | Issues #8438, #8524, #8155 |
| Patrol hygiene | Proposals are fingerprinted against open issues and deduplicated; open auto-filed issues are capped (default 25). | ~721 open auto-patrol issues |
| Budget guard | The daily dollar cap is checked before dispatch, not after spending. | Unbounded spend during failure loops |
| Kill switch | A `shipwright:pause` label or a pause file stops dispatch immediately. | Today, stopping the system means disabling workflows by hand |

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

### 7.3 Progress tracking

`docs/plans/port/progress.json` lists every capability with its context, its old command names, its
parity suite, and a status: `bash` → `porting` → `parity-green` → `bash-deleted`. CI checks that the
router points at TypeScript only for `parity-green` or later entries. Agents choose their next item from
this file.

### 7.4 Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| 0 | Foundation: Bun project layout, `check` commands, fitness rules, `TestEnv`, core adapters (config, store, events, gh, git, tmux, agent), AGENTS.md / rules / subagents / skills, ADRs 1–4, progress.json, parity harness in CI | `bun run check` green in CI; one trivial command (`hello`) ported end to end |
| 1 | Delivery loop: loop, pipeline + stages, triage, daemon / dispatch, memory, cost, plus all §6 safety controls | Shipwright's own CI pipeline runs on TypeScript with the breaker on; dispatch / watchdog / auto-retry re-enabled |
| 2 | Integrations: GitHub modules, trackers, CI, PR lifecycle | Parity green |
| 3 | Observability: status, dora, vitals, logs, …; dashboard server reads the SQLite store | Parity green |
| 4 | Remaining commands, parallelized across `porter` agents | All entries `parity-green` |
| 5 | Delete bash scripts, remove the router shim, `bun build --compile` single binary, Homebrew formula | No `.sh` under `scripts/` except installers |

## 8. Testing

| Layer | What | Speed |
|---|---|---|
| Domain unit | Pure functions and state machines with `bun test` | Majority of tests; milliseconds |
| Application | Use cases with in-memory fakes (`FakeTracker`, scripted `FakeAgentRunner`, `FakeTerminal`) | Fast |
| Adapter contract | One spec run against the fake and the real adapter, so fakes cannot drift | Real side runs nightly or on adapter changes |
| Parity | Old bash suites against ported commands (§7.2) | Per ported command |
| Prompt evals | Golden set of ~30 real issues for triage and patrol dedup, scored pass^k | Nightly and on prompt changes |

Every test runs inside `TestEnv`: a temporary `HOME`, state database and tmux socket (rule F8).

## 9. Risks

| Risk | Mitigation |
|---|---|
| Long hybrid period with two implementations | Router flip is per command and reversible; progress.json makes status visible; waves ordered by value. |
| Parity suites encode bugs | A suite that asserts buggy behavior is fixed first in bash (with a note), then used as the oracle. |
| Agent SDK API differs from the assumed options | Wave 0 verification item; the `AgentRunner` port isolates the rest of the code from SDK changes. |
| Rationalization loses a little-used behavior | Aliases keep every old command name; capability entries in progress.json list each old command's flags. |
| Migration stalls after Wave 1 | Waves 2–4 are mechanical and parallel; the `porter` subagent and skill exist to make them cheap. |

## 10. Prerequisites (outside this spec)

- PR #8531 (workflow expression-injection fix) merged.
- `fix/hermetic-tests` branch (private tmux server for tests, jq wrapper) merged.
- The 2026-10-13 bug audit completed; its confirmed bugs become Wave 0/1 regression tests.
