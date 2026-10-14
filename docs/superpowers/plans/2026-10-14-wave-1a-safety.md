# Wave 1a — Safety Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the spec §6.2 safety controls — global circuit breaker, kill switch, budget guard, issue intake caps, fix-loop cap, review-WIP limit, bot-only retry markers and dashboard hardening — and wire them into the three disabled workflows (`shipwright-dispatch.yml`, `shipwright-watchdog.yml`, `shipwright-auto-retry.yml`) and the bash daemon, so those workflows can be re-enabled before any delivery-loop porting.

**Architecture:** The controls are pure policies in the `orchestration` context (`src/contexts/orchestration/domain`) over ports in `src/contexts/orchestration/ports.ts`, with use cases in `application/` and adapters in `src/adapters` (`gh` through `ProcessRunner` argv; bash-compatible state files). One composition, `shipwright gates check` (pause → breaker → budget → review WIP → fix loop; it stops at the first closed gate and fails closed), is called by the workflows through the composite action `.github/actions/safety-gates` and by the daemon's `daemon_spawn_pipeline`. The breaker is stateless: every check folds the last 50 pipeline runs from GitHub Actions, so every machine and CI agree without shared state, and the Wave 1b SQLite durability adapter can later sit behind the same ports. The one GitHub write, the breaker's incident issue, is the first F10 method (`GithubWriter.ensureIncident(key, report)`), and an ast-grep rule enforces it. ADR-0007 records the thresholds and the composition.

**Tech Stack:** Bun 1.2.19, TypeScript (strict), zod 4, Biome 2, dependency-cruiser, `@ast-grep/cli`, `gh`, bash 3.2 with shellcheck 0.11.0, actionlint, vitest (dashboard).

**Spec:** `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md` §2, §3.3, §5, §6.1, §6.2, §7.4, §9, §10 · research decisions 9–11 (`~/.claude/research_notes/shipwright-sota-2027/00-synthesis.md`) · the Wave 0 plan `docs/superpowers/plans/2026-10-13-wave-0-foundation.md`.

**Not in 1a (later in Wave 1):** the SQLite durability adapter, the `decide()` interpreter and durable approval gates (1b); credentials, sandbox and ADR-0006 (1c); the evaluator's in-run fix loop (§6.3); porting patrol, dispatch or the daemon.

---

## Decisions this plan takes (recorded in ADR-0007, Task 17)

The maintainer accepted these on 2026-10-14 (breaker 5-of-8 / 30 min with `cancelled` excluded, bot `github-actions[bot]` with the `SHIPWRIGHT_BOT_LOGIN` override, review WIP 5, the fence-less incident method, a 401 for a loopback dashboard with a token, the daemon failing closed without Bun, the CI budget deferred) and added two changes: dispatch skips auto-filed issues, and the watchdog no longer retries.

| Control | Rule | Source of truth in 1a |
|---|---|---|
| Breaker | Opens when at least 5 of the last 8 *finished* runs failed. `failure`, `timed_out` and `startup_failure` count as failures; `cancelled`, `skipped`, `neutral`, `action_required` and `stale` are not counted. After a 30-minute cool-down, one probe is allowed: a run *created* after the cool-down. A probe success closes the breaker and a failure re-opens it. Runs in flight when it opened are ignored. | `gh run list --workflow shipwright-pipeline.yml --limit 50 --json databaseId,status,conclusion,createdAt,updatedAt` (`updatedAt` is the completion time) |
| Incident | While the breaker is open, one open `shipwright:incident` issue: created, or commented on once per trip. The key `breaker:open:<opened-at-ms>` is stored in the issue as `<!-- shipwright-idempotency-key: … -->`. | `gh issue list --label shipwright:incident --json number,body,comments` |
| Kill switch | The daemon's existing flag `~/.shipwright/daemon-pause.flag` (any file pauses; `resume_after` lapses it), or the `shipwright:pause` label on any open issue | the file, and `gh issue list --label shipwright:pause --json number` |
| Budget | Today's spend (UTC) plus the estimate must stay under `daily_budget_usd`. A disabled cap or a cap of 0 is unlimited. In CI the gate is a no-op (runners have no cost files); a CI budget source is deferred to Wave 1b/1c. | `~/.shipwright/budget.json` and `costs.json` (`entries[].cost_usd`, `ts_epoch`), as `scripts/sw-cost.sh` writes them |
| Review WIP | Agent PRs awaiting review plus queued or running pipeline runs must be fewer than 5. An agent PR is open, not a draft, not `APPROVED`, and authored by `app/github-actions` or labelled `shipwright`. | `gh pr list --state open --json number,author,labels,isDraft,reviewDecision` |
| Fix loop | Retry attempts 1–3 pass; the 4th is refused | `--attempt N` from the caller |
| Auto-filed issues | The dispatch workflow and the daemon's selection loop skip every issue labelled `auto-patrol` (`$PATROL_LABEL`). A human opts one in by **removing** that label. `ready-to-build` cannot be the opt-in, because `sw-patrol-meta.sh` and `sw-strategic.sh` add it automatically, and nothing automated removes `auto-patrol`. Bulk-closing the backlog is out of scope. | `gh label list` (read-only, 2026-10-14): `auto-patrol`, `ready-to-build`, `shipwright` exist; no approval label does |
| Retries | Auto-retry is the only retry path. The watchdog cancels stuck runs and comments; it never dispatches. For a run silent over 2 hours it labels `shipwright-stuck` and posts `SHIPWRIGHT-WATCHDOG-ABANDON: <run>` *before* cancelling, and auto-retry skips that run. | bot-authored comments |
| Intake | Patrol files only while fewer than 25 `auto-patrol` issues are open and no open issue has the same title fingerprint (lowercase; each digit run becomes `0`; punctuation becomes a space) | `gh issue list --state open --limit 2000 --json number,title,labels` |
| Bot markers | Workflows read `SHIPWRIGHT-*` markers only from comments whose `user.login` is `github-actions[bot]` **and** whose `user.type` is `Bot`. This uses REST; GraphQL reports the same account as `github-actions`. | `gh api --paginate repos/$GITHUB_REPOSITORY/issues/N/comments` |
| Dashboard | Fleet routes (`/api/claim`, `/api/claim/release`, `/api/connect/*`, `/api/webhook/ci`) need `SHIPWRIGHT_FLEET_TOKEN` (header `X-Shipwright-Token` or `Authorization: Bearer`) or a signed-in session. Without a token configured they work only on loopback. Mutating requests must be `application/json` (except `/auth/*`), and a request that carries `Origin` must come from an allowed origin. CORS echoes only allowed origins: `http://localhost:<port>`, `http://127.0.0.1:<port>` and `SW_DASHBOARD_ORIGINS`. Startup refuses a non-loopback bind with auth `none` or without the token. | environment |

Exit codes for every gate command: `0` allowed; `1` blocked, or a source could not be read (fail closed); `2` usage error. `shipwright paused` is inverted: `0` paused (or unknown), `1` not paused.

## Conventions for every task

- Run commands from the worktree root, `/Users/sethford/Documents/shipwright-wave1`.
- Run `bun run format` before `bun run check`, and **stage new files before `bun run check`**. The parity sandbox (`tools/port/sandbox.ts`) copies only files in the git index, so an unstaged new import makes `parity hello` fail.
- Never run `shipwright breaker check` or `shipwright gates check` against the real repository without `--no-github`: an open breaker writes the incident issue. Tests use `FakeProcessRunner`. No task writes to GitHub.
- Run bash suites only through `bash scripts/sw-test-all.sh --pattern <name>`, and never pipe its output: its watchdog `sleep` holds a pipe open for 300 s.
- Never run these suites locally, because they drive tmux or the full daemon: `sw-lib-daemon-dispatch-test`, `sw-lib-daemon-patrol-test`, `sw-daemon-test`, `sw-lib-daemon-poll-test`, `sw-tmux-*`, or `sw-test-all.sh` without `--pattern`.
- The suites this plan runs are hermetic (mocked `bun`, `gh` and `curl`, a temporary `HOME`, no tmux): `sw-lib-safety-gates-test`, `sw-ci-bot-comments-test`, `sw-lib-daemon-failure-test`, `sw-lib-daemon-state-test` and `sw-connect-test`.
- Run shellcheck exactly as CI does: `shellcheck -x -S warning -e SC2034,SC1090,SC2148,SC2119,SC2120 <files>`.

---

## File map

| Path | Responsibility |
|---|---|
| `src/contexts/orchestration/domain/breaker.ts` | Breaker state machine (closed, open, half-open), its description and the incident text |
| `src/contexts/orchestration/domain/pause.ts` | Kill switch: flag and label → pause status |
| `src/contexts/orchestration/domain/budget.ts` | Daily UTC budget arithmetic, compatible with `sw-cost.sh` |
| `src/contexts/orchestration/domain/flow.ts` | Review-WIP limit and fix-loop cap |
| `src/contexts/orchestration/domain/intake.ts` | Cap on auto-filed issues and title-fingerprint dedupe |
| `src/contexts/orchestration/ports.ts` | `RunHistory`, `PauseFlag`, `PauseLabel`, `CostLedger`, `PullRequests`, `OpenIssues`, `SafetyPorts` |
| `src/contexts/orchestration/application/{breaker,pause,budget,intake,gates}.ts` | Use cases; `gates.ts` is the ADR-0007 composition |
| `src/contexts/orchestration/index.ts` | The context's public API |
| `src/contexts/integrations/{ports,index}.ts` | `GithubWriter` (F10): `ensureIncident(key, report)` |
| `src/adapters/github/gh-json.ts` | Shared read-only `gh … --json` runner (argv, timeout, zod, classified errors) |
| `src/adapters/github/gh-{run-history,pause-label,pull-requests,open-issues}.ts` | Read adapters over `gh` |
| `src/adapters/github/gh-github-writer.ts` | The only file allowed to run `gh` write subcommands |
| `src/adapters/state/{file-pause-flag,json-cost-ledger}.ts` | State files shared with bash in `~/.shipwright` |
| `src/cli/shared.ts`, `src/cli/commands/{breaker,pause,budget,intake,gates}.ts` | The commands `breaker`, `pause`, `resume`, `paused`, `budget`, `intake` and `gates` |
| `src/main.ts` | `buildSafetyPorts(env)`; injects `ctx.safety()` lazily |
| `src/testing/{fake-safety-ports,cli-harness}.ts` | Fakes and the CLI test harness |
| `tools/arch/rules/f10-github-writes-only-in-writer.yml` and its rule test | F10 enforcement |
| `tools/arch/rules/dashboard-no-shell-from-data.yml` and its rule test | The interim dashboard rule (spec §3.3) |
| `scripts/lib/safety-gates.sh`, `scripts/sw-lib-safety-gates-test.sh` | Bash callers: `safety_gates_ok`, `patrol_issue_create`, `fleet_curl` |
| `scripts/lib/daemon-{dispatch,failure,patrol,poll-github,state}.sh`, `scripts/sw-connect.sh` | Minimal wiring of the gates, the auto-patrol skip and the fleet token |
| `scripts/ci/bot-comments.sh`, `scripts/sw-ci-bot-comments-test.sh` | Comments by the bot account only |
| `.github/actions/safety-gates/action.yml` | Composite action: set up Bun, run `gates check`, output `allowed` |
| `.github/workflows/shipwright-{dispatch,watchdog,auto-retry}.yml` | Gated, with bot-only markers |
| `dashboard/services/request-guard.ts` and its test, `dashboard/server.ts`, `dashboard/src/core/api.ts`, `dashboard/tsconfig.server.json` | Dashboard hardening and its typecheck |
| `scripts/sw`, `docs/plans/port/progress.json`, `docs/reference/cli.md` | Router `run_ts` lines, progress entries, generated reference |
| `docs/adr/0007-safety-controls.md`, `AGENTS.md`, `docs/architecture.md`, `.claude/rules/workflows.md` | Decision record and agent guidance |

---

### Task 0: Verify the branch and a green base

**Files:** none

- [ ] **Step 1: Confirm the branch, install, and run the definition of done**

```bash
git status -sb | head -1
bun install --frozen-lockfile
bun run check
```

Expected: `## wave1/safety`; `bun run check` passes and ends with `1/1 parity suites passed`. If it does not, stop and report: the base must be green.

- [ ] **Step 2: Check the Wave 0 PR**

```bash
gh pr view 8535 --json state,headRefName -q '.state + " " + .headRefName'
```

Expected: `OPEN docs/ts-migration-spec` (this branch is cut from it) or `MERGED docs/ts-migration-spec`. If merged, rebase: `git fetch -q origin && git rebase origin/main`, then repeat Step 1.

- [ ] **Step 3: Confirm the linters CI uses**

```bash
shellcheck --version | sed -n 2p
actionlint --version | head -1
```

Expected: `version: 0.11.0` and an actionlint version line. Install with `brew install shellcheck actionlint` if missing.

---

### Task 1: Breaker state machine (domain)

**Files:**
- Create: `src/contexts/orchestration/domain/breaker.ts`
- Test: `src/contexts/orchestration/domain/breaker.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, test } from "bun:test";
import {
  type BreakerPolicy,
  breakerAllowsDispatch,
  breakerIncident,
  describeBreaker,
  evaluateBreaker,
  type RunRecord,
} from "./breaker";

const MIN = 60_000;
const policy: BreakerPolicy = { window: 8, maxFailures: 5, coolDownMs: 30 * MIN };
const done = (id: string, startMin: number, endMin: number, ok: boolean): RunRecord => ({
  id,
  startedAt: startMin * MIN,
  finished: { at: endMin * MIN, outcome: ok ? "success" : "failure" },
});
const active = (id: string, startMin: number): RunRecord => ({
  id,
  startedAt: startMin * MIN,
  finished: null,
});
/** n runs, one per minute from `fromMin`, each lasting one minute. */
const series = (fromMin: number, outcomes: readonly boolean[]): RunRecord[] =>
  outcomes.map((ok, i) => done(`r${fromMin + i}`, fromMin + i, fromMin + i + 1, ok));

describe("evaluateBreaker", () => {
  test("no history is closed and allows dispatch", () => {
    const s = evaluateBreaker([], 0, policy);
    expect(s).toEqual({ kind: "closed", failures: 0, considered: 0 });
    expect(breakerAllowsDispatch(s)).toBe(true);
  });

  test("4 failures in the last 8 stays closed", () => {
    const runs = series(0, [false, true, false, true, false, true, false, true]);
    expect(evaluateBreaker(runs, 100 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 4,
      considered: 8,
    });
  });

  test("only the last `window` runs count", () => {
    const runs = series(0, [
      false,
      false,
      false,
      false,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
    ]);
    expect(evaluateBreaker(runs, 100 * MIN, policy)).toMatchObject({ kind: "closed", failures: 0 });
  });

  test("the 5th failure in 8 opens it; dispatch stops until the cool-down ends", () => {
    const runs = series(0, [false, true, false, false, true, false, false]); // 5th failure ends at 7
    const s = evaluateBreaker(runs, 10 * MIN, policy);
    expect(s).toEqual({ kind: "open", since: 7 * MIN, probeAfter: 37 * MIN });
    expect(breakerAllowsDispatch(s)).toBe(false);
  });

  test("input order does not matter", () => {
    const runs = series(0, [false, false, false, false, false]).reverse();
    expect(evaluateBreaker(runs, 6 * MIN, policy)).toMatchObject({ kind: "open", since: 5 * MIN });
  });

  test("runs already in flight when it opened do not close it", () => {
    const runs = [...series(0, [false, false, false, false, false]), done("late", 4, 20, true)];
    expect(evaluateBreaker(runs, 21 * MIN, policy)).toMatchObject({ kind: "open", since: 5 * MIN });
  });

  test("after the cool-down it is half-open and allows exactly one probe", () => {
    const tripped = series(0, [false, false, false, false, false]); // opens at 5, probe after 35
    const s = evaluateBreaker(tripped, 40 * MIN, policy);
    expect(s).toEqual({ kind: "half_open", since: 5 * MIN, probing: false });
    expect(breakerAllowsDispatch(s)).toBe(true);
  });

  test("a probe in flight blocks further dispatch", () => {
    const runs = [...series(0, [false, false, false, false, false]), active("probe", 36)];
    const s = evaluateBreaker(runs, 40 * MIN, policy);
    expect(s).toEqual({ kind: "half_open", since: 5 * MIN, probing: true });
    expect(breakerAllowsDispatch(s)).toBe(false);
  });

  test("a successful probe closes it with a fresh window", () => {
    const runs = [...series(0, [false, false, false, false, false]), done("probe", 36, 50, true)];
    expect(evaluateBreaker(runs, 51 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 0,
      considered: 0,
    });
  });

  test("a failed probe re-opens it from the probe's end", () => {
    const runs = [...series(0, [false, false, false, false, false]), done("probe", 36, 50, false)];
    expect(evaluateBreaker(runs, 51 * MIN, policy)).toEqual({
      kind: "open",
      since: 50 * MIN,
      probeAfter: 80 * MIN,
    });
  });
});

describe("describeBreaker", () => {
  test("names the state and its times", () => {
    expect(describeBreaker({ kind: "closed", failures: 2, considered: 8 })).toBe(
      "closed (2 of the last 8 runs failed)",
    );
    expect(describeBreaker({ kind: "open", since: 0, probeAfter: 30 * MIN })).toBe(
      "open since 1970-01-01T00:00:00.000Z; probe allowed after 1970-01-01T00:30:00.000Z",
    );
    expect(describeBreaker({ kind: "half_open", since: 0, probing: true })).toBe(
      "half-open since 1970-01-01T00:00:00.000Z; probe run in flight",
    );
    expect(describeBreaker({ kind: "half_open", since: 0, probing: false })).toBe(
      "half-open since 1970-01-01T00:00:00.000Z; one probe run allowed",
    );
  });
});

describe("breakerIncident", () => {
  test("names the trip time and the policy", () => {
    const report = breakerIncident({ kind: "open", since: 0, probeAfter: 30 * MIN }, policy);
    expect(report.title).toBe("Shipwright circuit breaker is open: dispatch stopped");
    expect(report.body).toContain("1970-01-01T00:00:00.000Z");
    expect(report.body).toContain("5 of the last 8");
    expect(report.body).toContain("shipwright:pause");
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
bun test ./src/contexts/orchestration/domain/breaker.test.ts
```

Expected: FAIL — `error: Cannot find module './breaker' from '…/breaker.test.ts'`.

- [ ] **Step 3: Implement `src/contexts/orchestration/domain/breaker.ts`**

The fold walks finished runs in completion order. Closed keeps a sliding window; the 5th failure in 8 opens it at that run's completion time. While open, only a run *created* after the cool-down counts (the probe). At `now`, an open breaker past its cool-down is half-open; it is `probing` while a run created after the cool-down is still queued or running.

```ts
// Global circuit breaker (spec §6.2, ADR-0007). Pure: the state is recomputed from run history on
// every check, so every caller (CI workflows, the daemon, any machine) reaches the same answer.

export type RunOutcome = "success" | "failure";

export interface RunRecord {
  readonly id: string;
  /** Epoch ms when the run was created (queued). */
  readonly startedAt: number;
  /** `null` while the run is queued or in progress. */
  readonly finished: { readonly at: number; readonly outcome: RunOutcome } | null;
}

export interface BreakerPolicy {
  /** How many of the most recent finished runs are considered. */
  readonly window: number;
  /** The breaker opens when at least this many runs in the window failed. */
  readonly maxFailures: number;
  /** Time after opening before one probe run is allowed. */
  readonly coolDownMs: number;
}

export const DEFAULT_BREAKER_POLICY: BreakerPolicy = {
  window: 8,
  maxFailures: 5,
  coolDownMs: 30 * 60 * 1000,
};

export type BreakerState =
  | { readonly kind: "closed"; readonly failures: number; readonly considered: number }
  | { readonly kind: "open"; readonly since: number; readonly probeAfter: number }
  | { readonly kind: "half_open"; readonly since: number; readonly probing: boolean };

type Finished = RunRecord & { readonly finished: NonNullable<RunRecord["finished"]> };
type Fold =
  | { readonly state: "closed"; readonly window: readonly RunOutcome[] }
  | { readonly state: "open"; readonly since: number };

const isFinished = (r: RunRecord): r is Finished => r.finished !== null;
const failuresIn = (window: readonly RunOutcome[]) => window.filter((o) => o === "failure").length;

function step(fold: Fold, run: Finished, policy: BreakerPolicy): Fold {
  if (fold.state === "closed") {
    const window = [...fold.window, run.finished.outcome].slice(-policy.window);
    return failuresIn(window) >= policy.maxFailures
      ? { state: "open", since: run.finished.at }
      : { state: "closed", window };
  }
  // Only a run started after the cool-down is a probe; runs in flight when it opened are ignored.
  if (run.startedAt < fold.since + policy.coolDownMs) return fold;
  return run.finished.outcome === "success"
    ? { state: "closed", window: [] }
    : { state: "open", since: run.finished.at };
}

/** Folds finished runs in completion order, then applies the cool-down at `now`. */
export function evaluateBreaker(
  runs: readonly RunRecord[],
  now: number,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): BreakerState {
  const finished = runs.filter(isFinished).sort((a, b) => a.finished.at - b.finished.at);
  const fold = finished.reduce<Fold>((f, run) => step(f, run, policy), {
    state: "closed",
    window: [],
  });
  if (fold.state === "closed") {
    return { kind: "closed", failures: failuresIn(fold.window), considered: fold.window.length };
  }
  const probeAfter = fold.since + policy.coolDownMs;
  if (now < probeAfter) return { kind: "open", since: fold.since, probeAfter };
  const probing = runs.some((r) => r.finished === null && r.startedAt >= probeAfter);
  return { kind: "half_open", since: fold.since, probing };
}

const iso = (epochMs: number) => new Date(epochMs).toISOString();

export function describeBreaker(state: BreakerState): string {
  if (state.kind === "closed") {
    return `closed (${state.failures} of the last ${state.considered} runs failed)`;
  }
  if (state.kind === "open") {
    return `open since ${iso(state.since)}; probe allowed after ${iso(state.probeAfter)}`;
  }
  const probe = state.probing ? "probe run in flight" : "one probe run allowed";
  return `half-open since ${iso(state.since)}; ${probe}`;
}

export function breakerAllowsDispatch(state: BreakerState): boolean {
  return state.kind === "closed" || (state.kind === "half_open" && !state.probing);
}

/** The incident issue opened (once per trip) when the breaker is open. */
export function breakerIncident(
  state: Extract<BreakerState, { kind: "open" }>,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): { readonly title: string; readonly body: string } {
  const minutes = Math.round(policy.coolDownMs / 60_000);
  return {
    title: "Shipwright circuit breaker is open: dispatch stopped",
    body: [
      `The global circuit breaker opened at ${iso(state.since)}: at least ${policy.maxFailures} of the last ${policy.window} pipeline runs failed.`,
      "",
      `Dispatch, auto-retry and watchdog retries are stopped. After ${minutes} minutes one probe run is allowed; if it succeeds the breaker closes, if it fails the breaker re-opens.`,
      "",
      "To keep everything stopped while you investigate, add the `shipwright:pause` label to any open issue or run `shipwright pause`.",
    ].join("\n"),
  };
}
```

- [ ] **Step 4: Run the tests**

```bash
bun test ./src/contexts/orchestration/domain/breaker.test.ts
```

Expected: `12 pass`, `0 fail`.

- [ ] **Step 5: Run the definition of done**

```bash
bun run format && git add -A src/contexts/orchestration && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 6: Commit**

```bash
git add -A src/contexts/orchestration
git commit -m "feat(orchestration): global circuit breaker state machine"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 2: Run history port and `gh` adapter

**Files:**
- Create: `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts`, `src/adapters/github/gh-json.ts`, `src/adapters/github/gh-run-history.ts`
- Test: `src/adapters/github/gh-json.test.ts`, `src/adapters/github/gh-run-history.test.ts`

`runGhJson` is the one place new read adapters run `gh … --json`: argv only, 30 s timeout, `classifyGhError` from the Wave 0 issue tracker, zod validation. (`GhIssueTracker` keeps its own copy; folding it in is a follow-up, not this wave.)

- [ ] **Step 1: Write the failing test for the shared helper**

```ts
import { expect, test } from "bun:test";
import { z } from "zod";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { runGhJson } from "./gh-json";

const Schema = z.array(z.object({ number: z.number() }));
const gh = (exitCode: number, stdout: string, stderr = "") =>
  new FakeProcessRunner([{ prefix: ["gh"], result: { exitCode, stdout, stderr } }]);

test("parses and validates gh JSON output", async () => {
  const runner = gh(0, '[{"number":1,"extra":true}]');
  expect(await runGhJson(runner, ["gh", "issue", "list"], Schema)).toEqual({
    ok: true,
    value: [{ number: 1 }],
  });
  expect(runner.calls[0]?.timeoutMs).toBe(30_000);
});

test("a gh failure is classified, not thrown", async () => {
  const r = await runGhJson(gh(1, "", "HTTP 502: Bad Gateway"), ["gh", "x"], Schema);
  expect(r).toEqual({ ok: false, error: { kind: "transient", message: "HTTP 502: Bad Gateway" } });
});

test("non-JSON or off-schema output is a failed error", async () => {
  const notJson = await runGhJson(gh(0, "nope"), ["gh", "x"], Schema);
  expect(!notJson.ok && notJson.error.kind).toBe("failed");
  const offSchema = await runGhJson(gh(0, '[{"number":"1"}]'), ["gh", "x"], Schema);
  expect(!offSchema.ok && offSchema.error.message).toMatch(/unexpected gh output/);
});

test("a missing gh binary is a failed error, not a rejection", async () => {
  const r = await runGhJson(new FakeProcessRunner([]), ["gh", "x"], Schema);
  expect(!r.ok && r.error.kind).toBe("failed");
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
bun test ./src/adapters/github/gh-json.test.ts
```

Expected: FAIL — `error: Cannot find module './gh-json' from '…/gh-json.test.ts'`.

- [ ] **Step 3: Implement `src/adapters/github/gh-json.ts`**

```ts
import type { ZodType } from "zod";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-issue-tracker";

/** Runs a read-only `gh … --json` call (argv only) and validates its output with `schema`. */
export async function runGhJson<T>(
  runner: ProcessRunner,
  argv: readonly string[],
  schema: ZodType<T>,
): Promise<Result<T, AdapterError>> {
  const r = await runOrFail(runner, { argv, timeoutMs: 30_000 });
  if (r.exitCode !== 0 || r.timedOut) return err(classifyGhError(r));
  let json: unknown;
  try {
    json = JSON.parse(r.stdout);
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    return err({ kind: "failed", message: `unexpected gh output: ${why}` });
  }
  const parsed = schema.safeParse(json);
  if (!parsed.success) {
    return err({ kind: "failed", message: `unexpected gh output: ${parsed.error.message}` });
  }
  return ok(parsed.data);
}
```

```bash
bun test ./src/adapters/github/gh-json.test.ts
```

Expected: `4 pass`, `0 fail`.

- [ ] **Step 4: Create the port `src/contexts/orchestration/ports.ts`**

```ts
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { RunRecord } from "./domain/breaker";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}
```

- [ ] **Step 5: Create the context's public API `src/contexts/orchestration/index.ts`**

```ts
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export type {
  RunHistory,
} from "./ports";
```

- [ ] **Step 6: Write the failing adapter test**

```ts
import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhRunHistory, toRunRecord } from "./gh-run-history";

const ghRun = (status: string, conclusion: string | null) => ({
  databaseId: 38554676028,
  status,
  conclusion,
  createdAt: "2026-10-14T11:10:10Z",
  updatedAt: "2026-10-14T11:11:36Z",
});

test("lists pipeline runs with argv only and maps them to run records", async () => {
  const stdout = JSON.stringify([ghRun("completed", "failure"), ghRun("in_progress", "")]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh", "run", "list"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  const r = await new GhRunHistory(runner).recentRuns(50);
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "run",
    "list",
    "--workflow",
    "shipwright-pipeline.yml",
    "--limit",
    "50",
    "--json",
    "databaseId,status,conclusion,createdAt,updatedAt",
  ]);
  expect(r).toEqual({
    ok: true,
    value: [
      {
        id: "38554676028",
        startedAt: Date.parse("2026-10-14T11:10:10Z"),
        finished: { at: Date.parse("2026-10-14T11:11:36Z"), outcome: "failure" },
      },
      { id: "38554676028", startedAt: Date.parse("2026-10-14T11:10:10Z"), finished: null },
    ],
  });
});

test.each([
  ["success", "success"],
  ["failure", "failure"],
  ["timed_out", "failure"],
  ["startup_failure", "failure"],
])("conclusion %p counts as %p", (conclusion, outcome) => {
  expect(toRunRecord(ghRun("completed", conclusion))?.finished?.outcome).toBe(outcome as never);
});

test.each([["cancelled"], ["skipped"], ["neutral"], ["action_required"], ["stale"]])(
  "conclusion %p is not counted",
  (conclusion) => {
    expect(toRunRecord(ghRun("completed", conclusion))).toBeNull();
  },
);

test.each([["queued"], ["in_progress"], ["waiting"], ["pending"]])(
  "status %p is an active run",
  (status) => {
    expect(toRunRecord(ghRun(status, null))?.finished).toBeNull();
  },
);

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 401: Bad credentials" } },
  ]);
  const r = await new GhRunHistory(runner).recentRuns(50);
  expect(!r.ok && r.error.kind).toBe("auth");
});
```

```bash
bun test ./src/adapters/github/gh-run-history.test.ts
```

Expected: FAIL — `error: Cannot find module './gh-run-history' from '…/gh-run-history.test.ts'`.

- [ ] **Step 7: Implement `src/adapters/github/gh-run-history.ts`**

`gh run list` has no completion timestamp; for a completed run `updatedAt` is when it finished. The repo comes from the working directory's git remote or `GH_REPO` (the workflows set `GH_REPO`).

```ts
import { z } from "zod";
import type { RunHistory, RunOutcome, RunRecord } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const GhRun = z.object({
  databaseId: z.number(),
  status: z.string(),
  conclusion: z.string().nullable(),
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
});
type GhRun = z.infer<typeof GhRun>;

/** Conclusions that count as a failed run. Cancelled, skipped and neutral runs are not counted. */
const FAILED = new Set(["failure", "timed_out", "startup_failure"]);

function outcomeOf(conclusion: string | null): RunOutcome | null {
  if (conclusion === "success") return "success";
  return FAILED.has(conclusion ?? "") ? "failure" : null;
}

/** `null` for a completed run whose conclusion is not counted. `updatedAt` is the completion time. */
export function toRunRecord(run: GhRun): RunRecord | null {
  const id = String(run.databaseId);
  const startedAt = Date.parse(run.createdAt);
  if (run.status !== "completed") return { id, startedAt, finished: null };
  const outcome = outcomeOf(run.conclusion);
  if (outcome === null) return null;
  return { id, startedAt, finished: { at: Date.parse(run.updatedAt), outcome } };
}

/** Pipeline run history from GitHub Actions. The repo comes from the cwd or `GH_REPO`. */
export class GhRunHistory implements RunHistory {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly workflow = "shipwright-pipeline.yml",
  ) {}

  async recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>> {
    const fields = "databaseId,status,conclusion,createdAt,updatedAt";
    const argv = ["gh", "run", "list", "--workflow", this.workflow, "--limit", String(limit)];
    const runs = await runGhJson(this.runner, [...argv, "--json", fields], z.array(GhRun));
    if (!runs.ok) return runs;
    return ok(runs.value.map(toRunRecord).filter((r): r is RunRecord => r !== null));
  }
}
```

```bash
bun test ./src/adapters/github/gh-run-history.test.ts
```

Expected: `15 pass`, `0 fail`.

- [ ] **Step 8: Run the definition of done**

```bash
bun run format && git add -A src/contexts/orchestration src/adapters/github && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 9: Commit**

```bash
git add -A src/contexts/orchestration src/adapters/github
git commit -m "feat(adapters): read pipeline run history with gh"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 3: F10: the idempotent GitHub writer and its fitness rule

**Files:**
- Create: `src/contexts/integrations/ports.ts`, `src/contexts/integrations/index.ts`, `src/adapters/github/gh-github-writer.ts`, `tools/arch/rules/f10-github-writes-only-in-writer.yml`, `tools/arch/rule-tests/f10-github-writes-only-in-writer-test.yml`
- Test: `src/adapters/github/gh-github-writer.test.ts`

F10 in Wave 1a means: every GitHub side effect is a `GithubWriter` method that takes an `IdempotencyKey` and reconciles before acting, implemented only in `src/adapters/github/gh-github-writer.ts`; an ast-grep rule rejects `gh issue|pr|label <write verb>` and `gh api -X POST|PATCH|PUT|DELETE` argv arrays (and `["issue", "create", …]`-style arrays passed to a `gh` helper) anywhere else in `src/`. The key is reconciled against a marker stored in the issue itself until the `SideEffects` ledger exists (1b). `ensureIncident` takes no `FenceToken`: no lease covers a system-wide incident (ADR-0007).

- [ ] **Step 1: Create the port `src/contexts/integrations/ports.ts`**

```ts
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

export interface IncidentReport {
  readonly title: string;
  readonly body: string;
}
export type IncidentAction = "created" | "commented" | "unchanged";
export interface IncidentOutcome {
  readonly issue: number;
  readonly action: IncidentAction;
}

/**
 * GitHub side effects (rule F10). Every method takes an `IdempotencyKey` and reconciles before it
 * acts, so a retried or concurrent call never writes twice for the same key. Implemented only in
 * `src/adapters/github/gh-github-writer.ts`; an ast-grep rule keeps `gh` writes out of other files.
 */
export interface GithubWriter {
  /**
   * Keeps one open incident issue: creates it, or comments on the open one, once per `key`.
   * A key already recorded on the open incident is `unchanged`.
   */
  ensureIncident(
    key: IdempotencyKey,
    report: IncidentReport,
  ): Promise<Result<IncidentOutcome, AdapterError>>;
}
```

- [ ] **Step 2: Create `src/contexts/integrations/index.ts`**

```ts
export type {
  GithubWriter,
  IncidentAction,
  IncidentOutcome,
  IncidentReport,
} from "./ports";
```

- [ ] **Step 3: Write the failing adapter test**

```ts
import { expect, test } from "bun:test";
import { idempotencyKey } from "../../shared/kernel/durability";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import { GhGithubWriter, INCIDENT_LABEL, idempotencyMarker } from "./gh-github-writer";

const key = idempotencyKey("breaker", "open", "1760440000000");
const report = { title: "Breaker open", body: "Dispatch stopped." };
const ok = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const openIncidents = (incidents: unknown[]): ScriptedCall => ({
  prefix: ["gh", "issue", "list"],
  result: ok(JSON.stringify(incidents)),
});

test("creates the label and the incident when none is open", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    { prefix: ["gh", "issue", "create"], result: ok("https://github.com/o/r/issues/901\n") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 901, action: "created" } });
  expect(runner.calls.map((c) => c.argv.slice(0, 3))).toEqual([
    ["gh", "issue", "list"],
    ["gh", "label", "create"],
    ["gh", "issue", "create"],
  ]);
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--label",
    INCIDENT_LABEL,
    "--limit",
    "1",
    "--json",
    "number,body,comments",
  ]);
  expect(runner.calls[2]?.argv).toEqual([
    "gh",
    "issue",
    "create",
    "--title",
    "Breaker open",
    "--body",
    `Dispatch stopped.\n\n${idempotencyMarker(key)}`,
    "--label",
    INCIDENT_LABEL,
  ]);
});

test("comments once on the open incident for a new key", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([{ number: 7, body: "old", comments: [{ body: "earlier trip" }] }]),
    { prefix: ["gh", "issue", "comment"], result: ok("https://github.com/o/r/issues/7#c1") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 7, action: "commented" } });
  expect(runner.calls[1]?.argv).toEqual([
    "gh",
    "issue",
    "comment",
    "7",
    "--body",
    `Dispatch stopped.\n\n${idempotencyMarker(key)}`,
  ]);
});

test("does nothing when the key is already on the incident (body or comment)", async () => {
  for (const incident of [
    { number: 7, body: `x ${idempotencyMarker(key)}`, comments: [] },
    { number: 7, body: null, comments: [{ body: `y ${idempotencyMarker(key)}` }] },
  ]) {
    const runner = new FakeProcessRunner([openIncidents([incident])]);
    const r = await new GhGithubWriter(runner).ensureIncident(key, report);
    expect(r).toEqual({ ok: true, value: { issue: 7, action: "unchanged" } });
    expect(runner.calls).toHaveLength(1);
  }
});

test("a failed write is a classified error", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    {
      prefix: ["gh", "issue", "create"],
      result: {
        exitCode: 1,
        stdout: "",
        stderr: "HTTP 403: Resource not accessible by integration",
      },
    },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(!r.ok && r.error.kind).toBe("auth");
});

test("unexpected create output is a failed error", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    { prefix: ["gh", "issue", "create"], result: ok("created!") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(!r.ok && r.error.message).toMatch(/issue URL/);
});
```

```bash
bun test ./src/adapters/github/gh-github-writer.test.ts
```

Expected: FAIL — `error: Cannot find module './gh-github-writer' from '…/gh-github-writer.test.ts'`.

- [ ] **Step 4: Implement `src/adapters/github/gh-github-writer.ts`**

```ts
// The only file allowed to run `gh` write subcommands (rule F10, tools/arch/rules/f10-*.yml).
// Every method is reconcile-then-act on an IdempotencyKey recorded in the GitHub object itself;
// the SideEffects ledger replaces that record when the SQLite durability adapter lands (Wave 1b).
import { z } from "zod";
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../../contexts/integrations";
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-issue-tracker";
import { runGhJson } from "./gh-json";

export const INCIDENT_LABEL = "shipwright:incident";
export const idempotencyMarker = (key: IdempotencyKey): string =>
  `<!-- shipwright-idempotency-key: ${key} -->`;

const OpenIncident = z.object({
  number: z.number(),
  body: z.string().nullable(),
  comments: z.array(z.object({ body: z.string() })),
});
type OpenIncident = z.infer<typeof OpenIncident>;

const recorded = (incident: OpenIncident, marker: string): boolean =>
  [incident.body ?? "", ...incident.comments.map((c) => c.body)].some((b) => b.includes(marker));

export class GhGithubWriter implements GithubWriter {
  constructor(private readonly runner: ProcessRunner) {}

  async ensureIncident(
    key: IdempotencyKey,
    report: IncidentReport,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const list = ["gh", "issue", "list", "--state", "open", "--label", INCIDENT_LABEL];
    const found = await runGhJson(
      this.runner,
      [...list, "--limit", "1", "--json", "number,body,comments"],
      z.array(OpenIncident),
    );
    if (!found.ok) return found;
    const body = `${report.body}\n\n${idempotencyMarker(key)}`;
    const [open] = found.value;
    if (!open) return this.createIncident(report.title, body);
    if (recorded(open, idempotencyMarker(key)))
      return ok({ issue: open.number, action: "unchanged" });
    const commented = await this.gh(["issue", "comment", String(open.number), "--body", body]);
    return commented.ok ? ok({ issue: open.number, action: "commented" }) : commented;
  }

  private async createIncident(
    title: string,
    body: string,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const label = await this.gh([
      "label",
      "create",
      INCIDENT_LABEL,
      "--color",
      "B60205",
      "--description",
      "Shipwright circuit-breaker incident",
      "--force",
    ]);
    if (!label.ok) return label;
    const created = await this.gh([
      "issue",
      "create",
      "--title",
      title,
      "--body",
      body,
      "--label",
      INCIDENT_LABEL,
    ]);
    if (!created.ok) return created;
    const issue = created.value.trim().match(/\/issues\/(\d+)$/)?.[1];
    if (!issue)
      return err({ kind: "failed", message: `no issue URL in gh output: ${created.value}` });
    return ok({ issue: Number(issue), action: "created" });
  }

  private async gh(args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["gh", ...args], timeoutMs: 30_000 });
    return r.exitCode === 0 && !r.timedOut ? ok(r.stdout) : err(classifyGhError(r));
  }
}
```

```bash
bun test ./src/adapters/github/gh-github-writer.test.ts
```

Expected: `5 pass`, `0 fail`.

- [ ] **Step 5: Write the rule test**

```yaml
id: F10-github-writes-only-in-writer
valid:
  - 'run({ argv: ["gh", "issue", "view", "1", "--json", "title"] });'
  - 'run({ argv: ["gh", "issue", "list", "--label", "x"] });'
  - 'run({ argv: ["gh", "pr", "list", "--state", "open"] });'
  - 'run({ argv: ["gh", "run", "list", "--json", "conclusion"] });'
  - 'run({ argv: ["gh", "api", "repos/o/r/issues", "-X", "GET"] });'
  - 'run({ argv: ["git", "issue", "create"] });'
  - 'const words = ["create", "issue"];'
invalid:
  - 'run({ argv: ["gh", "issue", "create", "--title", t] });'
  - 'run({ argv: ["gh", "issue", "comment", "1", "--body", b] });'
  - 'run({ argv: ["gh", "issue", "edit", "1", "--add-label", "x"] });'
  - 'run({ argv: ["gh", "issue", "close", "1"] });'
  - 'run({ argv: ["gh", "pr", "create", "--fill"] });'
  - 'run({ argv: ["gh", "pr", "merge", "1"] });'
  - 'run({ argv: ["gh", "pr", "comment", "1", "-b", b] });'
  - 'run({ argv: ["gh", "label", "create", "x"] });'
  - "run({ argv: ['gh', 'issue', 'create'] });"
  - 'gh(["issue", "create", "--title", t]);'
  - 'gh(["pr", "merge", "1"]);'
  - 'run({ argv: ["gh", "api", "repos/o/r/issues", "-X", "POST"] });'
  - 'run({ argv: ["gh", "api", "--method", "PATCH", "repos/o/r/issues/1"] });'
  - 'run({ argv: ["gh", "api", "-X", "DELETE", "repos/o/r/labels/x"] });'
  - 'run({ argv: ["gh", "api", "--method=PUT", "repos/o/r/x"] });'
```

- [ ] **Step 6: Show the gap — a write outside the writer is not caught yet**

```bash
printf 'export const argv = ["gh", "issue", "create", "--title", "x"];\n' > src/adapters/github/zz-f10-probe.ts
bunx ast-grep scan; echo "exit=$?"
```

Expected: `exit=0` — nothing reports the probe yet.

- [ ] **Step 7: Add the rule `tools/arch/rules/f10-github-writes-only-in-writer.yml`**

```yaml
id: F10-github-writes-only-in-writer
language: TypeScript
severity: error
message: "F10: GitHub writes go only through src/adapters/github/gh-github-writer.ts. Add an idempotent method (it takes an IdempotencyKey) to the GithubWriter port and call that."
files:
  - "src/**/*.ts"
ignores:
  - "src/adapters/github/gh-github-writer.ts"
  - "src/adapters/github/gh-github-writer.test.ts"
# Write subcommands: gh issue|pr|label create|edit|comment|close|reopen|delete|merge|ready|review|
# lock|transfer, and gh api with a POST/PATCH/PUT/DELETE method. Keep the two regex copies in sync.
rule:
  kind: array
  any:
    - all:
        - has: { nthChild: 1, kind: string, regex: '^["''`]gh["''`]$' }
        - has: { nthChild: 2, kind: string, regex: '^["''`](issue|pr|label)["''`]$' }
        - has:
            nthChild: 3
            kind: string
            regex: '^["''`](create|edit|comment|close|reopen|delete|merge|ready|review|lock|transfer)["''`]$'
    - all:
        - has: { nthChild: 1, kind: string, regex: '^["''`](issue|pr|label)["''`]$' }
        - has:
            nthChild: 2
            kind: string
            regex: '^["''`](create|edit|comment|close|reopen|delete|merge|ready|review|lock|transfer)["''`]$'
    - all:
        - has: { nthChild: 1, kind: string, regex: '^["''`]gh["''`]$' }
        - has: { nthChild: 2, kind: string, regex: '^["''`]api["''`]$' }
        - any:
            - all:
                - has: { kind: string, regex: '^["''`](-X|--method)["''`]$' }
                - has: { kind: string, regex: '^["''`](POST|PATCH|PUT|DELETE)["''`]$' }
            - has: { kind: string, regex: '^["''`](-X|--method=)(POST|PATCH|PUT|DELETE)["''`]$' }
```

- [ ] **Step 8: Run the rule tests and the probe**

```bash
bunx ast-grep test --skip-snapshot-tests
bunx ast-grep scan; echo "exit=$?"
rm src/adapters/github/zz-f10-probe.ts
bunx ast-grep scan; echo "exit=$?"
```

Expected: `PASS F10-github-writes-only-in-writer` and `test result: ok. 4 passed; 0 failed;`; the first scan reports `error[F10-github-writes-only-in-writer]` on `zz-f10-probe.ts` and `exit=1`; after deleting the probe, `exit=0`.

- [ ] **Step 9: Run the definition of done**

```bash
bun run format && git add -A src/contexts/integrations src/adapters/github tools/arch/rules/f10-github-writes-only-in-writer.yml tools/arch/rule-tests/f10-github-writes-only-in-writer-test.yml && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 10: Commit**

```bash
git add -A src/contexts/integrations src/adapters/github tools/arch/rules/f10-github-writes-only-in-writer.yml tools/arch/rule-tests/f10-github-writes-only-in-writer-test.yml
git commit -m "feat(integrations): idempotent incident writer and the F10 rule"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 4: Kill switch: pause flag and label

**Files:**
- Create: `src/contexts/orchestration/domain/pause.ts`, `src/adapters/state/file-pause-flag.ts`, `src/adapters/github/gh-pause-label.ts`
- Modify: `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts`
- Test: `src/contexts/orchestration/domain/pause.test.ts`, `src/adapters/state/file-pause-flag.test.ts`, `src/adapters/github/gh-pause-label.test.ts`

The local flag is the bash daemon's own `~/.shipwright/daemon-pause.flag` (written by `daemon-state.sh`, `daemon-failure.sh`, `daemon-poll-health.sh` and the dashboard), so `shipwright pause` and the daemon agree. Like the daemon, any existing file pauses — even unreadable JSON — unless its `resume_after` has passed.

- [ ] **Step 1: Write the failing domain test**

```ts
import { expect, test } from "bun:test";
import { type LocalPause, pauseStatus } from "./pause";

const flag = (resumeAfter: number | null = null): LocalPause => ({
  reason: "maintenance",
  since: "2026-10-14T10:00:00Z",
  resumeAfter,
});

test("nothing set is not paused", () => {
  expect(pauseStatus(null, [], 0)).toEqual({ paused: false, reasons: [] });
});

test("the local flag pauses, with its reason", () => {
  expect(pauseStatus(flag(), [], 0)).toEqual({
    paused: true,
    reasons: ["local pause flag: maintenance (since 2026-10-14T10:00:00Z)"],
  });
});

test("a flag whose resume_after has passed no longer pauses", () => {
  expect(pauseStatus(flag(1_000), [], 999).paused).toBe(true);
  expect(pauseStatus(flag(1_000), [], 1_000).paused).toBe(false);
});

test("the shipwright:pause label pauses everything", () => {
  expect(pauseStatus(null, [12, 34], 0)).toEqual({
    paused: true,
    reasons: ["label shipwright:pause on #12, #34"],
  });
});

test("an unchecked label (no GitHub) only uses the flag", () => {
  expect(pauseStatus(null, null, 0)).toEqual({ paused: false, reasons: [] });
});
```

```bash
bun test ./src/contexts/orchestration/domain/pause.test.ts
```

Expected: FAIL — `error: Cannot find module './pause' from '…/pause.test.ts'`.

- [ ] **Step 2: Implement `src/contexts/orchestration/domain/pause.ts`**

```ts
// Kill switch (spec §6.2): a local pause flag (shared with the bash daemon) or the
// `shipwright:pause` label on any open issue stops dispatch everywhere.

export const PAUSE_LABEL = "shipwright:pause";

export interface LocalPause {
  readonly reason: string;
  /** ISO timestamp when the flag was set; empty when unknown. */
  readonly since: string;
  /** Epoch ms after which the flag no longer pauses (the daemon's failure backoff); null = never. */
  readonly resumeAfter: number | null;
}

export interface PauseStatus {
  readonly paused: boolean;
  readonly reasons: readonly string[];
}

/** `labelled` is null when the label was not checked (no GitHub access). */
export function pauseStatus(
  flag: LocalPause | null,
  labelled: readonly number[] | null,
  now: number,
): PauseStatus {
  const reasons: string[] = [];
  if (flag && (flag.resumeAfter === null || now < flag.resumeAfter)) {
    const since = flag.since ? ` (since ${flag.since})` : "";
    reasons.push(`local pause flag: ${flag.reason}${since}`);
  }
  if (labelled && labelled.length > 0) {
    reasons.push(`label ${PAUSE_LABEL} on ${labelled.map((n) => `#${n}`).join(", ")}`);
  }
  return { paused: reasons.length > 0, reasons };
}
```

```bash
bun test ./src/contexts/orchestration/domain/pause.test.ts
```

Expected: `5 pass`, `0 fail`.

- [ ] **Step 3: Replace `src/contexts/orchestration/ports.ts` with**

```ts
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { RunRecord } from "./domain/breaker";
import type { LocalPause } from "./domain/pause";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}

/** The local pause flag file the bash daemon also reads (`~/.shipwright/daemon-pause.flag`). */
export interface PauseFlag {
  /** `null` when no flag is set. */
  read(): Promise<Result<LocalPause | null, AdapterError>>;
  write(reason: string, at: string): Promise<Result<void, AdapterError>>;
  /** Idempotent: clearing an absent flag is ok. */
  clear(): Promise<Result<void, AdapterError>>;
}

/** Open issues carrying the `shipwright:pause` label. */
export interface PauseLabel {
  labelled(): Promise<Result<readonly number[], AdapterError>>;
}
```

- [ ] **Step 4: Replace `src/contexts/orchestration/index.ts` with**

```ts
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export { type LocalPause, PAUSE_LABEL, type PauseStatus, pauseStatus } from "./domain/pause";
export type {
  PauseFlag,
  PauseLabel,
  RunHistory,
} from "./ports";
```

- [ ] **Step 5: Write the failing file-flag test**

```ts
import { afterEach, expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { FilePauseFlag, parsePauseFlag } from "./file-pause-flag";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());
const flagIn = (e: TestEnv) => join(e.stateDir, "daemon-pause.flag");

test("no file means no flag", async () => {
  env = createTestEnv();
  expect(await new FilePauseFlag(flagIn(env)).read()).toEqual({ ok: true, value: null });
});

test("write, read and clear round-trip in the bash daemon's format", async () => {
  env = createTestEnv();
  const flag = new FilePauseFlag(join(env.stateDir, "nested", "daemon-pause.flag"));
  expect(await flag.write("maintenance", "2026-10-14T10:00:00.000Z")).toEqual({
    ok: true,
    value: undefined,
  });
  expect(await flag.read()).toEqual({
    ok: true,
    value: { reason: "maintenance", since: "2026-10-14T10:00:00.000Z", resumeAfter: null },
  });
  expect(await flag.clear()).toEqual({ ok: true, value: undefined });
  expect(await flag.clear()).toEqual({ ok: true, value: undefined });
  expect(await flag.read()).toEqual({ ok: true, value: null });
});

test("written JSON has the keys the daemon reads", async () => {
  env = createTestEnv();
  await new FilePauseFlag(flagIn(env)).write("x", "2026-10-14T10:00:00.000Z");
  expect(JSON.parse(readFileSync(flagIn(env), "utf8"))).toEqual({
    reason: "x",
    timestamp: "2026-10-14T10:00:00.000Z",
    source: "shipwright pause",
  });
  expect(existsSync(`${flagIn(env)}.tmp`)).toBe(false);
});

test("reads flags written by the bash daemon", async () => {
  env = createTestEnv();
  writeFileSync(
    flagIn(env),
    '{"reason":"consecutive_failures","timestamp":"t","resume_after":"2026-10-14T11:00:00Z"}',
  );
  expect(await new FilePauseFlag(flagIn(env)).read()).toEqual({
    ok: true,
    value: {
      reason: "consecutive_failures",
      since: "t",
      resumeAfter: Date.parse("2026-10-14T11:00:00Z"),
    },
  });
});

test.each([
  ['{"paused":true,"reason":"disk_low"}', "disk_low"],
  ["not json", "pause flag present"],
  ["", "pause flag present"],
])("any existing flag file pauses, even %p", (text, reason) => {
  expect(parsePauseFlag(text)).toEqual({ reason, since: "", resumeAfter: null });
});
```

```bash
bun test ./src/adapters/state/file-pause-flag.test.ts
```

Expected: FAIL — `error: Cannot find module './file-pause-flag' from '…/file-pause-flag.test.ts'`.

- [ ] **Step 6: Implement `src/adapters/state/file-pause-flag.ts`**

```ts
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import type { LocalPause, PauseFlag } from "../../contexts/orchestration";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

// The bash daemon writes {reason, timestamp[, resume_after]} or {paused, reason}; any file pauses.
const FlagFile = z.object({
  reason: z.string().optional(),
  timestamp: z.string().optional(),
  resume_after: z.string().optional(),
});

/** Like the daemon, treats any existing flag file as a pause, even an unreadable one. */
export function parsePauseFlag(text: string): LocalPause {
  let json: unknown = {};
  try {
    json = JSON.parse(text);
  } catch {
    // Unparseable content still pauses (fail closed).
  }
  const parsed = FlagFile.safeParse(json);
  const data = parsed.success ? parsed.data : {};
  const resumeAfter = data.resume_after ? Date.parse(data.resume_after) : Number.NaN;
  return {
    reason: data.reason ?? "pause flag present",
    since: data.timestamp ?? "",
    resumeAfter: Number.isNaN(resumeAfter) ? null : resumeAfter,
  };
}

const failed = (e: unknown): AdapterError => ({
  kind: "failed",
  message: e instanceof Error ? e.message : String(e),
});

export class FilePauseFlag implements PauseFlag {
  constructor(private readonly path: string) {}

  async read(): Promise<Result<LocalPause | null, AdapterError>> {
    try {
      return ok(parsePauseFlag(await readFile(this.path, "utf8")));
    } catch (e) {
      return (e as { code?: string }).code === "ENOENT" ? ok(null) : err(failed(e));
    }
  }

  async write(reason: string, at: string): Promise<Result<void, AdapterError>> {
    const json = JSON.stringify({ reason, timestamp: at, source: "shipwright pause" });
    try {
      await mkdir(dirname(this.path), { recursive: true });
      await writeFile(`${this.path}.tmp`, `${json}\n`);
      await rename(`${this.path}.tmp`, this.path);
      return ok(undefined);
    } catch (e) {
      return err(failed(e));
    }
  }

  async clear(): Promise<Result<void, AdapterError>> {
    try {
      await rm(this.path, { force: true });
      return ok(undefined);
    } catch (e) {
      return err(failed(e));
    }
  }
}
```

```bash
bun test ./src/adapters/state/file-pause-flag.test.ts
```

Expected: `7 pass`, `0 fail`.

- [ ] **Step 7: Write the failing label test**

```ts
import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhPauseLabel } from "./gh-pause-label";

test("lists open issues carrying shipwright:pause", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["gh", "issue", "list"],
      result: { exitCode: 0, stdout: '[{"number":12},{"number":34}]', stderr: "" },
    },
  ]);
  expect(await new GhPauseLabel(runner).labelled()).toEqual({ ok: true, value: [12, 34] });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--label",
    "shipwright:pause",
    "--limit",
    "20",
    "--json",
    "number",
  ]);
});

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 503: unavailable" } },
  ]);
  const r = await new GhPauseLabel(runner).labelled();
  expect(!r.ok && r.error.kind).toBe("transient");
});
```

```bash
bun test ./src/adapters/github/gh-pause-label.test.ts
```

Expected: FAIL — `error: Cannot find module './gh-pause-label' from '…/gh-pause-label.test.ts'`.

- [ ] **Step 8: Implement `src/adapters/github/gh-pause-label.ts`**

```ts
import { z } from "zod";
import { PAUSE_LABEL, type PauseLabel } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

export class GhPauseLabel implements PauseLabel {
  constructor(private readonly runner: ProcessRunner) {}

  async labelled(): Promise<Result<readonly number[], AdapterError>> {
    const argv = ["gh", "issue", "list", "--state", "open", "--label", PAUSE_LABEL];
    const schema = z.array(z.object({ number: z.number() }));
    const r = await runGhJson(this.runner, [...argv, "--limit", "20", "--json", "number"], schema);
    return r.ok ? ok(r.value.map((i) => i.number)) : r;
  }
}
```

```bash
bun test ./src/adapters/github/gh-pause-label.test.ts
```

Expected: `2 pass`, `0 fail`.

- [ ] **Step 9: Run the definition of done**

```bash
bun run format && git add -A src/contexts/orchestration src/adapters && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 10: Commit**

```bash
git add -A src/contexts/orchestration src/adapters
git commit -m "feat(orchestration): kill switch flag and label"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 5: Breaker and pause use cases

**Files:**
- Create: `src/contexts/orchestration/application/breaker.ts`, `src/contexts/orchestration/application/pause.ts`, `src/testing/fake-safety-ports.ts`
- Modify: `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts`
- Test: `src/contexts/orchestration/application/breaker.test.ts`, `src/contexts/orchestration/application/pause.test.ts`

`SafetyPorts` bundles every port the gates use; `src/main.ts` builds it (Task 6) and later tasks add one field each. `checkBreaker` is the gate: when the breaker is open it ensures the incident under the key `breaker:open:<opened-at>`, so repeated checks during one trip write once. `breakerStatus` never writes.

- [ ] **Step 1: Replace `src/contexts/orchestration/ports.ts` with**

```ts
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { GithubWriter } from "../integrations";
import type { RunRecord } from "./domain/breaker";
import type { LocalPause } from "./domain/pause";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}

/** The local pause flag file the bash daemon also reads (`~/.shipwright/daemon-pause.flag`). */
export interface PauseFlag {
  /** `null` when no flag is set. */
  read(): Promise<Result<LocalPause | null, AdapterError>>;
  write(reason: string, at: string): Promise<Result<void, AdapterError>>;
  /** Idempotent: clearing an absent flag is ok. */
  clear(): Promise<Result<void, AdapterError>>;
}

/** Open issues carrying the `shipwright:pause` label. */
export interface PauseLabel {
  labelled(): Promise<Result<readonly number[], AdapterError>>;
}

/** Everything the safety gates read or write, wired in src/main.ts. */
export interface SafetyPorts {
  readonly now: () => number;
  readonly runs: RunHistory;
  readonly pauseFlag: PauseFlag;
  readonly pauseLabel: PauseLabel;
  readonly github: GithubWriter;
}
```

- [ ] **Step 2: Replace `src/contexts/orchestration/index.ts` with**

```ts
export {
  type BreakerReport,
  breakerStatus,
  checkBreaker,
  RUN_HISTORY_LIMIT,
} from "./application/breaker";
export { type PauseOptions, pause, readPause, resume } from "./application/pause";
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export { type LocalPause, PAUSE_LABEL, type PauseStatus, pauseStatus } from "./domain/pause";
export type {
  PauseFlag,
  PauseLabel,
  RunHistory,
  SafetyPorts,
} from "./ports";
```

- [ ] **Step 3: Create the fakes `src/testing/fake-safety-ports.ts`**

```ts
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../contexts/integrations";
import type {
  LocalPause,
  PauseFlag,
  PauseLabel,
  RunHistory,
  RunRecord,
  SafetyPorts,
} from "../contexts/orchestration";
import type { IdempotencyKey } from "../shared/kernel/durability";
import type { AdapterError } from "../shared/kernel/ports";
import { ok, type Result } from "../shared/kernel/result";

export const NOW = Date.parse("2026-10-14T12:00:00Z");

export class MemoryPauseFlag implements PauseFlag {
  constructor(public flag: LocalPause | null = null) {}
  async read() {
    return ok(this.flag);
  }
  async write(reason: string, at: string) {
    this.flag = { reason, since: at, resumeAfter: null };
    return ok(undefined);
  }
  async clear() {
    this.flag = null;
    return ok(undefined);
  }
}

export class RecordingGithubWriter implements GithubWriter {
  readonly calls: { key: IdempotencyKey; report: IncidentReport }[] = [];
  constructor(
    private readonly result: Result<IncidentOutcome, AdapterError> = ok({
      issue: 900,
      action: "created",
    }),
  ) {}
  async ensureIncident(key: IdempotencyKey, report: IncidentReport) {
    this.calls.push({ key, report });
    return this.result;
  }
}

export const fixedRuns = (r: Result<readonly RunRecord[], AdapterError>): RunHistory => ({
  recentRuns: async () => r,
});
export const fixedLabel = (r: Result<readonly number[], AdapterError>): PauseLabel => ({
  labelled: async () => r,
});

/** Safety ports with harmless defaults: nothing running, paused, capped or awaiting review. */
export function fakeSafetyPorts(over: Partial<SafetyPorts> = {}): SafetyPorts {
  return {
    now: () => NOW,
    runs: fixedRuns(ok([])),
    pauseFlag: new MemoryPauseFlag(),
    pauseLabel: fixedLabel(ok([])),
    github: new RecordingGithubWriter(),
    ...over,
  };
}
```

- [ ] **Step 4: Write the failing use-case tests**

```ts
import { expect, test } from "bun:test";
import { idempotencyKey } from "../../../shared/kernel/durability";
import { err, ok } from "../../../shared/kernel/result";
import {
  fakeSafetyPorts,
  fixedRuns,
  NOW,
  RecordingGithubWriter,
} from "../../../testing/fake-safety-ports";
import type { RunRecord } from "../domain/breaker";
import { breakerStatus, checkBreaker } from "./breaker";

const failed = (i: number): RunRecord => ({
  id: `r${i}`,
  startedAt: NOW - 60_000 * (10 - i),
  finished: { at: NOW - 60_000 * (9 - i), outcome: "failure" },
});
const fiveFailures = [0, 1, 2, 3, 4].map(failed); // last ends at NOW - 5 min

test("a closed breaker allows dispatch and writes nothing", async () => {
  const github = new RecordingGithubWriter();
  const r = await checkBreaker(fakeSafetyPorts({ github }));
  expect(r).toEqual({
    ok: true,
    value: { state: { kind: "closed", failures: 0, considered: 0 }, allowed: true, incident: null },
  });
  expect(github.calls).toHaveLength(0);
});

test("an open breaker blocks and ensures one incident keyed by the trip time", async () => {
  const github = new RecordingGithubWriter();
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  const since = NOW - 5 * 60_000;
  expect(r.ok && r.value.allowed).toBe(false);
  expect(r.ok && r.value.incident).toEqual({ issue: 900, action: "created" });
  expect(github.calls).toHaveLength(1);
  expect(github.calls[0]?.key).toBe(idempotencyKey("breaker", "open", String(since)));
  expect(github.calls[0]?.report.title).toContain("circuit breaker is open");
});

test("status never writes, even when open", async () => {
  const github = new RecordingGithubWriter();
  const r = await breakerStatus(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  expect(r.ok && r.value.state.kind).toBe("open");
  expect(github.calls).toHaveLength(0);
});

test("an unreadable history is an error (callers fail closed)", async () => {
  const runs = fixedRuns(err({ kind: "auth", message: "HTTP 401" }));
  expect(await checkBreaker(fakeSafetyPorts({ runs }))).toEqual({
    ok: false,
    error: { kind: "auth", message: "HTTP 401" },
  });
});

test("a failed incident write is an error", async () => {
  const github = new RecordingGithubWriter(err({ kind: "transient", message: "HTTP 502" }));
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  expect(!r.ok && r.error.kind).toBe("transient");
});
```

```ts
import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import {
  fakeSafetyPorts,
  fixedLabel,
  MemoryPauseFlag,
  NOW,
} from "../../../testing/fake-safety-ports";
import { pause, readPause, resume } from "./pause";

test("pause writes the flag with the current time; resume clears it", async () => {
  const pauseFlag = new MemoryPauseFlag();
  const ports = fakeSafetyPorts({ pauseFlag });
  await pause(ports, "investigating #8524");
  expect(pauseFlag.flag).toEqual({
    reason: "investigating #8524",
    since: new Date(NOW).toISOString(),
    resumeAfter: null,
  });
  expect((await readPause(ports, { github: true })).ok).toBe(true);
  await resume(ports);
  expect(pauseFlag.flag).toBeNull();
});

test("the label pauses; without GitHub it is not checked", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([7])) });
  expect(await readPause(ports, { github: true })).toEqual({
    ok: true,
    value: { paused: true, reasons: ["label shipwright:pause on #7"] },
  });
  expect(await readPause(ports, { github: false })).toEqual({
    ok: true,
    value: { paused: false, reasons: [] },
  });
});

test("an unreadable label is an error (callers fail closed)", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(err({ kind: "auth", message: "x" })) });
  expect((await readPause(ports, { github: true })).ok).toBe(false);
});
```

```bash
bun test ./src/contexts/orchestration/application/
```

Expected: FAIL — `Cannot find module './breaker'` and `Cannot find module './pause'`.

- [ ] **Step 5: Implement `src/contexts/orchestration/application/breaker.ts`**

```ts
import { idempotencyKey } from "../../../shared/kernel/durability";
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import type { IncidentOutcome } from "../../integrations";
import {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  breakerIncident,
  DEFAULT_BREAKER_POLICY,
  evaluateBreaker,
} from "../domain/breaker";
import type { SafetyPorts } from "../ports";

/** Runs read per check: the 8-run window plus room for in-flight and uncounted runs. */
export const RUN_HISTORY_LIMIT = 50;

export interface BreakerReport {
  readonly state: BreakerState;
  readonly allowed: boolean;
  /** Set only by checkBreaker when the breaker is open. */
  readonly incident: IncidentOutcome | null;
}

/** Read-only: evaluates the breaker over recent runs. */
export async function breakerStatus(
  ports: Pick<SafetyPorts, "runs" | "now">,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): Promise<Result<BreakerReport, AdapterError>> {
  const runs = await ports.runs.recentRuns(RUN_HISTORY_LIMIT);
  if (!runs.ok) return runs;
  const state = evaluateBreaker(runs.value, ports.now(), policy);
  return ok({ state, allowed: breakerAllowsDispatch(state), incident: null });
}

/** The dispatch gate: like breakerStatus, and an open breaker ensures one incident per trip. */
export async function checkBreaker(
  ports: Pick<SafetyPorts, "runs" | "now" | "github">,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): Promise<Result<BreakerReport, AdapterError>> {
  const status = await breakerStatus(ports, policy);
  if (!status.ok || status.value.state.kind !== "open") return status;
  const { state } = status.value;
  const key = idempotencyKey("breaker", "open", String(state.since));
  const incident = await ports.github.ensureIncident(key, breakerIncident(state, policy));
  return incident.ok ? ok({ ...status.value, incident: incident.value }) : incident;
}
```

- [ ] **Step 6: Implement `src/contexts/orchestration/application/pause.ts`**

```ts
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { type PauseStatus, pauseStatus } from "../domain/pause";
import type { SafetyPorts } from "../ports";

export interface PauseOptions {
  /** False in no-GitHub mode: only the local flag is checked. */
  readonly github: boolean;
}

export async function readPause(
  ports: Pick<SafetyPorts, "pauseFlag" | "pauseLabel" | "now">,
  options: PauseOptions,
): Promise<Result<PauseStatus, AdapterError>> {
  const flag = await ports.pauseFlag.read();
  if (!flag.ok) return flag;
  if (!options.github) return ok(pauseStatus(flag.value, null, ports.now()));
  const labelled = await ports.pauseLabel.labelled();
  if (!labelled.ok) return labelled;
  return ok(pauseStatus(flag.value, labelled.value, ports.now()));
}

export function pause(
  ports: Pick<SafetyPorts, "pauseFlag" | "now">,
  reason: string,
): Promise<Result<void, AdapterError>> {
  return ports.pauseFlag.write(reason, new Date(ports.now()).toISOString());
}

/** Clears the local flag only; a `shipwright:pause` label must be removed on GitHub. */
export function resume(ports: Pick<SafetyPorts, "pauseFlag">): Promise<Result<void, AdapterError>> {
  return ports.pauseFlag.clear();
}
```

- [ ] **Step 7: Run the tests**

```bash
bun test ./src/contexts/orchestration/application/
```

Expected: `8 pass`, `0 fail`.

- [ ] **Step 8: Run the definition of done**

```bash
bun run format && git add -A src/contexts/orchestration src/testing && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 9: Commit**

```bash
git add -A src/contexts/orchestration src/testing
git commit -m "feat(orchestration): breaker and pause use cases"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 6: CLI plumbing and `shipwright breaker`

**Files:**
- Create: `src/cli/shared.ts`, `src/testing/cli-harness.ts`, `src/cli/commands/breaker.ts`
- Modify: `src/cli/command.ts`, `src/cli/commands/index.ts`, `src/cli/commands/hello.test.ts`, `src/main.ts`, `src/main.test.ts`, `scripts/sw`, `docs/plans/port/progress.json`, `docs/reference/cli.md`
- Test: `src/cli/commands/breaker.test.ts`, `src/main.test.ts`

Commands get adapters through `ctx.safety()`, a factory `main` builds lazily, so `hello` and `--help` never touch the environment. `buildSafetyPorts` reads bash-shared files from `$HOME/.shipwright`, which bash uses even when `SHIPWRIGHT_STATE_DIR` is set (spec §9 risk row). This follows `.claude/skills/add-command/SKILL.md`: new command, `run_ts` router line, progress entry with `status: parity-green`, `parity: null`.

- [ ] **Step 1: Add the shared CLI helpers `src/cli/shared.ts`**

```ts
import type { AdapterError } from "../shared/kernel/ports";
import type { CliIO } from "./command";

export const isHelp = (arg: string | undefined): boolean => arg === "--help" || arg === "-h";

/** Bad arguments: message on stderr, usage on stdout, exit 2 (the CLI's usage-error code). */
export function usageError(io: CliIO, usage: string, message: string): number {
  io.err(`✗ ${message}`);
  io.out(usage);
  return 2;
}

/** Gates fail closed: a source that cannot be read blocks, with exit 1. */
export function adapterFailure(io: CliIO, what: string, error: AdapterError): number {
  io.err(`✗ ${what}: cannot verify (${error.kind}): ${error.message}`);
  return 1;
}
```

- [ ] **Step 2: Add the test harness `src/testing/cli-harness.ts`**

```ts
import type { CliIO, CommandContext } from "../cli/command";
import type { SafetyPorts } from "../contexts/orchestration";

export interface CapturedIO extends CliIO {
  readonly outLines: string[];
  readonly errLines: string[];
}

export function captureIO(): CapturedIO {
  const outLines: string[] = [];
  const errLines: string[] = [];
  return {
    outLines,
    errLines,
    out: (t) => outLines.push(t),
    err: (t) => errLines.push(t),
  };
}

/** A command context; `safety()` throws unless ports are given (commands like hello need none). */
export function commandContext(io: CliIO, safety?: SafetyPorts): CommandContext {
  return {
    io,
    version: "3.3.0",
    safety: () => {
      if (!safety) throw new Error("this command was not given safety ports");
      return safety;
    },
  };
}
```

- [ ] **Step 3: Add `safety` to the command context in `src/cli/command.ts`**

In `src/cli/command.ts`, replace:

```ts
export interface CliIO {
```

with:

```ts
import type { SafetyPorts } from "../contexts/orchestration";

export interface CliIO {
```

In `src/cli/command.ts`, replace:

```ts
  readonly io: CliIO;
  readonly version: string;
}
```

with:

```ts
  readonly io: CliIO;
  readonly version: string;
  /** Adapters for the safety commands, built on first call (commands that need none never call it). */
  readonly safety: () => SafetyPorts;
}
```

- [ ] **Step 4: Update `src/cli/commands/hello.test.ts` to the new context**

In `src/cli/commands/hello.test.ts`, replace:

```ts
import type { CliIO } from "../command";
```

with:

```ts
import { commandContext } from "../../testing/cli-harness";
import type { CliIO } from "../command";
```

In `src/cli/commands/hello.test.ts`, replace all four occurrences of:

```ts
{ io, version: "3.3.0" }
```

with:

```ts
commandContext(io)
```

- [ ] **Step 5: Write the failing composition-root tests**

In `src/main.test.ts`, replace:

```ts
import type { Command } from "./cli/command";
import { main } from "./main";
```

with:

```ts
import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Command } from "./cli/command";
import { commands } from "./cli/commands";
import { buildSafetyPorts, main } from "./main";
import { fakeSafetyPorts } from "./testing/fake-safety-ports";
import { createTestEnv } from "./testing/test-env";
```

Append to the end of `src/main.test.ts`:

```ts
test("a command gets the injected safety factory; hello never calls it", async () => {
  const c = io();
  let built = 0;
  const probe: Command = {
    name: "probe",
    aliases: [],
    summary: "uses ports",
    usage: "",
    run: async (_args, ctx) => {
      ctx.safety();
      return 0;
    },
  };
  const ports = fakeSafetyPorts();
  const safety = () => {
    built++;
    return ports;
  };
  expect(await main(["hello"], c.io, [...commands, probe], safety)).toBe(0);
  expect(built).toBe(0);
  expect(await main(["probe"], c.io, [probe], safety)).toBe(0);
  expect(built).toBe(1);
});

test("buildSafetyPorts keeps the pause flag where the bash daemon reads it", async () => {
  const env = createTestEnv();
  try {
    const ports = buildSafetyPorts({ HOME: env.home, SHIPWRIGHT_STATE_DIR: join(env.root, "s") });
    await ports.pauseFlag.write("test", "2026-10-14T00:00:00.000Z");
    expect(existsSync(join(env.home, ".shipwright", "daemon-pause.flag"))).toBe(true);
  } finally {
    env.cleanup();
  }
});
```

```bash
bun test ./src/main.test.ts
```

Expected: FAIL — `SyntaxError: Export named 'buildSafetyPorts' not found in module '…/src/main.ts'`.

- [ ] **Step 6: Wire the adapters in `src/main.ts`**

In `src/main.ts`, replace:

```ts
import pkg from "../package.json";
import type { CliIO, Command } from "./cli/command";
import { commands, findCommand } from "./cli/commands";
```

with:

```ts
import { join } from "node:path";
import pkg from "../package.json";
import { GhGithubWriter } from "./adapters/github/gh-github-writer";
import { GhPauseLabel } from "./adapters/github/gh-pause-label";
import { GhRunHistory } from "./adapters/github/gh-run-history";
import { resolvePaths } from "./adapters/paths";
import { BunProcessRunner } from "./adapters/process/bun-process-runner";
import { FilePauseFlag } from "./adapters/state/file-pause-flag";
import type { CliIO, Command } from "./cli/command";
import { commands, findCommand } from "./cli/commands";
import type { SafetyPorts } from "./contexts/orchestration";
```

In `src/main.ts`, replace:

```ts
function renderHelp(
```

with:

```ts
/** Adapters for the safety commands (ADR-0007). */
export function buildSafetyPorts(env: Readonly<Record<string, string | undefined>>): SafetyPorts {
  // Files shared with the bash daemon live in ~/.shipwright, which bash uses even when
  // SHIPWRIGHT_STATE_DIR is set (spec §9); read them where bash writes them.
  const legacyDir = join(resolvePaths(env).home, ".shipwright");
  const runner = new BunProcessRunner();
  return {
    now: () => Date.now(),
    runs: new GhRunHistory(runner),
    pauseFlag: new FilePauseFlag(join(legacyDir, "daemon-pause.flag")),
    pauseLabel: new GhPauseLabel(runner),
    github: new GhGithubWriter(runner),
  };
}

function once<T>(make: () => T): () => T {
  let value: T | undefined;
  return () => {
    value ??= make();
    return value;
  };
}

function renderHelp(
```

In `src/main.ts`, replace:

```ts
  registry: readonly Command[] = commands,
): Promise<number> {
```

with:

```ts
  registry: readonly Command[] = commands,
  safety: () => SafetyPorts = once(() => buildSafetyPorts(process.env)),
): Promise<number> {
```

In `src/main.ts`, replace:

```ts
return await command.run(args, { io, version: pkg.version });
```

with:

```ts
return await command.run(args, { io, version: pkg.version, safety });
```

```bash
bun test ./src/main.test.ts ./src/cli
```

Expected: `19 pass`, `0 fail`.

- [ ] **Step 7: Write the failing command test**

```ts
import { expect, test } from "bun:test";
import type { RunRecord } from "../../contexts/orchestration";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import {
  fakeSafetyPorts,
  fixedRuns,
  NOW,
  RecordingGithubWriter,
} from "../../testing/fake-safety-ports";
import { breakerCommand } from "./breaker";

const failures: RunRecord[] = [0, 1, 2, 3, 4].map((i) => ({
  id: `r${i}`,
  startedAt: NOW - 600_000,
  finished: { at: NOW - 60_000 * (5 - i), outcome: "failure" },
}));

test("check exits 0 when closed", async () => {
  const io = captureIO();
  expect(await breakerCommand.run(["check"], commandContext(io, fakeSafetyPorts()))).toBe(0);
  expect(io.outLines).toEqual(["✓ breaker: closed (0 of the last 0 runs failed)"]);
});

test("check exits 1 when open and reports the incident", async () => {
  const io = captureIO();
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) });
  expect(await breakerCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual([
    "✗ breaker: open since 2026-10-14T11:59:00.000Z; probe allowed after 2026-10-14T12:29:00.000Z",
    "  incident #900 (created)",
  ]);
  expect(github.calls).toHaveLength(1);
});

test("status reports an open breaker, exits 0 and never writes", async () => {
  const io = captureIO();
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) });
  expect(await breakerCommand.run(["status"], commandContext(io, ports))).toBe(0);
  expect(io.outLines[0]).toStartWith("✗ breaker: open since");
  expect(github.calls).toHaveLength(0);
});

test("an unreadable run history blocks (exit 1)", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ runs: fixedRuns(err({ kind: "auth", message: "HTTP 401" })) });
  expect(await breakerCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.errLines).toEqual(["✗ breaker: cannot verify (auth): HTTP 401"]);
});

test.each([[[]], [["nope"]], [["check", "extra"]]])("bad arguments %p exit 2", async (args) => {
  const io = captureIO();
  expect(await breakerCommand.run(args, commandContext(io))).toBe(2);
  expect(io.outLines.join("\n")).toContain("USAGE\n  shipwright breaker <status|check>");
});

test("--help prints usage and exits 0", async () => {
  const io = captureIO();
  expect(await breakerCommand.run(["--help"], commandContext(io))).toBe(0);
});
```

```bash
bun test ./src/cli/commands/breaker.test.ts
```

Expected: FAIL — `error: Cannot find module './breaker' from '…/breaker.test.ts'`.

- [ ] **Step 8: Implement `src/cli/commands/breaker.ts`**

```ts
import { breakerStatus, checkBreaker, describeBreaker } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright breaker <status|check>

DESCRIPTION
  Global circuit breaker over recent pipeline runs (spec §6.2, ADR-0007). It opens when at
  least 5 of the last 8 finished runs failed. After a 30-minute cool-down one probe run is
  allowed; its result closes or re-opens the breaker.

COMMANDS
  status   Print the breaker state. Never writes. Exits 0.
  check    Exit 0 when dispatch is allowed, 1 when it is not or the run history cannot be
           read. While open, opens or updates the one shipwright:incident issue (once per trip).

EXAMPLES
  shipwright breaker status
  shipwright breaker check && gh workflow run shipwright-pipeline.yml -f issue_number=42`;

export const breakerCommand: Command = {
  name: "breaker",
  aliases: [],
  summary: "Global circuit breaker: show it, or check it as a dispatch gate",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelp(sub)) {
      io.out(usage);
      return 0;
    }
    if ((sub !== "status" && sub !== "check") || rest.length > 0) {
      return usageError(io, usage, `Expected status or check, got: ${args.join(" ") || "nothing"}`);
    }
    const r = sub === "check" ? await checkBreaker(safety()) : await breakerStatus(safety());
    if (!r.ok) return adapterFailure(io, "breaker", r.error);
    io.out(`${r.value.allowed ? "✓" : "✗"} breaker: ${describeBreaker(r.value.state)}`);
    if (r.value.incident) {
      io.out(`  incident #${r.value.incident.issue} (${r.value.incident.action})`);
    }
    return sub === "check" && !r.value.allowed ? 1 : 0;
  },
};
```

- [ ] **Step 9: Register it — replace `src/cli/commands/index.ts` with**

```ts
import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { helloCommand } from "./hello";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
```

```bash
bun test ./src/cli/commands/breaker.test.ts
```

Expected: `8 pass`, `0 fail`.

- [ ] **Step 10: Route it in `scripts/sw`**

In `scripts/sw`, replace:

```text
        hello)
            run_ts hello "$@"
            ;;
```

with:

```text
        hello)
            run_ts hello "$@"
            ;;
        breaker)
            run_ts breaker "$@"
            ;;
```

- [ ] **Step 11: Add the progress entry**

In `docs/plans/port/progress.json`, replace the end of the file:

```json
    "parity": "scripts/sw-hello-test.sh",
    "status": "parity-green"
  }
]
```

with:

```json
    "parity": "scripts/sw-hello-test.sh",
    "status": "parity-green"
  },
  {
    "command": "breaker",
    "aliases": [],
    "script": "sw-breaker.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a (spec §6.2 global circuit breaker); no bash predecessor."
  }
]
```

- [ ] **Step 12: Regenerate the CLI reference and try it**

```bash
bun run docs:gen
bash -n scripts/sw && echo router-ok
bun src/cli.ts breaker; echo "exit=$?"
```

Expected: `docs/reference/cli.md` gains a `breaker` section; `router-ok`; the usage error `✗ Expected status or check, got: nothing`, the usage text and `exit=2`.

- [ ] **Step 13: Run the definition of done**

```bash
bun run format && git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 14: Commit**

```bash
git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md
git commit -m "feat(cli): shipwright breaker"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 7: `shipwright pause`, `resume` and `paused`

**Files:**
- Create: `src/cli/commands/pause.ts`
- Modify: `src/cli/commands/index.ts`, `scripts/sw`, `docs/plans/port/progress.json`, `docs/reference/cli.md`
- Test: `src/cli/commands/pause.test.ts`

`paused` fails closed: when the flag or the label cannot be read it reports paused (exit 0), so `! shipwright paused` never lets dispatch through on an error. `resume` clears only the local flag; removing the label is a deliberate human GitHub action.

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedLabel, MemoryPauseFlag } from "../../testing/fake-safety-ports";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

test("pause sets the local flag with the given reason", async () => {
  const pauseFlag = new MemoryPauseFlag();
  const io = captureIO();
  const ctx = commandContext(io, fakeSafetyPorts({ pauseFlag }));
  expect(await pauseCommand.run(["investigating", "#8524"], ctx)).toBe(0);
  expect(pauseFlag.flag?.reason).toBe("investigating #8524");
  expect(io.outLines[0]).toBe("✓ paused: investigating #8524");
});

test("pause without a reason uses a default", async () => {
  const pauseFlag = new MemoryPauseFlag();
  await pauseCommand.run([], commandContext(captureIO(), fakeSafetyPorts({ pauseFlag })));
  expect(pauseFlag.flag?.reason).toBe("paused with shipwright pause");
});

test("resume clears the flag and reminds about the label", async () => {
  const pauseFlag = new MemoryPauseFlag({ reason: "x", since: "", resumeAfter: null });
  const io = captureIO();
  expect(await resumeCommand.run([], commandContext(io, fakeSafetyPorts({ pauseFlag })))).toBe(0);
  expect(pauseFlag.flag).toBeNull();
  expect(io.outLines).toEqual([
    "✓ local pause flag cleared",
    "  A shipwright:pause label on any open issue still pauses dispatch everywhere.",
  ]);
});

test("paused exits 0 with reasons when paused, 1 when not", async () => {
  const io = captureIO();
  const labelled = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([5])) });
  expect(await pausedCommand.run([], commandContext(io, labelled))).toBe(0);
  expect(io.outLines).toEqual(["paused: label shipwright:pause on #5"]);
  const clear = captureIO();
  expect(await pausedCommand.run([], commandContext(clear, fakeSafetyPorts()))).toBe(1);
  expect(clear.outLines).toEqual(["not paused"]);
});

test("paused --no-github ignores the label", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([5])) });
  expect(await pausedCommand.run(["--no-github"], commandContext(captureIO(), ports))).toBe(1);
});

test("paused fails closed: an unreadable source counts as paused (exit 0)", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(err({ kind: "auth", message: "x" })) });
  expect(await pausedCommand.run([], commandContext(io, ports))).toBe(0);
  expect(io.errLines).toEqual(["✗ pause: cannot verify (auth): x"]);
});

test.each([
  [resumeCommand, ["extra"]],
  [pausedCommand, ["--bogus"]],
])("bad arguments exit 2", async (command, args) => {
  expect(await command.run(args, commandContext(captureIO()))).toBe(2);
});
```

```bash
bun test ./src/cli/commands/pause.test.ts
```

Expected: FAIL — `error: Cannot find module './pause' from '…/pause.test.ts'`.

- [ ] **Step 2: Implement `src/cli/commands/pause.ts`**

```ts
import { pause, readPause, resume } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const pauseUsage = `USAGE
  shipwright pause [REASON...]

DESCRIPTION
  Kill switch (spec §6.2, ADR-0007): sets the local pause flag (~/.shipwright/daemon-pause.flag,
  shared with the bash daemon). No dispatch happens on this machine until \`shipwright resume\`.
  To stop every machine and CI, add the shipwright:pause label to any open issue.

EXAMPLES
  shipwright pause investigating the 2026-10-13 failure loop`;

const resumeUsage = `USAGE
  shipwright resume

DESCRIPTION
  Clears the local pause flag. A shipwright:pause label on an open issue still pauses dispatch.`;

const pausedUsage = `USAGE
  shipwright paused [--no-github]

DESCRIPTION
  Exits 0 when dispatch is paused (local flag or shipwright:pause label), 1 when it is not.
  Fails closed: when the flag or the label cannot be read, it reports paused (exit 0).

OPTIONS
  --no-github   Check only the local flag

EXAMPLES
  shipwright paused || dispatch_next_issue`;

export const pauseCommand: Command = {
  name: "pause",
  aliases: [],
  summary: "Kill switch: pause dispatch on this machine",
  usage: pauseUsage,
  async run(args, { io, safety }) {
    if (isHelp(args[0])) {
      io.out(pauseUsage);
      return 0;
    }
    const reason = args.join(" ").trim() || "paused with shipwright pause";
    const r = await pause(safety(), reason);
    if (!r.ok) return adapterFailure(io, "pause", r.error);
    io.out(`✓ paused: ${reason}`);
    return 0;
  },
};

export const resumeCommand: Command = {
  name: "resume",
  aliases: [],
  summary: "Clear the local pause flag",
  usage: resumeUsage,
  async run(args, { io, safety }) {
    if (isHelp(args[0])) {
      io.out(resumeUsage);
      return 0;
    }
    if (args.length > 0) return usageError(io, resumeUsage, `Unknown arguments: ${args.join(" ")}`);
    const r = await resume(safety());
    if (!r.ok) return adapterFailure(io, "resume", r.error);
    io.out("✓ local pause flag cleared");
    io.out("  A shipwright:pause label on any open issue still pauses dispatch everywhere.");
    return 0;
  },
};

export const pausedCommand: Command = {
  name: "paused",
  aliases: [],
  summary: "Exit 0 when dispatch is paused (flag or label), 1 when not",
  usage: pausedUsage,
  async run(args, { io, safety }) {
    if (isHelp(args[0])) {
      io.out(pausedUsage);
      return 0;
    }
    const github = !args.includes("--no-github");
    if (args.some((a) => a !== "--no-github")) {
      return usageError(io, pausedUsage, `Unknown arguments: ${args.join(" ")}`);
    }
    const r = await readPause(safety(), { github });
    if (!r.ok) {
      adapterFailure(io, "pause", r.error);
      return 0; // fail closed: an unknown pause state counts as paused
    }
    io.out(r.value.paused ? `paused: ${r.value.reasons.join("; ")}` : "not paused");
    return r.value.paused ? 0 : 1;
  },
};
```

- [ ] **Step 3: Register them — replace `src/cli/commands/index.ts` with**

```ts
import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { helloCommand } from "./hello";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
```

```bash
bun test ./src/cli/commands/pause.test.ts
```

Expected: `8 pass`, `0 fail`.

- [ ] **Step 4: Route them in `scripts/sw`**

In `scripts/sw`, replace:

```text
        breaker)
            run_ts breaker "$@"
            ;;
```

with:

```text
        breaker)
            run_ts breaker "$@"
            ;;
        pause)
            run_ts pause "$@"
            ;;
        resume)
            run_ts resume "$@"
            ;;
        paused)
            run_ts paused "$@"
            ;;
```

- [ ] **Step 5: Add the progress entries**

In `docs/plans/port/progress.json`, replace the end of the file:

```json
    "notes": "New in Wave 1a (spec §6.2 global circuit breaker); no bash predecessor."
  }
]
```

with:

```json
    "notes": "New in Wave 1a (spec §6.2 global circuit breaker); no bash predecessor."
  },
  {
    "command": "pause",
    "aliases": [],
    "script": "sw-pause.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a (spec §6.2 kill switch); writes the daemon's existing pause flag."
  },
  {
    "command": "resume",
    "aliases": [],
    "script": "sw-resume.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a (spec §6.2 kill switch); clears the daemon's pause flag."
  },
  {
    "command": "paused",
    "aliases": [],
    "script": "sw-paused.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a (spec §6.2 kill switch); exit 0 when paused, for scripts."
  }
]
```

- [ ] **Step 6: Regenerate the reference and try it in a temporary HOME**

```bash
bun run docs:gen
T=$(mktemp -d)
HOME=$T bun src/cli.ts pause testing the kill switch
HOME=$T bun src/cli.ts paused --no-github; echo "exit=$?"
cat "$T/.shipwright/daemon-pause.flag"
HOME=$T bun src/cli.ts resume
HOME=$T bun src/cli.ts paused --no-github; echo "exit=$?"
```

Expected: `✓ paused: testing the kill switch`; `paused: local pause flag: testing the kill switch (since …)` and `exit=0`; the flag JSON `{"reason":"testing the kill switch","timestamp":"…","source":"shipwright pause"}`; `✓ local pause flag cleared` plus the label reminder; `not paused` and `exit=1`.

- [ ] **Step 7: Run the definition of done**

```bash
bun run format && git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 8: Commit**

```bash
git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md
git commit -m "feat(cli): shipwright pause, resume and paused"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 8: Pre-dispatch budget guard

**Files:**
- Create: `src/contexts/orchestration/domain/budget.ts`, `src/contexts/orchestration/application/budget.ts`, `src/adapters/state/json-cost-ledger.ts`, `src/cli/commands/budget.ts`
- Modify: `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts`, `src/testing/fake-safety-ports.ts`, `src/main.ts`, `src/cli/commands/index.ts`, `scripts/sw`, `docs/plans/port/progress.json`, `docs/reference/cli.md`
- Test: `src/contexts/orchestration/domain/budget.test.ts`, `src/contexts/orchestration/application/budget.test.ts`, `src/adapters/state/json-cost-ledger.test.ts`, `src/cli/commands/budget.test.ts`

State-format compatibility: `scripts/sw-cost.sh` always dual-writes `~/.shipwright/costs.json` (`entries[]` with `cost_usd`, `ts_epoch`; last 1000 kept) and `budget.json` (`daily_budget_usd`, `enabled`) next to the SQLite db, so the adapter reads only those JSON files, read-only. Today is the UTC calendar day, as in `cost_check_budget`. Blocking at `spent + estimate >= cap` matches the daemon's existing `remaining <= 0` skip. A corrupt `budget.json` is an error (blocks); malformed cost entries are skipped, like the jq sums.

- [ ] **Step 1: Write the failing domain test**

```ts
import { expect, test } from "bun:test";
import { type CostEntry, evaluateBudget, utcDayStartEpochS } from "./budget";

const NOW = Date.parse("2026-10-14T15:30:00Z");
const TODAY = Date.parse("2026-10-14T00:00:00Z") / 1000;
const spent = (usd: number, epochS: number): CostEntry => ({ costUsd: usd, atEpochS: epochS });

test("today starts at UTC midnight, like sw-cost.sh", () => {
  expect(utcDayStartEpochS(NOW)).toBe(TODAY);
});

test("no cap configured is unlimited", () => {
  expect(evaluateBudget(null, [spent(500, TODAY)], NOW)).toEqual({
    allowed: true,
    limitUsd: null,
    spentTodayUsd: 500,
    remainingUsd: null,
  });
});

test("only today's entries count against the cap", () => {
  const entries = [spent(4, TODAY - 1), spent(2.5, TODAY), spent(1.25, TODAY + 3600)];
  expect(evaluateBudget({ limitUsd: 10 }, entries, NOW)).toEqual({
    allowed: true,
    limitUsd: 10,
    spentTodayUsd: 3.75,
    remainingUsd: 6.25,
  });
});

test("spend at or over the cap blocks; so does an estimate that would cross it", () => {
  expect(evaluateBudget({ limitUsd: 10 }, [spent(10, TODAY)], NOW).allowed).toBe(false);
  expect(evaluateBudget({ limitUsd: 10 }, [spent(8, TODAY)], NOW, 2).allowed).toBe(false);
  expect(evaluateBudget({ limitUsd: 10 }, [spent(8, TODAY)], NOW, 1.99).allowed).toBe(true);
});
```

```bash
bun test ./src/contexts/orchestration/domain/budget.test.ts
```

Expected: FAIL — `error: Cannot find module './budget' from '…/budget.test.ts'`.

- [ ] **Step 2: Implement `src/contexts/orchestration/domain/budget.ts`**

```ts
// Pre-dispatch budget guard (spec §6.2). Same arithmetic as scripts/sw-cost.sh: today is the UTC
// calendar day, and a cap of 0 or a disabled budget means unlimited.

export interface CostEntry {
  readonly costUsd: number;
  readonly atEpochS: number;
}

export interface DailyBudget {
  readonly limitUsd: number;
}

export interface BudgetVerdict {
  readonly allowed: boolean;
  /** `null` when no daily cap is configured. */
  readonly limitUsd: number | null;
  readonly spentTodayUsd: number;
  readonly remainingUsd: number | null;
}

export function utcDayStartEpochS(nowMs: number): number {
  const d = new Date(nowMs);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) / 1000;
}

/** Blocks when today's spend plus `estimateUsd` reaches the cap (the daemon's `remaining <= 0`). */
export function evaluateBudget(
  budget: DailyBudget | null,
  entries: readonly CostEntry[],
  nowMs: number,
  estimateUsd = 0,
): BudgetVerdict {
  const since = utcDayStartEpochS(nowMs);
  const spentTodayUsd = entries
    .filter((e) => e.atEpochS >= since)
    .reduce((sum, e) => sum + e.costUsd, 0);
  if (budget === null) {
    return { allowed: true, limitUsd: null, spentTodayUsd, remainingUsd: null };
  }
  return {
    allowed: spentTodayUsd + estimateUsd < budget.limitUsd,
    limitUsd: budget.limitUsd,
    spentTodayUsd,
    remainingUsd: budget.limitUsd - spentTodayUsd,
  };
}

const usd = (n: number) => `$${n.toFixed(2)}`;

export function describeBudget(v: BudgetVerdict): string {
  if (v.limitUsd === null || v.remainingUsd === null) {
    const spent = usd(v.spentTodayUsd);
    return `no daily cap (${spent} spent today); set one with: shipwright cost budget set <usd>`;
  }
  const left = usd(Math.max(0, v.remainingUsd));
  return `${usd(v.spentTodayUsd)} of ${usd(v.limitUsd)} spent today (UTC); ${left} left`;
}
```

```bash
bun test ./src/contexts/orchestration/domain/budget.test.ts
```

Expected: `4 pass`, `0 fail`.

- [ ] **Step 3: Replace `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts` and `src/testing/fake-safety-ports.ts`**

`src/contexts/orchestration/ports.ts`:

```ts
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { GithubWriter } from "../integrations";
import type { RunRecord } from "./domain/breaker";
import type { CostEntry, DailyBudget } from "./domain/budget";
import type { LocalPause } from "./domain/pause";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}

/** The local pause flag file the bash daemon also reads (`~/.shipwright/daemon-pause.flag`). */
export interface PauseFlag {
  /** `null` when no flag is set. */
  read(): Promise<Result<LocalPause | null, AdapterError>>;
  write(reason: string, at: string): Promise<Result<void, AdapterError>>;
  /** Idempotent: clearing an absent flag is ok. */
  clear(): Promise<Result<void, AdapterError>>;
}

/** Open issues carrying the `shipwright:pause` label. */
export interface PauseLabel {
  labelled(): Promise<Result<readonly number[], AdapterError>>;
}

/** Spend and the daily cap, as recorded by `shipwright cost` (read-only). */
export interface CostLedger {
  /** `budget` is null when no cap is enabled. */
  read(): Promise<
    Result<
      { readonly budget: DailyBudget | null; readonly entries: readonly CostEntry[] },
      AdapterError
    >
  >;
}

/** Everything the safety gates read or write, wired in src/main.ts. */
export interface SafetyPorts {
  readonly now: () => number;
  readonly runs: RunHistory;
  readonly pauseFlag: PauseFlag;
  readonly pauseLabel: PauseLabel;
  readonly github: GithubWriter;
  readonly costs: CostLedger;
}
```

`src/contexts/orchestration/index.ts`:

```ts
export {
  type BreakerReport,
  breakerStatus,
  checkBreaker,
  RUN_HISTORY_LIMIT,
} from "./application/breaker";
export { checkBudget } from "./application/budget";
export { type PauseOptions, pause, readPause, resume } from "./application/pause";
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export {
  type BudgetVerdict,
  type CostEntry,
  type DailyBudget,
  describeBudget,
  evaluateBudget,
} from "./domain/budget";
export { type LocalPause, PAUSE_LABEL, type PauseStatus, pauseStatus } from "./domain/pause";
export type {
  CostLedger,
  PauseFlag,
  PauseLabel,
  RunHistory,
  SafetyPorts,
} from "./ports";
```

`src/testing/fake-safety-ports.ts`:

```ts
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../contexts/integrations";
import type {
  CostEntry,
  CostLedger,
  DailyBudget,
  LocalPause,
  PauseFlag,
  PauseLabel,
  RunHistory,
  RunRecord,
  SafetyPorts,
} from "../contexts/orchestration";
import type { IdempotencyKey } from "../shared/kernel/durability";
import type { AdapterError } from "../shared/kernel/ports";
import { ok, type Result } from "../shared/kernel/result";

export const NOW = Date.parse("2026-10-14T12:00:00Z");

export class MemoryPauseFlag implements PauseFlag {
  constructor(public flag: LocalPause | null = null) {}
  async read() {
    return ok(this.flag);
  }
  async write(reason: string, at: string) {
    this.flag = { reason, since: at, resumeAfter: null };
    return ok(undefined);
  }
  async clear() {
    this.flag = null;
    return ok(undefined);
  }
}

export class RecordingGithubWriter implements GithubWriter {
  readonly calls: { key: IdempotencyKey; report: IncidentReport }[] = [];
  constructor(
    private readonly result: Result<IncidentOutcome, AdapterError> = ok({
      issue: 900,
      action: "created",
    }),
  ) {}
  async ensureIncident(key: IdempotencyKey, report: IncidentReport) {
    this.calls.push({ key, report });
    return this.result;
  }
}

export const fixedRuns = (r: Result<readonly RunRecord[], AdapterError>): RunHistory => ({
  recentRuns: async () => r,
});
export const fixedLabel = (r: Result<readonly number[], AdapterError>): PauseLabel => ({
  labelled: async () => r,
});

export const fixedCosts = (
  budget: DailyBudget | null,
  entries: readonly CostEntry[] = [],
): CostLedger => ({ read: async () => ok({ budget, entries }) });

/** Safety ports with harmless defaults: nothing running, paused, capped or awaiting review. */
export function fakeSafetyPorts(over: Partial<SafetyPorts> = {}): SafetyPorts {
  return {
    now: () => NOW,
    runs: fixedRuns(ok([])),
    pauseFlag: new MemoryPauseFlag(),
    pauseLabel: fixedLabel(ok([])),
    github: new RecordingGithubWriter(),
    costs: fixedCosts(null),
    ...over,
  };
}
```

- [ ] **Step 4: Write the failing use-case test, then implement it**

```ts
import { expect, test } from "bun:test";
import { err } from "../../../shared/kernel/result";
import { fakeSafetyPorts, fixedCosts, NOW } from "../../../testing/fake-safety-ports";
import { checkBudget } from "./budget";

const today = Math.floor(NOW / 1000);

test("checks today's spend plus the estimate against the cap", async () => {
  const costs = fixedCosts({ limitUsd: 5 }, [{ costUsd: 4, atEpochS: today }]);
  const ports = fakeSafetyPorts({ costs });
  expect(await checkBudget(ports, 0)).toEqual({
    ok: true,
    value: { allowed: true, limitUsd: 5, spentTodayUsd: 4, remainingUsd: 1 },
  });
  const over = await checkBudget(ports, 1);
  expect(over.ok && over.value.allowed).toBe(false);
});

test("an unreadable ledger is an error (callers fail closed)", async () => {
  const costs = { read: async () => err({ kind: "failed" as const, message: "bad json" }) };
  expect((await checkBudget(fakeSafetyPorts({ costs }), 0)).ok).toBe(false);
});
```

```bash
bun test ./src/contexts/orchestration/application/budget.test.ts
```

Expected: FAIL — `error: Cannot find module './budget' from '…/budget.test.ts'`.

`src/contexts/orchestration/application/budget.ts`:

```ts
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { type BudgetVerdict, evaluateBudget } from "../domain/budget";
import type { SafetyPorts } from "../ports";

export async function checkBudget(
  ports: Pick<SafetyPorts, "costs" | "now">,
  estimateUsd: number,
): Promise<Result<BudgetVerdict, AdapterError>> {
  const ledger = await ports.costs.read();
  if (!ledger.ok) return ledger;
  return ok(evaluateBudget(ledger.value.budget, ledger.value.entries, ports.now(), estimateUsd));
}
```

```bash
bun test ./src/contexts/orchestration/application/budget.test.ts
```

Expected: `2 pass`, `0 fail`.

- [ ] **Step 5: Write the failing ledger test, then implement it**

```ts
import { afterEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { JsonCostLedger } from "./json-cost-ledger";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());
const write = (name: string, json: unknown) =>
  writeFileSync(join((env as TestEnv).stateDir, name), JSON.stringify(json));

test("missing files mean no cap and no spend", async () => {
  env = createTestEnv();
  expect(await new JsonCostLedger(env.stateDir).read()).toEqual({
    ok: true,
    value: { budget: null, entries: [] },
  });
});

test("reads the files sw-cost.sh writes", async () => {
  env = createTestEnv();
  write("budget.json", { daily_budget_usd: 25, enabled: true });
  write("costs.json", {
    entries: [
      {
        input_tokens: 1,
        output_tokens: 2,
        model: "opus",
        stage: "build",
        issue: "42",
        cost_usd: 1.5,
        ts: "t",
        ts_epoch: 1760400000,
      },
      { cost_usd: "oops", ts_epoch: 1760400001 },
    ],
    summary: {},
  });
  expect(await new JsonCostLedger(env.stateDir).read()).toEqual({
    ok: true,
    value: { budget: { limitUsd: 25 }, entries: [{ costUsd: 1.5, atEpochS: 1760400000 }] },
  });
});

test.each([[{ daily_budget_usd: 25, enabled: false }], [{ daily_budget_usd: 0, enabled: true }]])(
  "a disabled or zero budget (%p) is no cap",
  async (budget) => {
    env = createTestEnv();
    write("budget.json", budget);
    const r = await new JsonCostLedger(env.stateDir).read();
    expect(r.ok && r.value.budget).toBeNull();
  },
);

test("a corrupt budget file is an error, not 'unlimited'", async () => {
  env = createTestEnv();
  writeFileSync(join(env.stateDir, "budget.json"), "{not json");
  const r = await new JsonCostLedger(env.stateDir).read();
  expect(!r.ok && r.error.kind).toBe("failed");
});
```

```bash
bun test ./src/adapters/state/json-cost-ledger.test.ts
```

Expected: FAIL — `error: Cannot find module './json-cost-ledger' from '…/json-cost-ledger.test.ts'`.

`src/adapters/state/json-cost-ledger.ts`:

```ts
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import type { CostEntry, CostLedger, DailyBudget } from "../../contexts/orchestration";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

// Formats written by scripts/sw-cost.sh (always dual-written next to the SQLite db).
const BudgetFile = z.object({ daily_budget_usd: z.number(), enabled: z.boolean() });
const CostsFile = z.object({ entries: z.array(z.unknown()) });
const Entry = z.object({ cost_usd: z.number(), ts_epoch: z.number() });

type Read = Result<unknown | null, AdapterError>;

async function readJson(path: string): Promise<Read> {
  try {
    return ok(JSON.parse(await readFile(path, "utf8")));
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") return ok(null);
    return err({
      kind: "failed",
      message: `${path}: ${e instanceof Error ? e.message : String(e)}`,
    });
  }
}

function toBudget(json: unknown, path: string): Result<DailyBudget | null, AdapterError> {
  if (json === null) return ok(null);
  const b = BudgetFile.safeParse(json);
  if (!b.success) return err({ kind: "failed", message: `${path}: ${b.error.message}` });
  const on = b.data.enabled && b.data.daily_budget_usd > 0;
  return ok(on ? { limitUsd: b.data.daily_budget_usd } : null);
}

/** Malformed entries are skipped, as sw-cost.sh's jq sums skip them. */
function toEntries(json: unknown): CostEntry[] {
  const file = CostsFile.safeParse(json);
  if (!file.success) return [];
  return file.data.entries.flatMap((raw) => {
    const e = Entry.safeParse(raw);
    return e.success ? [{ costUsd: e.data.cost_usd, atEpochS: e.data.ts_epoch }] : [];
  });
}

/** Reads `costs.json` and `budget.json` from the bash cost directory (`~/.shipwright`). */
export class JsonCostLedger implements CostLedger {
  constructor(private readonly dir: string) {}

  async read() {
    const budgetPath = join(this.dir, "budget.json");
    const [budgetJson, costsJson] = await Promise.all([
      readJson(budgetPath),
      readJson(join(this.dir, "costs.json")),
    ]);
    if (!budgetJson.ok) return budgetJson;
    if (!costsJson.ok) return costsJson;
    const budget = toBudget(budgetJson.value, budgetPath);
    if (!budget.ok) return budget;
    return ok({ budget: budget.value, entries: toEntries(costsJson.value) });
  }
}
```

```bash
bun test ./src/adapters/state/json-cost-ledger.test.ts
```

Expected: `5 pass`, `0 fail`.

- [ ] **Step 6: Wire it in `src/main.ts`**

In `src/main.ts`, replace:

```ts
import { FilePauseFlag } from "./adapters/state/file-pause-flag";
```

with:

```ts
import { FilePauseFlag } from "./adapters/state/file-pause-flag";
import { JsonCostLedger } from "./adapters/state/json-cost-ledger";
```

In `src/main.ts`, replace:

```ts
    github: new GhGithubWriter(runner),
  };
```

with:

```ts
    github: new GhGithubWriter(runner),
    costs: new JsonCostLedger(legacyDir),
  };
```

- [ ] **Step 7: Write the failing command test**

```ts
import { expect, test } from "bun:test";
import { err } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedCosts, NOW } from "../../testing/fake-safety-ports";
import { budgetCommand } from "./budget";

const today = Math.floor(NOW / 1000);
const ports = (spentUsd: number) =>
  fakeSafetyPorts({
    costs: fixedCosts({ limitUsd: 10 }, [{ costUsd: spentUsd, atEpochS: today }]),
  });

test("check exits 0 under the cap", async () => {
  const io = captureIO();
  expect(await budgetCommand.run(["check"], commandContext(io, ports(3.2)))).toBe(0);
  expect(io.outLines).toEqual(["✓ budget: $3.20 of $10.00 spent today (UTC); $6.80 left"]);
});

test("check exits 1 at the cap, and when an estimate would cross it", async () => {
  expect(await budgetCommand.run(["check"], commandContext(captureIO(), ports(10)))).toBe(1);
  const io = captureIO();
  const args = ["check", "--estimate", "7"];
  expect(await budgetCommand.run(args, commandContext(io, ports(3.2)))).toBe(1);
  expect(io.outLines).toEqual(["✗ budget: $3.20 of $10.00 spent today (UTC); $6.80 left"]);
});

test("no cap is allowed and says how to set one", async () => {
  const io = captureIO();
  expect(await budgetCommand.run(["status"], commandContext(io, fakeSafetyPorts()))).toBe(0);
  expect(io.outLines).toEqual([
    "✓ budget: no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
  ]);
});

test("status exits 0 even when over the cap", async () => {
  expect(await budgetCommand.run(["status"], commandContext(captureIO(), ports(12)))).toBe(0);
});

test("an unreadable ledger blocks (exit 1)", async () => {
  const costs = { read: async () => err({ kind: "failed" as const, message: "bad json" }) };
  const io = captureIO();
  expect(await budgetCommand.run(["check"], commandContext(io, fakeSafetyPorts({ costs })))).toBe(
    1,
  );
  expect(io.errLines).toEqual(["✗ budget: cannot verify (failed): bad json"]);
});

test.each([[[]], [["check", "--estimate"]], [["check", "--estimate", "-1"]], [["spend"]]])(
  "bad arguments %p exit 2",
  async (args) => {
    expect(await budgetCommand.run(args, commandContext(captureIO()))).toBe(2);
  },
);
```

```bash
bun test ./src/cli/commands/budget.test.ts
```

Expected: FAIL — `error: Cannot find module './budget' from '…/budget.test.ts'`.

- [ ] **Step 8: Implement `src/cli/commands/budget.ts` and register it**

```ts
import { checkBudget, describeBudget } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright budget <status|check> [--estimate USD]

DESCRIPTION
  Pre-dispatch budget guard (spec §6.2, ADR-0007). Reads the daily cap and today's spend (UTC)
  from ~/.shipwright/budget.json and costs.json, written by \`shipwright cost\`.

COMMANDS
  status   Print today's spend against the cap. Exits 0.
  check    Exit 0 when today's spend plus the estimate stays under the cap, 1 when it does not
           or the files cannot be read. No cap configured means unlimited.

OPTIONS
  --estimate USD   Expected cost of the next run (default 0)

EXAMPLES
  shipwright budget check --estimate 2.50`;

/** The --estimate value, 0 when absent, or null when malformed. */
function parseEstimate(rest: readonly string[]): number | null {
  if (rest.length === 0) return 0;
  if (rest.length !== 2 || rest[0] !== "--estimate") return null;
  const n = Number(rest[1]);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

export const budgetCommand: Command = {
  name: "budget",
  aliases: [],
  summary: "Daily budget guard: show it, or check it as a dispatch gate",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelp(sub)) {
      io.out(usage);
      return 0;
    }
    const estimate = parseEstimate(rest);
    if ((sub !== "status" && sub !== "check") || estimate === null) {
      return usageError(
        io,
        usage,
        `Expected status or check [--estimate USD], got: ${args.join(" ") || "nothing"}`,
      );
    }
    const r = await checkBudget(safety(), estimate);
    if (!r.ok) return adapterFailure(io, "budget", r.error);
    io.out(`${r.value.allowed ? "✓" : "✗"} budget: ${describeBudget(r.value)}`);
    return sub === "check" && !r.value.allowed ? 1 : 0;
  },
};
```

Replace `src/cli/commands/index.ts` with:

```ts
import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { helloCommand } from "./hello";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
  budgetCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
```

```bash
bun test ./src/cli/commands/budget.test.ts
```

Expected: `9 pass`, `0 fail`.

- [ ] **Step 9: Route, progress entry, reference**

In `scripts/sw`, replace:

```text
        paused)
            run_ts paused "$@"
            ;;
```

with:

```text
        paused)
            run_ts paused "$@"
            ;;
        budget)
            run_ts budget "$@"
            ;;
```

In `docs/plans/port/progress.json`, replace the end of the file:

```json
    "notes": "New in Wave 1a (spec §6.2 kill switch); exit 0 when paused, for scripts."
  }
]
```

with:

```json
    "notes": "New in Wave 1a (spec §6.2 kill switch); exit 0 when paused, for scripts."
  },
  {
    "command": "budget",
    "aliases": [],
    "script": "sw-budget.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a (spec §6.2 budget guard); reads the files sw-cost.sh writes."
  }
]
```

```bash
bun run docs:gen
T=$(mktemp -d); mkdir -p "$T/.shipwright"
echo '{"daily_budget_usd":5,"enabled":true}' > "$T/.shipwright/budget.json"
echo "{\"entries\":[{\"cost_usd\":6,\"ts_epoch\":$(date +%s)}]}" > "$T/.shipwright/costs.json"
HOME=$T bun src/cli.ts budget check; echo "exit=$?"
```

Expected: `✗ budget: $6.00 of $5.00 spent today (UTC); $0.00 left` and `exit=1`.

- [ ] **Step 10: Run the definition of done**

```bash
bun run format && git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 11: Commit**

```bash
git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md
git commit -m "feat(orchestration): pre-dispatch budget guard"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 9: Review-WIP limit and fix-loop cap

**Files:**
- Create: `src/contexts/orchestration/domain/flow.ts`, `src/adapters/github/gh-pull-requests.ts`
- Modify: `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts`, `src/testing/fake-safety-ports.ts`, `src/main.ts`
- Test: `src/contexts/orchestration/domain/flow.test.ts`, `src/adapters/github/gh-pull-requests.test.ts`

Review WIP counts agent PRs awaiting a human *plus* pipeline runs already queued or running, because each of those will open another PR; counting PRs alone would let one dispatch run start dozens of pipelines before any PR exists. Agent PRs today are authored by `app/github-actions` (CI pipeline) or carry the `shipwright` label the pipeline copies from the issue (local daemon runs). These gates have no command of their own; `shipwright gates` (Task 11) runs them.

- [ ] **Step 1: Write the failing domain test**

```ts
import { expect, test } from "bun:test";
import { DEFAULT_FLOW_POLICY, fixLoopAllows, type PullSummary, reviewWip } from "./flow";

const pr = (number: number, over: Partial<PullSummary> = {}): PullSummary => ({
  number,
  author: "app/github-actions",
  labels: [],
  draft: false,
  approved: false,
  ...over,
});
const policy = { ...DEFAULT_FLOW_POLICY, reviewWipLimit: 3 };

test("counts agent PRs awaiting review plus runs that will open more", () => {
  const pulls = [
    pr(1),
    pr(2, { author: "sethdford", labels: ["shipwright"] }),
    pr(3, { author: "sethdford" }),
    pr(4, { author: "app/dependabot" }),
    pr(5, { draft: true }),
    pr(6, { approved: true }),
  ];
  expect(reviewWip(pulls, 0, policy)).toEqual({
    allowed: true,
    awaitingReview: [1, 2],
    inFlight: 0,
    limit: 3,
  });
  expect(reviewWip(pulls, 1, policy)).toMatchObject({ allowed: false, inFlight: 1 });
});

test("the default limit is 5", () => {
  const four = [pr(1), pr(2), pr(3), pr(4)];
  expect(reviewWip(four, 0, DEFAULT_FLOW_POLICY).allowed).toBe(true);
  expect(reviewWip([...four, pr(5)], 0, DEFAULT_FLOW_POLICY).allowed).toBe(false);
});

test("the fix loop allows attempts 1-3 and stops the 4th", () => {
  expect(fixLoopAllows(null, DEFAULT_FLOW_POLICY)).toBe(true);
  expect(fixLoopAllows(3, DEFAULT_FLOW_POLICY)).toBe(true);
  expect(fixLoopAllows(4, DEFAULT_FLOW_POLICY)).toBe(false);
});
```

```bash
bun test ./src/contexts/orchestration/domain/flow.test.ts
```

Expected: FAIL — `error: Cannot find module './flow' from '…/flow.test.ts'`.

- [ ] **Step 2: Implement `src/contexts/orchestration/domain/flow.ts`**

```ts
// Flow control (spec §6.2, research decision 11): a review-WIP limit and a fix-loop cap.

export interface PullSummary {
  readonly number: number;
  /** gh login, e.g. "app/github-actions" for the Actions bot. */
  readonly author: string;
  readonly labels: readonly string[];
  readonly draft: boolean;
  readonly approved: boolean;
}

export interface FlowPolicy {
  /** No dispatch while this many agent PRs await review or are being produced. */
  readonly reviewWipLimit: number;
  /** PRs by these authors are agent PRs. */
  readonly agentAuthors: readonly string[];
  /** PRs with this label (propagated from dispatched issues) are agent PRs. */
  readonly agentLabel: string;
  /** Retries of one issue allowed before it escalates to a human. */
  readonly fixLoopCap: number;
}

export const DEFAULT_FLOW_POLICY: FlowPolicy = {
  reviewWipLimit: 5,
  agentAuthors: ["app/github-actions"],
  agentLabel: "shipwright",
  fixLoopCap: 3,
};

export interface WipVerdict {
  readonly allowed: boolean;
  /** Open, non-draft, unapproved agent PRs. */
  readonly awaitingReview: readonly number[];
  /** Pipeline runs queued or running; each may open another PR. */
  readonly inFlight: number;
  readonly limit: number;
}

const isAgentPr = (p: PullSummary, policy: FlowPolicy) =>
  policy.agentAuthors.includes(p.author) || p.labels.includes(policy.agentLabel);

export function reviewWip(
  pulls: readonly PullSummary[],
  inFlight: number,
  policy: FlowPolicy = DEFAULT_FLOW_POLICY,
): WipVerdict {
  const awaitingReview = pulls
    .filter((p) => isAgentPr(p, policy) && !p.draft && !p.approved)
    .map((p) => p.number);
  const allowed = awaitingReview.length + inFlight < policy.reviewWipLimit;
  return { allowed, awaitingReview, inFlight, limit: policy.reviewWipLimit };
}

export function describeWip(v: WipVerdict): string {
  const prs = `${v.awaitingReview.length} agent PRs awaiting review`;
  return `${prs} + ${v.inFlight} runs in flight (limit ${v.limit})`;
}

/** `attempt` is the retry number (1 = first retry); null for a first dispatch. */
export function fixLoopAllows(attempt: number | null, policy: FlowPolicy = DEFAULT_FLOW_POLICY) {
  return attempt === null || attempt <= policy.fixLoopCap;
}
```

```bash
bun test ./src/contexts/orchestration/domain/flow.test.ts
```

Expected: `3 pass`, `0 fail`.

- [ ] **Step 3: Replace `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts` and `src/testing/fake-safety-ports.ts`**

`src/contexts/orchestration/ports.ts`:

```ts
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { GithubWriter } from "../integrations";
import type { RunRecord } from "./domain/breaker";
import type { CostEntry, DailyBudget } from "./domain/budget";
import type { PullSummary } from "./domain/flow";
import type { LocalPause } from "./domain/pause";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}

/** The local pause flag file the bash daemon also reads (`~/.shipwright/daemon-pause.flag`). */
export interface PauseFlag {
  /** `null` when no flag is set. */
  read(): Promise<Result<LocalPause | null, AdapterError>>;
  write(reason: string, at: string): Promise<Result<void, AdapterError>>;
  /** Idempotent: clearing an absent flag is ok. */
  clear(): Promise<Result<void, AdapterError>>;
}

/** Open issues carrying the `shipwright:pause` label. */
export interface PauseLabel {
  labelled(): Promise<Result<readonly number[], AdapterError>>;
}

/** Spend and the daily cap, as recorded by `shipwright cost` (read-only). */
export interface CostLedger {
  /** `budget` is null when no cap is enabled. */
  read(): Promise<
    Result<
      { readonly budget: DailyBudget | null; readonly entries: readonly CostEntry[] },
      AdapterError
    >
  >;
}

/** Open pull requests, for the review-WIP limit. */
export interface PullRequests {
  open(): Promise<Result<readonly PullSummary[], AdapterError>>;
}

/** Everything the safety gates read or write, wired in src/main.ts. */
export interface SafetyPorts {
  readonly now: () => number;
  readonly runs: RunHistory;
  readonly pauseFlag: PauseFlag;
  readonly pauseLabel: PauseLabel;
  readonly github: GithubWriter;
  readonly costs: CostLedger;
  readonly pulls: PullRequests;
}
```

`src/contexts/orchestration/index.ts`:

```ts
export {
  type BreakerReport,
  breakerStatus,
  checkBreaker,
  RUN_HISTORY_LIMIT,
} from "./application/breaker";
export { checkBudget } from "./application/budget";
export { type PauseOptions, pause, readPause, resume } from "./application/pause";
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export {
  type BudgetVerdict,
  type CostEntry,
  type DailyBudget,
  describeBudget,
  evaluateBudget,
} from "./domain/budget";
export {
  DEFAULT_FLOW_POLICY,
  describeWip,
  type FlowPolicy,
  fixLoopAllows,
  type PullSummary,
  reviewWip,
  type WipVerdict,
} from "./domain/flow";
export { type LocalPause, PAUSE_LABEL, type PauseStatus, pauseStatus } from "./domain/pause";
export type {
  CostLedger,
  PauseFlag,
  PauseLabel,
  PullRequests,
  RunHistory,
  SafetyPorts,
} from "./ports";
```

`src/testing/fake-safety-ports.ts`:

```ts
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../contexts/integrations";
import type {
  CostEntry,
  CostLedger,
  DailyBudget,
  LocalPause,
  PauseFlag,
  PauseLabel,
  PullRequests,
  PullSummary,
  RunHistory,
  RunRecord,
  SafetyPorts,
} from "../contexts/orchestration";
import type { IdempotencyKey } from "../shared/kernel/durability";
import type { AdapterError } from "../shared/kernel/ports";
import { ok, type Result } from "../shared/kernel/result";

export const NOW = Date.parse("2026-10-14T12:00:00Z");

export class MemoryPauseFlag implements PauseFlag {
  constructor(public flag: LocalPause | null = null) {}
  async read() {
    return ok(this.flag);
  }
  async write(reason: string, at: string) {
    this.flag = { reason, since: at, resumeAfter: null };
    return ok(undefined);
  }
  async clear() {
    this.flag = null;
    return ok(undefined);
  }
}

export class RecordingGithubWriter implements GithubWriter {
  readonly calls: { key: IdempotencyKey; report: IncidentReport }[] = [];
  constructor(
    private readonly result: Result<IncidentOutcome, AdapterError> = ok({
      issue: 900,
      action: "created",
    }),
  ) {}
  async ensureIncident(key: IdempotencyKey, report: IncidentReport) {
    this.calls.push({ key, report });
    return this.result;
  }
}

export const fixedRuns = (r: Result<readonly RunRecord[], AdapterError>): RunHistory => ({
  recentRuns: async () => r,
});
export const fixedLabel = (r: Result<readonly number[], AdapterError>): PauseLabel => ({
  labelled: async () => r,
});

export const fixedCosts = (
  budget: DailyBudget | null,
  entries: readonly CostEntry[] = [],
): CostLedger => ({ read: async () => ok({ budget, entries }) });

export const fixedPulls = (r: Result<readonly PullSummary[], AdapterError>): PullRequests => ({
  open: async () => r,
});

/** Safety ports with harmless defaults: nothing running, paused, capped or awaiting review. */
export function fakeSafetyPorts(over: Partial<SafetyPorts> = {}): SafetyPorts {
  return {
    now: () => NOW,
    runs: fixedRuns(ok([])),
    pauseFlag: new MemoryPauseFlag(),
    pauseLabel: fixedLabel(ok([])),
    github: new RecordingGithubWriter(),
    costs: fixedCosts(null),
    pulls: fixedPulls(ok([])),
    ...over,
  };
}
```

- [ ] **Step 4: Write the failing adapter test, then implement it**

```ts
import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhPullRequests } from "./gh-pull-requests";

test("lists open PRs as summaries", async () => {
  const stdout = JSON.stringify([
    {
      number: 6765,
      author: { is_bot: true, login: "app/github-actions" },
      labels: [{ name: "shipwright" }],
      isDraft: false,
      reviewDecision: "",
    },
    {
      number: 9,
      author: { login: "sethdford" },
      labels: [],
      isDraft: true,
      reviewDecision: "APPROVED",
    },
  ]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh", "pr", "list"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  expect(await new GhPullRequests(runner).open()).toEqual({
    ok: true,
    value: [
      {
        number: 6765,
        author: "app/github-actions",
        labels: ["shipwright"],
        draft: false,
        approved: false,
      },
      { number: 9, author: "sethdford", labels: [], draft: true, approved: true },
    ],
  });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "pr",
    "list",
    "--state",
    "open",
    "--limit",
    "200",
    "--json",
    "number,author,labels,isDraft,reviewDecision",
  ]);
});

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 401: Bad credentials" } },
  ]);
  const r = await new GhPullRequests(runner).open();
  expect(!r.ok && r.error.kind).toBe("auth");
});
```

```bash
bun test ./src/adapters/github/gh-pull-requests.test.ts
```

Expected: FAIL — `error: Cannot find module './gh-pull-requests' from '…/gh-pull-requests.test.ts'`.

`src/adapters/github/gh-pull-requests.ts`:

```ts
import { z } from "zod";
import type { PullRequests, PullSummary } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const GhPull = z.object({
  number: z.number(),
  author: z.object({ login: z.string() }),
  labels: z.array(z.object({ name: z.string() })),
  isDraft: z.boolean(),
  reviewDecision: z.string().nullable(),
});

export class GhPullRequests implements PullRequests {
  constructor(private readonly runner: ProcessRunner) {}

  async open(): Promise<Result<readonly PullSummary[], AdapterError>> {
    const argv = ["gh", "pr", "list", "--state", "open", "--limit", "200"];
    const fields = "number,author,labels,isDraft,reviewDecision";
    const r = await runGhJson(this.runner, [...argv, "--json", fields], z.array(GhPull));
    if (!r.ok) return r;
    return ok(
      r.value.map((p) => ({
        number: p.number,
        author: p.author.login,
        labels: p.labels.map((l) => l.name),
        draft: p.isDraft,
        approved: p.reviewDecision === "APPROVED",
      })),
    );
  }
}
```

```bash
bun test ./src/adapters/github/gh-pull-requests.test.ts
```

Expected: `2 pass`, `0 fail`.

- [ ] **Step 5: Wire it in `src/main.ts`**

In `src/main.ts`, replace:

```ts
import { GhPauseLabel } from "./adapters/github/gh-pause-label";
```

with:

```ts
import { GhPauseLabel } from "./adapters/github/gh-pause-label";
import { GhPullRequests } from "./adapters/github/gh-pull-requests";
```

In `src/main.ts`, replace:

```ts
    costs: new JsonCostLedger(legacyDir),
  };
```

with:

```ts
    costs: new JsonCostLedger(legacyDir),
    pulls: new GhPullRequests(runner),
  };
```

- [ ] **Step 6: Run the definition of done**

```bash
bun run format && git add -A src && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 7: Commit**

```bash
git add -A src
git commit -m "feat(orchestration): review-WIP limit and fix-loop cap"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 10: Issue intake caps

**Files:**
- Create: `src/contexts/orchestration/domain/intake.ts`, `src/contexts/orchestration/application/intake.ts`, `src/adapters/github/gh-open-issues.ts`, `src/cli/commands/intake.ts`
- Modify: `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts`, `src/testing/fake-safety-ports.ts`, `src/main.ts`, `src/cli/commands/index.ts`, `scripts/sw`, `docs/plans/port/progress.json`, `docs/reference/cli.md`
- Test: `src/contexts/orchestration/domain/intake.test.ts`, `src/contexts/orchestration/application/intake.test.ts`, `src/adapters/github/gh-open-issues.test.ts`, `src/cli/commands/intake.test.ts`

The minimal gate patrol consults before filing (Task 12 wires it): fewer than 25 open `auto-patrol` issues, and no open issue with the same title fingerprint. With ~790 auto-patrol issues open today, patrol files nothing until the backlog is triaged — the intended effect. Patrol itself is not ported (spec §7.5).

- [ ] **Step 1: Write the failing domain test**

```ts
import { expect, test } from "bun:test";
import { evaluateIntake, type IssueSummary, titleFingerprint } from "./intake";

const issue = (number: number, title: string, labels: string[] = []): IssueSummary => ({
  number,
  title,
  labels,
});
const policy = { autoLabel: "auto-patrol", maxOpenAuto: 2 };

test("fingerprints ignore case, numbers and punctuation", () => {
  expect(titleFingerprint("Security: lodash 4.17.20 in package-lock")).toBe(
    titleFingerprint("security — LODASH 4.17.21 in package_lock"),
  );
  expect(titleFingerprint("Decompose `sw-memory.sh`")).not.toBe(
    titleFingerprint("Decompose `sw-loop.sh`"),
  );
});

test("allows filing under the cap with no duplicate", () => {
  const open = [issue(1, "Flaky test in sw-loop", ["auto-patrol"])];
  expect(evaluateIntake(open, "Stale docs in README", policy)).toEqual({
    allowed: true,
    openAuto: 1,
    cap: 2,
    duplicateOf: null,
  });
});

test("blocks a near-duplicate of any open issue", () => {
  const open = [issue(8524, "Classify and cap duplicate build-loop errors (3 seen)")];
  expect(
    evaluateIntake(open, "classify and cap duplicate build loop errors (5 seen)", policy),
  ).toEqual({
    allowed: false,
    openAuto: 0,
    cap: 2,
    duplicateOf: 8524,
  });
});

test("blocks at the cap of open auto-filed issues, with or without a title", () => {
  const open = [issue(1, "a", ["auto-patrol"]), issue(2, "b", ["auto-patrol"]), issue(3, "c")];
  expect(evaluateIntake(open, null, policy)).toMatchObject({ allowed: false, openAuto: 2 });
  expect(evaluateIntake(open.slice(1), null, policy).allowed).toBe(true);
});
```

```bash
bun test ./src/contexts/orchestration/domain/intake.test.ts
```

Expected: FAIL — `error: Cannot find module './intake' from '…/intake.test.ts'`.

- [ ] **Step 2: Implement `src/contexts/orchestration/domain/intake.ts`**

```ts
// Issue intake caps (spec §6.2 "Patrol hygiene"): a cap on open auto-filed issues and an exact
// title-fingerprint dedupe. Semantic dedupe (a decide<T> call) replaces the fingerprint later.

export interface IssueSummary {
  readonly number: number;
  readonly title: string;
  readonly labels: readonly string[];
}

export interface IntakePolicy {
  /** Label that marks issues filed by automation (patrol). */
  readonly autoLabel: string;
  /** No new auto-filed issue while this many are open. */
  readonly maxOpenAuto: number;
}

export const DEFAULT_INTAKE_POLICY: IntakePolicy = { autoLabel: "auto-patrol", maxOpenAuto: 25 };

export interface IntakeVerdict {
  readonly allowed: boolean;
  readonly openAuto: number;
  readonly cap: number;
  /** An open issue with the same title fingerprint, if any. */
  readonly duplicateOf: number | null;
}

/** Lowercase, every run of digits as 0, everything but letters and digits as one space. */
export function titleFingerprint(title: string): string {
  return title
    .toLowerCase()
    .replace(/\d+/g, "0")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

export function evaluateIntake(
  open: readonly IssueSummary[],
  candidateTitle: string | null,
  policy: IntakePolicy = DEFAULT_INTAKE_POLICY,
): IntakeVerdict {
  const openAuto = open.filter((i) => i.labels.includes(policy.autoLabel)).length;
  const fingerprint = candidateTitle === null ? "" : titleFingerprint(candidateTitle);
  const duplicate = fingerprint
    ? open.find((i) => titleFingerprint(i.title) === fingerprint)
    : undefined;
  return {
    allowed: openAuto < policy.maxOpenAuto && duplicate === undefined,
    openAuto,
    cap: policy.maxOpenAuto,
    duplicateOf: duplicate?.number ?? null,
  };
}

export function describeIntake(v: IntakeVerdict): string {
  const count = `${v.openAuto} of ${v.cap} open auto-patrol issues`;
  if (v.duplicateOf !== null) return `${count}; duplicate of #${v.duplicateOf}`;
  return v.openAuto >= v.cap ? `${count} (cap reached)` : count;
}
```

```bash
bun test ./src/contexts/orchestration/domain/intake.test.ts
```

Expected: `4 pass`, `0 fail`.

- [ ] **Step 3: Replace `src/contexts/orchestration/ports.ts`, `src/contexts/orchestration/index.ts` and `src/testing/fake-safety-ports.ts`**

`src/contexts/orchestration/ports.ts`:

```ts
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { GithubWriter } from "../integrations";
import type { RunRecord } from "./domain/breaker";
import type { CostEntry, DailyBudget } from "./domain/budget";
import type { PullSummary } from "./domain/flow";
import type { IssueSummary } from "./domain/intake";
import type { LocalPause } from "./domain/pause";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}

/** The local pause flag file the bash daemon also reads (`~/.shipwright/daemon-pause.flag`). */
export interface PauseFlag {
  /** `null` when no flag is set. */
  read(): Promise<Result<LocalPause | null, AdapterError>>;
  write(reason: string, at: string): Promise<Result<void, AdapterError>>;
  /** Idempotent: clearing an absent flag is ok. */
  clear(): Promise<Result<void, AdapterError>>;
}

/** Open issues carrying the `shipwright:pause` label. */
export interface PauseLabel {
  labelled(): Promise<Result<readonly number[], AdapterError>>;
}

/** Spend and the daily cap, as recorded by `shipwright cost` (read-only). */
export interface CostLedger {
  /** `budget` is null when no cap is enabled. */
  read(): Promise<
    Result<
      { readonly budget: DailyBudget | null; readonly entries: readonly CostEntry[] },
      AdapterError
    >
  >;
}

/** Open pull requests, for the review-WIP limit. */
export interface PullRequests {
  open(): Promise<Result<readonly PullSummary[], AdapterError>>;
}

/** Open issues, for intake caps and dedupe. */
export interface OpenIssues {
  open(): Promise<Result<readonly IssueSummary[], AdapterError>>;
}

/** Everything the safety gates read or write, wired in src/main.ts. */
export interface SafetyPorts {
  readonly now: () => number;
  readonly runs: RunHistory;
  readonly pauseFlag: PauseFlag;
  readonly pauseLabel: PauseLabel;
  readonly github: GithubWriter;
  readonly costs: CostLedger;
  readonly pulls: PullRequests;
  readonly issues: OpenIssues;
}
```

`src/contexts/orchestration/index.ts`:

```ts
export {
  type BreakerReport,
  breakerStatus,
  checkBreaker,
  RUN_HISTORY_LIMIT,
} from "./application/breaker";
export { checkBudget } from "./application/budget";
export { checkIntake } from "./application/intake";
export { type PauseOptions, pause, readPause, resume } from "./application/pause";
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export {
  type BudgetVerdict,
  type CostEntry,
  type DailyBudget,
  describeBudget,
  evaluateBudget,
} from "./domain/budget";
export {
  DEFAULT_FLOW_POLICY,
  describeWip,
  type FlowPolicy,
  fixLoopAllows,
  type PullSummary,
  reviewWip,
  type WipVerdict,
} from "./domain/flow";
export {
  DEFAULT_INTAKE_POLICY,
  describeIntake,
  evaluateIntake,
  type IntakePolicy,
  type IntakeVerdict,
  type IssueSummary,
  titleFingerprint,
} from "./domain/intake";
export { type LocalPause, PAUSE_LABEL, type PauseStatus, pauseStatus } from "./domain/pause";
export type {
  CostLedger,
  OpenIssues,
  PauseFlag,
  PauseLabel,
  PullRequests,
  RunHistory,
  SafetyPorts,
} from "./ports";
```

`src/testing/fake-safety-ports.ts`:

```ts
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../contexts/integrations";
import type {
  CostEntry,
  CostLedger,
  DailyBudget,
  IssueSummary,
  LocalPause,
  OpenIssues,
  PauseFlag,
  PauseLabel,
  PullRequests,
  PullSummary,
  RunHistory,
  RunRecord,
  SafetyPorts,
} from "../contexts/orchestration";
import type { IdempotencyKey } from "../shared/kernel/durability";
import type { AdapterError } from "../shared/kernel/ports";
import { ok, type Result } from "../shared/kernel/result";

export const NOW = Date.parse("2026-10-14T12:00:00Z");

export class MemoryPauseFlag implements PauseFlag {
  constructor(public flag: LocalPause | null = null) {}
  async read() {
    return ok(this.flag);
  }
  async write(reason: string, at: string) {
    this.flag = { reason, since: at, resumeAfter: null };
    return ok(undefined);
  }
  async clear() {
    this.flag = null;
    return ok(undefined);
  }
}

export class RecordingGithubWriter implements GithubWriter {
  readonly calls: { key: IdempotencyKey; report: IncidentReport }[] = [];
  constructor(
    private readonly result: Result<IncidentOutcome, AdapterError> = ok({
      issue: 900,
      action: "created",
    }),
  ) {}
  async ensureIncident(key: IdempotencyKey, report: IncidentReport) {
    this.calls.push({ key, report });
    return this.result;
  }
}

export const fixedRuns = (r: Result<readonly RunRecord[], AdapterError>): RunHistory => ({
  recentRuns: async () => r,
});
export const fixedLabel = (r: Result<readonly number[], AdapterError>): PauseLabel => ({
  labelled: async () => r,
});

export const fixedCosts = (
  budget: DailyBudget | null,
  entries: readonly CostEntry[] = [],
): CostLedger => ({ read: async () => ok({ budget, entries }) });

export const fixedPulls = (r: Result<readonly PullSummary[], AdapterError>): PullRequests => ({
  open: async () => r,
});

export const fixedIssues = (r: Result<readonly IssueSummary[], AdapterError>): OpenIssues => ({
  open: async () => r,
});

/** Safety ports with harmless defaults: nothing running, paused, capped or awaiting review. */
export function fakeSafetyPorts(over: Partial<SafetyPorts> = {}): SafetyPorts {
  return {
    now: () => NOW,
    runs: fixedRuns(ok([])),
    pauseFlag: new MemoryPauseFlag(),
    pauseLabel: fixedLabel(ok([])),
    github: new RecordingGithubWriter(),
    costs: fixedCosts(null),
    pulls: fixedPulls(ok([])),
    issues: fixedIssues(ok([])),
    ...over,
  };
}
```

- [ ] **Step 4: Write the failing use-case test, then implement it**

```ts
import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import { fakeSafetyPorts, fixedIssues } from "../../../testing/fake-safety-ports";
import { checkIntake } from "./intake";

test("evaluates the candidate title against open issues", async () => {
  const issues = fixedIssues(ok([{ number: 4, title: "Stale docs", labels: ["auto-patrol"] }]));
  expect(await checkIntake(fakeSafetyPorts({ issues }), "stale DOCS")).toEqual({
    ok: true,
    value: { allowed: false, openAuto: 1, cap: 25, duplicateOf: 4 },
  });
});

test("an unreadable issue list is an error (callers fail closed)", async () => {
  const issues = fixedIssues(err({ kind: "transient", message: "HTTP 502" }));
  expect((await checkIntake(fakeSafetyPorts({ issues }), null)).ok).toBe(false);
});
```

```bash
bun test ./src/contexts/orchestration/application/intake.test.ts
```

Expected: FAIL — `error: Cannot find module './intake' from '…/intake.test.ts'`.

`src/contexts/orchestration/application/intake.ts`:

```ts
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { evaluateIntake, type IntakeVerdict } from "../domain/intake";
import type { SafetyPorts } from "../ports";

/** Whether automation may file an issue titled `title` (null: check only the cap). */
export async function checkIntake(
  ports: Pick<SafetyPorts, "issues">,
  title: string | null,
): Promise<Result<IntakeVerdict, AdapterError>> {
  const open = await ports.issues.open();
  return open.ok ? ok(evaluateIntake(open.value, title)) : open;
}
```

```bash
bun test ./src/contexts/orchestration/application/intake.test.ts
```

Expected: `2 pass`, `0 fail`.

- [ ] **Step 5: Write the failing adapter test, then implement it**

```ts
import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhOpenIssues } from "./gh-open-issues";

test("lists open issues with titles and labels", async () => {
  const stdout = JSON.stringify([
    { number: 8525, title: "Detect thrashing", labels: [{ name: "auto-patrol" }] },
  ]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh", "issue", "list"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  expect(await new GhOpenIssues(runner).open()).toEqual({
    ok: true,
    value: [{ number: 8525, title: "Detect thrashing", labels: ["auto-patrol"] }],
  });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--limit",
    "2000",
    "--json",
    "number,title,labels",
  ]);
  expect(runner.calls[0]?.timeoutMs).toBe(30_000);
});

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 429: Too Many Requests" } },
  ]);
  const r = await new GhOpenIssues(runner).open();
  expect(!r.ok && r.error.kind).toBe("transient");
});
```

```bash
bun test ./src/adapters/github/gh-open-issues.test.ts
```

Expected: FAIL — `error: Cannot find module './gh-open-issues' from '…/gh-open-issues.test.ts'`.

`src/adapters/github/gh-open-issues.ts` (listing ~850 open issues takes ~7 s, inside the 30 s timeout):

```ts
import { z } from "zod";
import type { IssueSummary, OpenIssues } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const GhIssue = z.object({
  number: z.number(),
  title: z.string(),
  labels: z.array(z.object({ name: z.string() })),
});

/** All open issues (up to 2000; the repo had ~850 open in October 2026). */
export class GhOpenIssues implements OpenIssues {
  constructor(private readonly runner: ProcessRunner) {}

  async open(): Promise<Result<readonly IssueSummary[], AdapterError>> {
    const argv = ["gh", "issue", "list", "--state", "open", "--limit", "2000"];
    const r = await runGhJson(
      this.runner,
      [...argv, "--json", "number,title,labels"],
      z.array(GhIssue),
    );
    if (!r.ok) return r;
    return ok(r.value.map((i) => ({ ...i, labels: i.labels.map((l) => l.name) })));
  }
}
```

```bash
bun test ./src/adapters/github/gh-open-issues.test.ts
```

Expected: `2 pass`, `0 fail`.

- [ ] **Step 6: Wire it in `src/main.ts`**

In `src/main.ts`, replace:

```ts
import { GhGithubWriter } from "./adapters/github/gh-github-writer";
```

with:

```ts
import { GhGithubWriter } from "./adapters/github/gh-github-writer";
import { GhOpenIssues } from "./adapters/github/gh-open-issues";
```

In `src/main.ts`, replace:

```ts
    pulls: new GhPullRequests(runner),
  };
```

with:

```ts
    pulls: new GhPullRequests(runner),
    issues: new GhOpenIssues(runner),
  };
```

- [ ] **Step 7: Write the failing command test, then implement and register it**

```ts
import { expect, test } from "bun:test";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedIssues } from "../../testing/fake-safety-ports";
import { intakeCommand } from "./intake";

const auto = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    number: i + 1,
    title: `t${i}x`,
    labels: ["auto-patrol"],
  }));

test("check exits 0 under the cap with no duplicate", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(auto(3))) });
  expect(
    await intakeCommand.run(["check", "--title", "New finding"], commandContext(io, ports)),
  ).toBe(0);
  expect(io.outLines).toEqual(["✓ intake: 3 of 25 open auto-patrol issues"]);
});

test("check exits 1 at the cap", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(auto(25))) });
  expect(await intakeCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual(["✗ intake: 25 of 25 open auto-patrol issues (cap reached)"]);
});

test("check exits 1 for a duplicate title", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(auto(1))) });
  expect(await intakeCommand.run(["check", "--title", "T0X"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual(["✗ intake: 1 of 25 open auto-patrol issues; duplicate of #1"]);
});

test("an unreadable issue list blocks (exit 1)", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(err({ kind: "auth", message: "x" })) });
  expect(await intakeCommand.run(["check"], commandContext(io, ports))).toBe(1);
});

test.each([[[]], [["check", "--title"]], [["check", "--bogus", "x"]]])(
  "bad arguments %p exit 2",
  async (args) => {
    expect(await intakeCommand.run(args, commandContext(captureIO()))).toBe(2);
  },
);
```

```bash
bun test ./src/cli/commands/intake.test.ts
```

Expected: FAIL — `error: Cannot find module './intake' from '…/intake.test.ts'`.

`src/cli/commands/intake.ts`:

```ts
import { checkIntake, describeIntake } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright intake check [--title TITLE]

DESCRIPTION
  Issue intake caps (spec §6.2, ADR-0007), consulted before automation files an issue.
  Exits 1 when 25 or more auto-patrol issues are open, when an open issue has the same
  title fingerprint (case, digits and punctuation ignored), or when issues cannot be listed.

OPTIONS
  --title TITLE   Title of the issue about to be filed

EXAMPLES
  shipwright intake check --title "Security: lodash 4.17.20 in package-lock"`;

/** The --title value, null when absent, or undefined when the arguments are malformed. */
function parseTitle(rest: readonly string[]): string | null | undefined {
  if (rest.length === 0) return null;
  if (rest.length !== 2 || rest[0] !== "--title") return undefined;
  return rest[1];
}

export const intakeCommand: Command = {
  name: "intake",
  aliases: [],
  summary: "Issue intake caps: may automation file this issue?",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelp(sub)) {
      io.out(usage);
      return 0;
    }
    const title = parseTitle(rest);
    if (sub !== "check" || title === undefined) {
      return usageError(
        io,
        usage,
        `Expected check [--title TITLE], got: ${args.join(" ") || "nothing"}`,
      );
    }
    const r = await checkIntake(safety(), title);
    if (!r.ok) return adapterFailure(io, "intake", r.error);
    io.out(`${r.value.allowed ? "✓" : "✗"} intake: ${describeIntake(r.value)}`);
    return r.value.allowed ? 0 : 1;
  },
};
```

Replace `src/cli/commands/index.ts` with:

```ts
import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { helloCommand } from "./hello";
import { intakeCommand } from "./intake";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
  budgetCommand,
  intakeCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
```

```bash
bun test ./src/cli/commands/intake.test.ts
```

Expected: `7 pass`, `0 fail`.

- [ ] **Step 8: Route, progress entry, reference**

In `scripts/sw`, replace:

```text
        budget)
            run_ts budget "$@"
            ;;
```

with:

```text
        budget)
            run_ts budget "$@"
            ;;
        intake)
            run_ts intake "$@"
            ;;
```

In `docs/plans/port/progress.json`, replace the end of the file:

```json
    "notes": "New in Wave 1a (spec §6.2 budget guard); reads the files sw-cost.sh writes."
  }
]
```

with:

```json
    "notes": "New in Wave 1a (spec §6.2 budget guard); reads the files sw-cost.sh writes."
  },
  {
    "command": "intake",
    "aliases": [],
    "script": "sw-intake.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a (spec §6.2 patrol hygiene): cap and title-fingerprint dedupe."
  }
]
```

```bash
bun run docs:gen
```

Expected: `docs/reference/cli.md` gains an `intake` section.

- [ ] **Step 9: Try it read-only against the real repository**

```bash
bun src/cli.ts intake check --title "Classify and cap duplicate/near-duplicate build-loop errors before retry"; echo "exit=$?"
```

Expected: a line like `✗ intake: 787 of 25 open auto-patrol issues; duplicate of #8524` and `exit=1` (counts drift; this only reads).

- [ ] **Step 10: Run the definition of done**

```bash
bun run format && git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 11: Commit**

```bash
git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md
git commit -m "feat(orchestration): issue intake caps"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 11: `shipwright gates` — the dispatch gate composition

**Files:**
- Create: `src/contexts/orchestration/application/gates.ts`, `src/cli/commands/gates.ts`
- Modify: `src/contexts/orchestration/index.ts`, `src/cli/commands/index.ts`, `scripts/sw`, `docs/plans/port/progress.json`, `docs/reference/cli.md`
- Test: `src/contexts/orchestration/application/gates.test.ts`, `src/cli/commands/gates.test.ts`

Order is pause → breaker → budget → review WIP → fix loop, short-circuiting at the first closed gate: a paused system never writes a breaker incident. `--no-github` (the daemon's no-GitHub mode) skips breaker and review WIP. Any adapter error closes that gate with `cannot verify (<kind>): <message>`.

- [ ] **Step 1: Write the failing use-case test**

```ts
import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import {
  fakeSafetyPorts,
  fixedCosts,
  fixedLabel,
  fixedPulls,
  fixedRuns,
  NOW,
  RecordingGithubWriter,
} from "../../../testing/fake-safety-ports";
import type { RunRecord } from "../domain/breaker";
import { checkDispatchGates } from "./gates";

const open = { github: true, attempt: null };
const failures: RunRecord[] = [0, 1, 2, 3, 4].map((i) => ({
  id: `r${i}`,
  startedAt: NOW - 600_000,
  finished: { at: NOW - 60_000 * (5 - i), outcome: "failure" },
}));

test("all gates open: every gate is reported, in order", async () => {
  const r = await checkDispatchGates(fakeSafetyPorts(), open);
  expect(r.allowed).toBe(true);
  expect(r.results).toEqual([
    { gate: "pause", allowed: true, detail: "not paused" },
    { gate: "breaker", allowed: true, detail: "closed (0 of the last 0 runs failed)" },
    {
      gate: "budget",
      allowed: true,
      detail: "no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
    },
    {
      gate: "review_wip",
      allowed: true,
      detail: "0 agent PRs awaiting review + 0 runs in flight (limit 5)",
    },
    { gate: "fix_loop", allowed: true, detail: "first attempt" },
  ]);
});

test("stops at the first closed gate; a paused system writes no incident", async () => {
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({
    github,
    pauseLabel: fixedLabel(ok([3])),
    runs: fixedRuns(ok(failures)),
  });
  const r = await checkDispatchGates(ports, open);
  expect(r).toEqual({
    allowed: false,
    results: [{ gate: "pause", allowed: false, detail: "label shipwright:pause on #3" }],
  });
  expect(github.calls).toHaveLength(0);
});

test("an open breaker blocks and ensures the incident", async () => {
  const github = new RecordingGithubWriter();
  const r = await checkDispatchGates(
    fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) }),
    open,
  );
  expect(r.allowed).toBe(false);
  expect(r.results.map((g) => g.gate)).toEqual(["pause", "breaker"]);
  expect(github.calls).toHaveLength(1);
});

test("budget, review WIP and the fix-loop cap each block", async () => {
  const today = Math.floor(NOW / 1000);
  const broke = fakeSafetyPorts({
    costs: fixedCosts({ limitUsd: 1 }, [{ costUsd: 1, atEpochS: today }]),
  });
  expect((await checkDispatchGates(broke, open)).results.at(-1)?.gate).toBe("budget");
  const pr = { author: "app/github-actions", labels: [], draft: false, approved: false };
  const busy = fakeSafetyPorts({
    pulls: fixedPulls(ok([1, 2, 3, 4, 5].map((number) => ({ number, ...pr })))),
  });
  expect((await checkDispatchGates(busy, open)).results.at(-1)).toMatchObject({
    gate: "review_wip",
    allowed: false,
  });
  const fourth = await checkDispatchGates(fakeSafetyPorts(), { github: true, attempt: 4 });
  expect(fourth.results.at(-1)).toEqual({
    gate: "fix_loop",
    allowed: false,
    detail: "retry 4 exceeds the cap of 3",
  });
});

test("a source that cannot be read closes its gate", async () => {
  const runs = fixedRuns(err({ kind: "auth", message: "HTTP 401" }));
  const r = await checkDispatchGates(fakeSafetyPorts({ runs }), open);
  expect(r.results.at(-1)).toEqual({
    gate: "breaker",
    allowed: false,
    detail: "cannot verify (auth): HTTP 401",
  });
});

test("without GitHub only the local gates run", async () => {
  const runs = fixedRuns(err({ kind: "auth", message: "no gh" }));
  const r = await checkDispatchGates(fakeSafetyPorts({ runs }), { github: false, attempt: 2 });
  expect(r.allowed).toBe(true);
  expect(r.results.map((g) => [g.gate, g.detail])).toEqual([
    ["pause", "not paused"],
    ["breaker", "skipped (no GitHub)"],
    ["budget", "no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>"],
    ["review_wip", "skipped (no GitHub)"],
    ["fix_loop", "retry 2 of 3"],
  ]);
});
```

```bash
bun test ./src/contexts/orchestration/application/gates.test.ts
```

Expected: FAIL — `error: Cannot find module './gates' from '…/gates.test.ts'`.

- [ ] **Step 2: Implement `src/contexts/orchestration/application/gates.ts` and export it**

```ts
// The dispatch gate composition (ADR-0007): pause → breaker → budget → review WIP → fix loop.
// Short-circuits at the first closed gate, so a paused system never writes a breaker incident.
// Every source that cannot be read closes its gate (fail closed).
import type { AdapterError } from "../../../shared/kernel/ports";
import { describeBreaker } from "../domain/breaker";
import { describeBudget } from "../domain/budget";
import { DEFAULT_FLOW_POLICY, describeWip, fixLoopAllows, reviewWip } from "../domain/flow";
import type { SafetyPorts } from "../ports";
import { checkBreaker, RUN_HISTORY_LIMIT } from "./breaker";
import { checkBudget } from "./budget";
import { readPause } from "./pause";

export type GateName = "pause" | "breaker" | "budget" | "review_wip" | "fix_loop";
export interface GateResult {
  readonly gate: GateName;
  readonly allowed: boolean;
  readonly detail: string;
}
export interface GateOptions {
  /** False in no-GitHub mode: the breaker and review-WIP gates are skipped. */
  readonly github: boolean;
  /** Retry number for the fix-loop cap; null for a first dispatch. */
  readonly attempt: number | null;
}
export interface GatesReport {
  readonly allowed: boolean;
  readonly results: readonly GateResult[];
}

const unreadable = (gate: GateName, e: AdapterError): GateResult => ({
  gate,
  allowed: false,
  detail: `cannot verify (${e.kind}): ${e.message}`,
});
const skipped = (gate: GateName): GateResult => ({
  gate,
  allowed: true,
  detail: "skipped (no GitHub)",
});

async function pauseGate(ports: SafetyPorts, o: GateOptions): Promise<GateResult> {
  const r = await readPause(ports, { github: o.github });
  if (!r.ok) return unreadable("pause", r.error);
  const detail = r.value.paused ? r.value.reasons.join("; ") : "not paused";
  return { gate: "pause", allowed: !r.value.paused, detail };
}

async function breakerGate(ports: SafetyPorts, o: GateOptions): Promise<GateResult> {
  if (!o.github) return skipped("breaker");
  const r = await checkBreaker(ports);
  if (!r.ok) return unreadable("breaker", r.error);
  return { gate: "breaker", allowed: r.value.allowed, detail: describeBreaker(r.value.state) };
}

async function budgetGate(ports: SafetyPorts): Promise<GateResult> {
  const r = await checkBudget(ports, 0);
  if (!r.ok) return unreadable("budget", r.error);
  return { gate: "budget", allowed: r.value.allowed, detail: describeBudget(r.value) };
}

async function reviewGate(ports: SafetyPorts, o: GateOptions): Promise<GateResult> {
  if (!o.github) return skipped("review_wip");
  const [pulls, runs] = await Promise.all([
    ports.pulls.open(),
    ports.runs.recentRuns(RUN_HISTORY_LIMIT),
  ]);
  if (!pulls.ok) return unreadable("review_wip", pulls.error);
  if (!runs.ok) return unreadable("review_wip", runs.error);
  const inFlight = runs.value.filter((r) => r.finished === null).length;
  const v = reviewWip(pulls.value, inFlight);
  return { gate: "review_wip", allowed: v.allowed, detail: describeWip(v) };
}

function fixLoopGate(o: GateOptions): GateResult {
  const cap = DEFAULT_FLOW_POLICY.fixLoopCap;
  const allowed = fixLoopAllows(o.attempt);
  if (o.attempt === null) return { gate: "fix_loop", allowed, detail: "first attempt" };
  const detail = allowed
    ? `retry ${o.attempt} of ${cap}`
    : `retry ${o.attempt} exceeds the cap of ${cap}`;
  return { gate: "fix_loop", allowed, detail };
}

export async function checkDispatchGates(
  ports: SafetyPorts,
  options: GateOptions,
): Promise<GatesReport> {
  const gates: (() => Promise<GateResult> | GateResult)[] = [
    () => pauseGate(ports, options),
    () => breakerGate(ports, options),
    () => budgetGate(ports),
    () => reviewGate(ports, options),
    () => fixLoopGate(options),
  ];
  const results: GateResult[] = [];
  for (const gate of gates) {
    const result = await gate();
    results.push(result);
    if (!result.allowed) return { allowed: false, results };
  }
  return { allowed: true, results };
}
```

Replace `src/contexts/orchestration/index.ts` with:

```ts
export {
  type BreakerReport,
  breakerStatus,
  checkBreaker,
  RUN_HISTORY_LIMIT,
} from "./application/breaker";
export { checkBudget } from "./application/budget";
export {
  checkDispatchGates,
  type GateName,
  type GateOptions,
  type GateResult,
  type GatesReport,
} from "./application/gates";
export { checkIntake } from "./application/intake";
export { type PauseOptions, pause, readPause, resume } from "./application/pause";
export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export {
  type BudgetVerdict,
  type CostEntry,
  type DailyBudget,
  describeBudget,
  evaluateBudget,
} from "./domain/budget";
export {
  DEFAULT_FLOW_POLICY,
  describeWip,
  type FlowPolicy,
  fixLoopAllows,
  type PullSummary,
  reviewWip,
  type WipVerdict,
} from "./domain/flow";
export {
  DEFAULT_INTAKE_POLICY,
  describeIntake,
  evaluateIntake,
  type IntakePolicy,
  type IntakeVerdict,
  type IssueSummary,
  titleFingerprint,
} from "./domain/intake";
export { type LocalPause, PAUSE_LABEL, type PauseStatus, pauseStatus } from "./domain/pause";
export type {
  CostLedger,
  OpenIssues,
  PauseFlag,
  PauseLabel,
  PullRequests,
  RunHistory,
  SafetyPorts,
} from "./ports";
```

```bash
bun test ./src/contexts/orchestration/application/gates.test.ts
```

Expected: `6 pass`, `0 fail`.

- [ ] **Step 3: Write the failing command test**

```ts
import { expect, test } from "bun:test";
import { ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedLabel } from "../../testing/fake-safety-ports";
import { gatesCommand, parseGateArgs } from "./gates";

test("check prints every gate and exits 0 when all are open", async () => {
  const io = captureIO();
  expect(await gatesCommand.run(["check"], commandContext(io, fakeSafetyPorts()))).toBe(0);
  expect(io.outLines).toEqual([
    "✓ pause: not paused",
    "✓ breaker: closed (0 of the last 0 runs failed)",
    "✓ budget: no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
    "✓ review_wip: 0 agent PRs awaiting review + 0 runs in flight (limit 5)",
    "✓ fix_loop: first attempt",
  ]);
});

test("check exits 1 at the first closed gate", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([3])) });
  expect(await gatesCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual(["✗ pause: label shipwright:pause on #3"]);
});

test("parses --attempt and --no-github", () => {
  expect(parseGateArgs(["--attempt", "2", "--no-github"])).toEqual({ github: false, attempt: 2 });
  expect(parseGateArgs([])).toEqual({ github: true, attempt: null });
  expect(parseGateArgs(["--attempt", "0"])).toBeNull();
  expect(parseGateArgs(["--attempt", "two"])).toBeNull();
  expect(parseGateArgs(["--attempt"])).toBeNull();
  expect(parseGateArgs(["--force"])).toBeNull();
});

test.each([[[]], [["status"]], [["check", "--attempt", "x"]]])(
  "bad arguments %p exit 2",
  async (args) => {
    expect(await gatesCommand.run(args, commandContext(captureIO()))).toBe(2);
  },
);
```

```bash
bun test ./src/cli/commands/gates.test.ts
```

Expected: FAIL — `error: Cannot find module './gates' from '…/gates.test.ts'`.

- [ ] **Step 4: Implement `src/cli/commands/gates.ts` and register it**

```ts
import { checkDispatchGates, type GateOptions } from "../../contexts/orchestration";
import type { Command } from "../command";
import { isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright gates check [--attempt N] [--no-github]

DESCRIPTION
  Every dispatch gate in order (ADR-0007): pause, breaker, budget, review WIP, fix loop.
  Stops at the first closed gate. Exits 0 when dispatch is allowed, 1 when it is not or a
  gate's source cannot be read. Workflows and the daemon call this before dispatching.

OPTIONS
  --attempt N    Retry number of this dispatch (1 = first retry); the fix-loop cap is 3
  --no-github    Check only local gates (pause flag, budget)

EXAMPLES
  shipwright gates check
  shipwright gates check --attempt 2`;

/** Gate options from the arguments after `check`, or null when they are malformed. */
export function parseGateArgs(args: readonly string[]): GateOptions | null {
  let github = true;
  let attempt: number | null = null;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--no-github") {
      github = false;
    } else if (arg === "--attempt" && /^[1-9]\d*$/.test(args[i + 1] ?? "")) {
      attempt = Number(args[i + 1]);
      i++;
    } else {
      return null;
    }
  }
  return { github, attempt };
}

export const gatesCommand: Command = {
  name: "gates",
  aliases: [],
  summary: "All dispatch gates (pause, breaker, budget, review WIP, fix loop)",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelp(sub)) {
      io.out(usage);
      return 0;
    }
    const options = parseGateArgs(rest);
    if (sub !== "check" || options === null) {
      return usageError(
        io,
        usage,
        `Expected check [--attempt N] [--no-github], got: ${args.join(" ") || "nothing"}`,
      );
    }
    const report = await checkDispatchGates(safety(), options);
    for (const g of report.results) io.out(`${g.allowed ? "✓" : "✗"} ${g.gate}: ${g.detail}`);
    return report.allowed ? 0 : 1;
  },
};
```

Replace `src/cli/commands/index.ts` with:

```ts
import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { gatesCommand } from "./gates";
import { helloCommand } from "./hello";
import { intakeCommand } from "./intake";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
  budgetCommand,
  intakeCommand,
  gatesCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
```

```bash
bun test ./src/cli/commands/gates.test.ts
```

Expected: `6 pass`, `0 fail`.

- [ ] **Step 5: Route, progress entry, reference**

In `scripts/sw`, replace:

```text
        intake)
            run_ts intake "$@"
            ;;
```

with:

```text
        intake)
            run_ts intake "$@"
            ;;
        gates)
            run_ts gates "$@"
            ;;
```

In `docs/plans/port/progress.json`, replace the end of the file:

```json
    "notes": "New in Wave 1a (spec §6.2 patrol hygiene): cap and title-fingerprint dedupe."
  }
]
```

with:

```json
    "notes": "New in Wave 1a (spec §6.2 patrol hygiene): cap and title-fingerprint dedupe."
  },
  {
    "command": "gates",
    "aliases": [],
    "script": "sw-gates.sh",
    "context": "orchestration",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 1a: all dispatch gates in ADR-0007 order, for workflows and the daemon."
  }
]
```

```bash
bun run docs:gen
T=$(mktemp -d)
HOME=$T bun src/cli.ts gates check --no-github; echo "exit=$?"
```

Expected: five lines — `✓ pause: not paused`, `✓ breaker: skipped (no GitHub)`, `✓ budget: no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>`, `✓ review_wip: skipped (no GitHub)`, `✓ fix_loop: first attempt` — and `exit=0`.

- [ ] **Step 6: Run the definition of done**

```bash
bun run format && git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 7: Commit**

```bash
git add -A src scripts/sw docs/plans/port/progress.json docs/reference/cli.md
git commit -m "feat(cli): shipwright gates"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 12: Bash: gate the daemon's dispatch, retries and patrol filing; skip auto-filed issues

**Files:**
- Create: `scripts/lib/safety-gates.sh`, `scripts/sw-lib-safety-gates-test.sh`
- Modify: `scripts/lib/daemon-dispatch.sh`, `scripts/lib/daemon-failure.sh`, `scripts/lib/daemon-patrol.sh`, `scripts/lib/daemon-poll-github.sh`

Minimal bash: one small library that only calls the TypeScript CLI (`bun src/cli.ts`, resolved relative to the library, so it works from any cwd), and four call sites. It also holds the dispatch-selection rule: an issue labelled `auto-patrol` (`$PATROL_LABEL`) is never dispatched until a human opts it in by removing that label. `ready-to-build` cannot be the opt-in, because `sw-patrol-meta.sh` and `sw-strategic.sh` add it automatically; nothing automated removes `auto-patrol`. `dispatch_eligible` serves the daemon's selection loop and `dispatchable_issue_numbers` the dispatch workflow (Task 14). It fails closed: without Bun, `safety_gates_ok` returns 127 and nothing is dispatched or filed. The retry path passes its retry number for the fix-loop cap through `DAEMON_RETRY_ATTEMPT`. `daemon_spawn_pipeline` already returns 1 from its budget gate at the same point, so its callers handle the new early return. Verification is `bash -n`, shellcheck and hermetic suites only; the dispatch and patrol suites drive tmux and are not run (see Conventions).

- [ ] **Step 1: Write the failing suite**

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/safety-gates test — bash callers of the TS safety gates  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun, gh and curl are mocks; no tmux, no network, temp HOME.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: safety-gates Tests"

setup_test_env "lib-safety-gates"
trap cleanup_test_env EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log"
export GH_LOG="$TEST_TEMP_DIR/gh.log"
export CURL_ARGS="$TEST_TEMP_DIR/curl.args"
export CURL_STDIN="$TEST_TEMP_DIR/curl.stdin"
export BUN_EXIT=0
mock_binary "bun" 'printf "%s\n" "$*" >> "$BUN_LOG"; exit "$BUN_EXIT"'
mock_binary "gh" 'printf "%s\n" "$*" >> "$GH_LOG"'
mock_binary "curl" 'cat > "$CURL_STDIN"; printf "%s\n" "$@" > "$CURL_ARGS"'

source "$SCRIPT_DIR/lib/safety-gates.sh"

# ─── safety_gates_ok ──────────────────────────────────────────────────────
print_test_section "safety_gates_ok"

: > "$BUN_LOG"
if safety_gates_ok 2>/dev/null; then
    assert_pass "open gates allow dispatch"
else
    assert_fail "open gates allow dispatch"
fi
assert_contains "runs gates check" "$(cat "$BUN_LOG")" "src/cli.ts gates check --no-github"

: > "$BUN_LOG"
safety_gates_ok 2 2>/dev/null || true
assert_contains "passes the retry attempt" "$(cat "$BUN_LOG")" "gates check --no-github --attempt 2"

: > "$BUN_LOG"
safety_gates_ok "2;echo pwned" 2>/dev/null || true
assert_eq "drops a non-numeric attempt" "0" "$(grep -c 'pwned' "$BUN_LOG" || true)"

export BUN_EXIT=1
if safety_gates_ok 2>/dev/null; then
    assert_fail "a closed gate blocks dispatch"
else
    assert_pass "a closed gate blocks dispatch"
fi
export BUN_EXIT=0

if SW_BUN="no-such-bun-binary" safety_gates_ok 2>/dev/null; then
    assert_fail "missing bun fails closed"
else
    assert_pass "missing bun fails closed"
fi

# ─── patrol_issue_create ──────────────────────────────────────────────────
print_test_section "patrol_issue_create"

: > "$BUN_LOG"
: > "$GH_LOG"
patrol_issue_create --title "Security: x in y" --body "b" --label "auto-patrol" 2>/dev/null
assert_contains "asks the intake gate with the title" "$(cat "$BUN_LOG")" \
    "intake check --title Security: x in y"
assert_contains "files the issue when allowed" "$(cat "$GH_LOG")" \
    "issue create --title Security: x in y --body b --label auto-patrol"

: > "$GH_LOG"
export BUN_EXIT=1
if patrol_issue_create --title "dup" --body "b" 2>/dev/null; then
    assert_fail "a closed intake gate refuses"
else
    assert_pass "a closed intake gate refuses"
fi
assert_eq "nothing filed when refused" "" "$(cat "$GH_LOG")"
export BUN_EXIT=0

# ─── dispatch eligibility ─────────────────────────────────────────────────
print_test_section "dispatch eligibility (auto-filed issues need a human opt-in)"

if dispatch_eligible "shipwright,bug"; then
    assert_pass "a human-filed issue is eligible"
else
    assert_fail "a human-filed issue is eligible"
fi
if dispatch_eligible "shipwright,auto-patrol,security"; then
    assert_fail "an auto-patrol issue is skipped"
else
    assert_pass "an auto-patrol issue is skipped"
fi
if dispatch_eligible "shipwright,auto-patrol-meta"; then
    assert_pass "only the exact label matches"
else
    assert_fail "only the exact label matches"
fi
if dispatch_eligible ""; then
    assert_pass "an issue without labels is eligible"
else
    assert_fail "an issue without labels is eligible"
fi
if PATROL_LABEL="patrol" dispatch_eligible "shipwright,patrol"; then
    assert_fail "honors a configured PATROL_LABEL"
else
    assert_pass "honors a configured PATROL_LABEL"
fi
issues='[{"number":1,"labels":[{"name":"shipwright"}]},
 {"number":2,"labels":[{"name":"auto-patrol"},{"name":"shipwright"}]},
 {"number":3,"labels":[]}]'
assert_eq "filters gh issue list JSON" "1 3" "$(dispatchable_issue_numbers <<<"$issues" | tr '\n' ' ' | sed 's/ $//')"

print_test_results
```

Make it executable:

```bash
chmod +x scripts/sw-lib-safety-gates-test.sh
```

```bash
bash scripts/sw-lib-safety-gates-test.sh
```

Expected: FAIL — `…/scripts/lib/safety-gates.sh: No such file or directory`, non-zero exit.

- [ ] **Step 2: Implement `scripts/lib/safety-gates.sh`**

```bash
# safety-gates.sh — bash callers of the Wave 1a safety gates (ADR-0007).
# The decisions live in TypeScript (`shipwright gates`, `shipwright intake`); this file only
# calls them. Everything fails closed: if Bun or the CLI cannot run, nothing is dispatched or filed.
[[ -n "${_SAFETY_GATES_LOADED:-}" ]] && return 0
_SAFETY_GATES_LOADED=1

_SAFETY_GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW_TS_CLI="${SW_TS_CLI:-${_SAFETY_GATES_DIR}/../../src/cli.ts}"

# _sw_ts <args...> — runs the TypeScript CLI; 127 when Bun is missing.
_sw_ts() {
    local bun_bin="${SW_BUN:-bun}"
    if ! command -v "$bun_bin" >/dev/null 2>&1; then
        echo "safety gates: ${bun_bin} not found — failing closed" >&2
        return 127
    fi
    "$bun_bin" "$SW_TS_CLI" "$@"
}

# safety_gates_ok [attempt] — 0 when dispatch is allowed; the gate report goes to stderr.
# attempt: retry number (1 = first retry) for the fix-loop cap; ignored unless numeric.
safety_gates_ok() {
    local attempt="${1:-}"
    local args=(gates check)
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        args+=(--no-github)
    fi
    if [[ "$attempt" =~ ^[1-9][0-9]*$ ]]; then
        args+=(--attempt "$attempt")
    fi
    _sw_ts "${args[@]}" >&2
}

# patrol_issue_create <gh issue create args...> — files the issue only when the intake gate
# allows it (open auto-filed issues under the cap, no open issue with the same fingerprint).
patrol_issue_create() {
    local title="" prev="" arg
    for arg in "$@"; do
        if [[ "$prev" == "--title" ]]; then
            title="$arg"
        fi
        prev="$arg"
    done
    if ! _sw_ts intake check --title "$title" >&2; then
        return 1
    fi
    gh issue create "$@"
}

# Auto-filed issues (label $PATROL_LABEL, default auto-patrol) are never dispatched until a human
# opts one in by removing that label (ADR-0007). Automation never removes it.

# dispatch_eligible <labels-csv> — 0 when an issue with these labels may be dispatched.
dispatch_eligible() {
    case ",${1:-}," in
        *",${PATROL_LABEL:-auto-patrol},"*) return 1 ;;
    esac
    return 0
}

# dispatchable_issue_numbers — reads `gh issue list --json number,labels` on stdin and prints the
# numbers of the issues that may be dispatched, one per line.
dispatchable_issue_numbers() {
    jq -r --arg auto "${PATROL_LABEL:-auto-patrol}" \
        '.[] | select([.labels[].name] | index($auto) | not) | .number'
}
```

```bash
bash scripts/sw-lib-safety-gates-test.sh
```

Expected: `All 16 tests passed`.

- [ ] **Step 3: Gate `daemon_spawn_pipeline` in `scripts/lib/daemon-dispatch.sh`**

In `scripts/lib/daemon-dispatch.sh`, replace:

```bash
[[ -n "${_DAEMON_DISPATCH_LOADED:-}" ]] && return 0
_DAEMON_DISPATCH_LOADED=1
```

with:

```bash
[[ -n "${_DAEMON_DISPATCH_LOADED:-}" ]] && return 0
_DAEMON_DISPATCH_LOADED=1
# shellcheck source=safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety-gates.sh"
```

In `scripts/lib/daemon-dispatch.sh`, replace:

```bash
    daemon_log INFO "Spawning pipeline for issue #${issue_num}: ${issue_title}"

    # ── Budget gate: hard-stop if daily budget exhausted ──
```

with:

```bash
    # ── Safety gates (ADR-0007): pause, breaker, budget, review WIP, fix-loop cap ──
    # DAEMON_RETRY_ATTEMPT is set by the retry path in daemon-failure.sh.
    if ! safety_gates_ok "${DAEMON_RETRY_ATTEMPT:-}"; then
        daemon_log WARN "Safety gates closed — not dispatching issue #${issue_num}"
        emit_event "daemon.gates_closed" "issue=${issue_num}"
        return 1
    fi

    daemon_log INFO "Spawning pipeline for issue #${issue_num}: ${issue_title}"

    # ── Budget gate: hard-stop if daily budget exhausted ──
```

- [ ] **Step 4: Pass the retry number in `scripts/lib/daemon-failure.sh`**

In `scripts/lib/daemon-failure.sh`, replace:

```bash
                    daemon_spawn_pipeline "$issue_num" "retry-${retry_count}" "" "${all_extra_args[@]}"
```

with:

```bash
                    DAEMON_RETRY_ATTEMPT="$retry_count" \
                        daemon_spawn_pipeline "$issue_num" "retry-${retry_count}" "" "${all_extra_args[@]}"
```

- [ ] **Step 5: Route patrol's ten `gh issue create` calls through the intake gate**

In `scripts/lib/daemon-patrol.sh`, replace:

```bash
[[ -n "${_DAEMON_PATROL_LOADED:-}" ]] && return 0
_DAEMON_PATROL_LOADED=1
```

with:

```bash
[[ -n "${_DAEMON_PATROL_LOADED:-}" ]] && return 0
_DAEMON_PATROL_LOADED=1
# shellcheck source=safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety-gates.sh"
```

Every call site is a line that is exactly `gh issue create \` followed by `--title …`, `--body …` and `--label … 2>/dev/null || true`, so one substitution covers all ten (macOS `sed -i ''`). A refused issue returns 1, which each site's `|| true` absorbs.

```bash
sed -i '' -E 's/^([[:space:]]*)gh issue create \\$/\1patrol_issue_create \\/' scripts/lib/daemon-patrol.sh
grep -c 'patrol_issue_create \\$' scripts/lib/daemon-patrol.sh
grep -c 'gh issue create' scripts/lib/daemon-patrol.sh || true
```

Expected: `10`, then `0`.

- [ ] **Step 6: Skip auto-filed issues in the daemon's selection loop (`scripts/lib/daemon-poll-github.sh`)**

In `scripts/lib/daemon-poll-github.sh`, replace:

```bash
[[ -n "${_DAEMON_POLL_GITHUB_LOADED:-}" ]] && return 0
_DAEMON_POLL_GITHUB_LOADED=1
```

with:

```bash
[[ -n "${_DAEMON_POLL_GITHUB_LOADED:-}" ]] && return 0
_DAEMON_POLL_GITHUB_LOADED=1
# shellcheck source=safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety-gates.sh"
```

In `scripts/lib/daemon-poll-github.sh`, replace:

```bash
        # Skip if already inflight
        if daemon_is_inflight "$issue_key"; then
            continue
        fi
```

with:

```bash
        # Skip if already inflight
        if daemon_is_inflight "$issue_key"; then
            continue
        fi

        # Auto-filed issues wait for a human to remove the auto-patrol label (ADR-0007)
        if ! dispatch_eligible "$labels_csv"; then
            daemon_log INFO "Issue #${issue_num} is auto-filed — skipped until a human removes '${PATROL_LABEL:-auto-patrol}'"
            continue
        fi
```

The skip sits before the claim, the priority lane and the queue, so an auto-filed issue is never claimed, queued or spawned. (`sw-lib-daemon-poll-test` drives tmux, so this call site is verified by `bash -n` and shellcheck; the rule itself is covered by the suite.)

- [ ] **Step 7: Syntax, shellcheck and the hermetic suites**

```bash
for f in scripts/lib/safety-gates.sh scripts/lib/daemon-dispatch.sh scripts/lib/daemon-failure.sh scripts/lib/daemon-patrol.sh scripts/lib/daemon-poll-github.sh; do bash -n "$f" || echo "SYNTAX $f"; done
shellcheck -x -S warning -e SC2034,SC1090,SC2148,SC2119,SC2120 scripts/lib/safety-gates.sh scripts/lib/daemon-failure.sh scripts/lib/daemon-patrol.sh scripts/lib/daemon-poll-github.sh scripts/sw-lib-safety-gates-test.sh; echo "shellcheck=$?"
shellcheck -x -S warning -e SC2034,SC1090,SC2148,SC2119,SC2120 scripts/lib/daemon-dispatch.sh | grep -c 'SC2155' || true
bash scripts/sw-test-all.sh --pattern lib-safety-gates > /tmp/sw-gates.log 2>&1; echo "gates-suite=$?"
bash scripts/sw-test-all.sh --pattern lib-daemon-failure > /tmp/sw-failure.log 2>&1; echo "failure-suite=$?"
```

Expected: no `SYNTAX` lines; `shellcheck=0`; `2` (the two SC2155 warnings already in `daemon-dispatch.sh` on `export CLAUDE_MODEL=…` and `local job_id=…`; nothing new); `gates-suite=0`; `failure-suite=0` (that suite stubs `daemon_spawn_pipeline`, so it is hermetic).

- [ ] **Step 8: Run the definition of done**

```bash
bun run format && git add -A scripts/lib scripts/sw-lib-safety-gates-test.sh && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 9: Commit**

```bash
git add -A scripts/lib scripts/sw-lib-safety-gates-test.sh
git commit -m "feat(daemon): gate dispatch, retries and patrol filing; skip auto-filed issues"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 13: Bot-authored comments only (helper for retry markers)

**Files:**
- Create: `scripts/ci/bot-comments.sh`, `scripts/sw-ci-bot-comments-test.sh`

`shipwright-auto-retry.yml` trusts `SHIPWRIGHT-RETRY`, `-RESULT`, `-STAGE`, `-NO-CHANGES` and `-ERROR-MSG` markers from any commenter; anyone could reset the retry count with `<!-- SHIPWRIGHT-RETRY: 0 -->` or mark stages complete. Every workflow here comments with `secrets.GITHUB_TOKEN`, so the bot is `github-actions[bot]`. The REST API reports it with `user.type == "Bot"`, and no user can register a `[bot]` login; GraphQL (`gh issue view --json comments`) shows the same author as `github-actions`, so this helper uses REST. `SHIPWRIGHT_BOT_LOGIN` overrides the login when a GitHub App token is used (decision 5, Wave 1c).

- [ ] **Step 1: Write the failing suite**

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/bot-comments.sh test — SHIPWRIGHT-* markers from the bot only ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock that prints two pages of REST comments.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: bot-comments Tests"

setup_test_env "ci-bot-comments"
trap cleanup_test_env EXIT

export GITHUB_REPOSITORY="o/r"
export GH_ARGS="$TEST_TEMP_DIR/gh.args"
cat > "$TEST_TEMP_DIR/page1.json" <<'JSON'
[{"user":{"login":"github-actions[bot]","type":"Bot"},"created_at":"2026-10-14T01:00:00Z","body":"<!-- SHIPWRIGHT-RETRY: 1 -->"},
 {"user":{"login":"mallory","type":"User"},"created_at":"2026-10-14T02:00:00Z","body":"<!-- SHIPWRIGHT-RETRY: 0 -->"}]
JSON
cat > "$TEST_TEMP_DIR/page2.json" <<'JSON'
[{"user":{"login":"github-actions[bot]","type":"Bot"},"created_at":"2026-10-14T03:00:00Z","body":"<!-- SHIPWRIGHT-STAGE: plan:complete -->"},
 {"user":{"login":"github-actions[bot]","type":"User"},"created_at":"2026-10-14T04:00:00Z","body":"<!-- SHIPWRIGHT-STAGE: build:complete -->"}]
JSON
export PAGE1="$TEST_TEMP_DIR/page1.json" PAGE2="$TEST_TEMP_DIR/page2.json"
mock_binary "gh" 'printf "%s\n" "$@" > "$GH_ARGS"; cat "$PAGE1" "$PAGE2"'

BOT_COMMENTS="$SCRIPT_DIR/ci/bot-comments.sh"

print_test_section "filtering"
out=$("$BOT_COMMENTS" 42)
assert_eq "keeps only Bot-type comments by the bot login" "2" "$(jq 'length' <<<"$out")"
assert_eq "keeps order and timestamps" "2026-10-14T01:00:00Z,2026-10-14T03:00:00Z" \
    "$(jq -r '[.[].createdAt] | join(",")' <<<"$out")"
assert_eq "drops the spoofed marker" "0" "$(grep -c 'RETRY: 0' <<<"$out" || true)"
assert_contains "reads every page of the REST endpoint" "$(cat "$GH_ARGS")" "--paginate"
assert_contains "asks for the issue's comments" "$(cat "$GH_ARGS")" "repos/o/r/issues/42/comments?per_page=100"

out=$(SHIPWRIGHT_BOT_LOGIN="mallory" "$BOT_COMMENTS" 42)
assert_eq "a User account is never the bot, even when named" "0" "$(jq 'length' <<<"$out")"

print_test_section "input validation"
if "$BOT_COMMENTS" "42; echo pwned" >/dev/null 2>&1; then
    assert_fail "rejects a non-numeric issue"
else
    assert_pass "rejects a non-numeric issue"
fi

mock_binary "gh" 'echo "HTTP 502" >&2; exit 1'
if "$BOT_COMMENTS" 42 >/dev/null 2>&1; then
    assert_fail "a gh failure fails the script (callers fail closed)"
else
    assert_pass "a gh failure fails the script (callers fail closed)"
fi

print_test_results
```

Create the directory and make the suite executable:

```bash
mkdir -p scripts/ci
chmod +x scripts/sw-ci-bot-comments-test.sh
```

```bash
bash scripts/sw-ci-bot-comments-test.sh
```

Expected: FAIL — `ERROR: …sw-ci-bot-comments-test.sh:… exited with status 127` (the script does not exist).

- [ ] **Step 2: Implement `scripts/ci/bot-comments.sh`**

```bash
#!/usr/bin/env bash
# bot-comments.sh <issue-number> — comments written by the Shipwright bot on an issue, as a JSON
# array of {createdAt, body}. Workflows read SHIPWRIGHT-* markers only from this output, so a
# marker typed by anyone else is ignored (ADR-0007).
#
# The bot is the GitHub App user of the workflow token: login $SHIPWRIGHT_BOT_LOGIN (default
# "github-actions[bot]") AND account type "Bot" — a user cannot register a "[bot]" login.
# Needs GITHUB_REPOSITORY and a gh token. Exits non-zero when gh fails; callers fail closed.
set -euo pipefail

issue="${1:-}"
if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: bot-comments.sh <issue-number>" >&2
    exit 2
fi
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
bot="${SHIPWRIGHT_BOT_LOGIN:-github-actions[bot]}"

gh api --paginate "repos/${repo}/issues/${issue}/comments?per_page=100" \
    | jq -s --arg bot "$bot" \
        '[.[][] | select(.user.login == $bot and .user.type == "Bot")
          | {createdAt: .created_at, body: .body}]'
```

Make it executable:

```bash
chmod +x scripts/ci/bot-comments.sh
```

```bash
bash scripts/sw-ci-bot-comments-test.sh
shellcheck -x -S warning -e SC2034,SC1090,SC2148,SC2119,SC2120 scripts/ci/bot-comments.sh scripts/sw-ci-bot-comments-test.sh; echo "shellcheck=$?"
bash scripts/sw-test-all.sh --pattern ci-bot-comments > /tmp/sw-bot.log 2>&1; echo "suite=$?"
```

Expected: `All 8 tests passed`; `shellcheck=0`; `suite=0`.

- [ ] **Step 3: Read-only smoke test against the real repository**

```bash
GITHUB_REPOSITORY=sethdford/shipwright scripts/ci/bot-comments.sh 7525 | jq length
```

Expected: a number around `200` (the bot's comments on #7525).

- [ ] **Step 4: Run the definition of done**

```bash
bun run format && git add -A scripts/ci scripts/sw-ci-bot-comments-test.sh && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 5: Commit**

```bash
git add -A scripts/ci scripts/sw-ci-bot-comments-test.sh
git commit -m "feat(ci): read SHIPWRIGHT markers from bot comments only"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 14: Gate dispatch and auto-retry; the watchdog only cancels

**Files:**
- Create: `.github/actions/safety-gates/action.yml`
- Modify: `.github/workflows/shipwright-dispatch.yml`, `.github/workflows/shipwright-watchdog.yml`, `.github/workflows/shipwright-auto-retry.yml`

The three workflows had no checkout; each now checks out (without persisted credentials) and sets `GH_REPO` at job level so the TypeScript `gh` calls target this repository. Dispatch and auto-retry run the composite action — set up Bun 1.2.19, `bun install --frozen-lockfile --ignore-scripts`, `bun src/cli.ts gates check`, output `allowed` — and act only when it is `'true'`. Dispatch re-runs `bun src/cli.ts gates check` before each issue, because an earlier dispatch in the same run can close review WIP; it stops after `MAX_DISPATCH` (3) issues per run, and it skips `auto-patrol` issues through `dispatchable_issue_numbers` (Task 12). **Auto-retry is the single retry path:** the watchdog only cancels stuck runs and comments; the cancelled run then triggers auto-retry, which applies the gates and the fix-loop cap. For a run silent over 2 hours the watchdog labels and comments (`SHIPWRIGHT-WATCHDOG-ABANDON`) *before* cancelling, and auto-retry skips any run carrying that bot marker. The auto-retry budget step (`shipwright cost remaining-budget`) is removed: the budget gate replaces it. No `${{ }}` appears inside any `run:` script (`bun run arch` checks the composite action too).

- [ ] **Step 1: Create `.github/actions/safety-gates/action.yml`**

```yaml
name: Shipwright safety gates
description: >-
  Installs the Shipwright TypeScript CLI and runs `shipwright gates check` (pause, breaker,
  budget, review WIP, fix loop; ADR-0007). Never fails the job: read the `allowed` output.
  Requires actions/checkout first and GITHUB_TOKEN in the job env.
inputs:
  attempt:
    description: Retry number for the fix-loop cap (1 = first retry); empty for a first dispatch
    required: false
    default: ""
outputs:
  allowed:
    description: "'true' when every gate is open, otherwise 'false'"
    value: ${{ steps.gates.outputs.allowed }}
runs:
  using: composite
  steps:
    - uses: oven-sh/setup-bun@v2
      with:
        bun-version: 1.2.19
    - name: Install the Shipwright CLI dependencies
      shell: bash
      run: bun install --frozen-lockfile --ignore-scripts
    - name: Check the dispatch gates
      id: gates
      shell: bash
      env:
        ATTEMPT: ${{ inputs.attempt }}
      run: |
        args=(gates check)
        if [[ -n "$ATTEMPT" ]]; then
          args+=(--attempt "$ATTEMPT")
        fi
        if bun src/cli.ts "${args[@]}"; then
          echo "allowed=true" >> "$GITHUB_OUTPUT"
        else
          echo "allowed=false" >> "$GITHUB_OUTPUT"
        fi
```

- [ ] **Step 2: `shipwright-dispatch.yml` — checkout, gates, auto-patrol filter, per-dispatch re-check and a per-run cap**

In `.github/workflows/shipwright-dispatch.yml`, replace:

```yaml
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

    steps:
      - name: Scan and dispatch shipwright-labeled issues
        run: |
```

with:

```yaml
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      GH_REPO: ${{ github.repository }}

    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Safety gates
        id: gates
        uses: ./.github/actions/safety-gates

      - name: Scan and dispatch shipwright-labeled issues
        if: steps.gates.outputs.allowed == 'true'
        env:
          MAX_DISPATCH: "3"
        run: |
```

In `.github/workflows/shipwright-dispatch.yml`, replace:

```yaml
          # Get all open issues with the 'shipwright' label
          ISSUES=$(gh issue list --repo "$GITHUB_REPOSITORY" \
            --label shipwright --state open --json number,title \
            --jq '.[].number' 2>/dev/null || echo "")
```

with:

```yaml
          # Open issues with the 'shipwright' label, minus auto-filed ones: an auto-patrol issue
          # is dispatched only after a human removes that label (ADR-0007).
          # shellcheck source=/dev/null
          source scripts/lib/safety-gates.sh
          ISSUES=$(gh issue list --repo "$GITHUB_REPOSITORY" \
            --label shipwright --state open --limit 200 --json number,labels 2>/dev/null \
            | dispatchable_issue_numbers 2>/dev/null || echo "")
```

In `.github/workflows/shipwright-dispatch.yml`, replace:

```yaml
            # ── All checks passed — dispatch pipeline ──
```

with:

```yaml
            # ── Gates again before every dispatch: an earlier one may have closed a gate ──
            if [[ "$DISPATCHED" -ge "$MAX_DISPATCH" ]]; then
              echo "Dispatched $DISPATCHED issue(s), the per-run cap — stopping"
              break
            fi
            if ! bun src/cli.ts gates check; then
              echo "Safety gates closed — stopping"
              break
            fi

            # ── All checks passed — dispatch pipeline ──
```

- [ ] **Step 3: `shipwright-watchdog.yml` — checkout, bot-only signals, cancel without retrying**

In `.github/workflows/shipwright-watchdog.yml`, replace:

```yaml
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

    steps:
      - name: Monitor in-progress pipeline runs
```

with:

```yaml
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      GH_REPO: ${{ github.repository }}

    steps:
      # For scripts/ci/bot-comments.sh. The watchdog never dispatches: auto-retry is the only
      # retry path (ADR-0007), so this job needs no safety gates.
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Monitor in-progress pipeline runs
```

In `.github/workflows/shipwright-watchdog.yml`, replace:

```yaml
            COMMENTS_JSON=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
              --json comments --jq '.comments[] | {createdAt, body}' 2>/dev/null || echo "")
```

with:

```yaml
            # Bot-authored comments only: anyone can type a SHIPWRIGHT-* marker (ADR-0007).
            COMMENTS_JSON=$(scripts/ci/bot-comments.sh "$ISSUE_NUMBER" 2>/dev/null | jq -c '.[]' 2>/dev/null || echo "")
```

In `.github/workflows/shipwright-watchdog.yml`, replace:

```yaml
            # 45 min - 2h silence: cancel and retry
            if [[ "$SILENT_MINS" -lt 120 ]]; then
              echo "Status: STUCK (${SILENT_MINS}m silence) — cancelling and retrying"
```

with:

```yaml
            # 45 min - 2h silence: cancel. Retrying is auto-retry's job alone: it runs on the
            # cancelled run, behind the safety gates and the fix-loop cap (ADR-0007).
            if [[ "$SILENT_MINS" -lt 120 ]]; then
              echo "Status: STUCK (${SILENT_MINS}m silence) — cancelling; auto-retry decides on a retry"
```

In `.github/workflows/shipwright-watchdog.yml`, replace:

```yaml
          | Action | Dispatching retry with resume |
```

with:

```yaml
          | Action | Cancelled — auto-retry decides whether to retry (safety gates, at most 3 retries) |
```

In `.github/workflows/shipwright-watchdog.yml`, delete the retry dispatch after the stuck comment — replace:

```yaml
          )" 2>/dev/null || true

              # Dispatch retry
              gh workflow run shipwright-pipeline.yml \
                --repo "$GITHUB_REPOSITORY" \
                -f issue_number="$ISSUE_NUMBER" \
                -f template=full \
                -f max_iterations="25" \
                -f completed_stages="$COMPLETED_STAGES" \
                -f skip_triage=true 2>/dev/null || echo "Failed to dispatch retry for #$ISSUE_NUMBER"
              sleep 5
              continue
```

with:

```yaml
          )" 2>/dev/null || true
              continue
```

In `.github/workflows/shipwright-watchdog.yml`, move the abandon branch's cancel after its comment — first replace:

```yaml
            # Cancel the run
            gh run cancel "$RUN_ID" --repo "$GITHUB_REPOSITORY" 2>/dev/null || true

            # Label as stuck
```

with:

```yaml
            # Label and comment BEFORE cancelling: auto-retry starts as soon as the run is
            # cancelled, and skips it only when the SHIPWRIGHT-WATCHDOG-ABANDON marker exists.
            # Label as stuck
```

then replace:

```yaml
          <!-- SHIPWRIGHT-WATCHDOG-ABANDON: $RUN_ID -->
          EOF
          )" 2>/dev/null || true
```

with:

```yaml
          <!-- SHIPWRIGHT-WATCHDOG-ABANDON: $RUN_ID -->
          EOF
          )" 2>/dev/null || true

            # Cancel the run (after the marker exists)
            gh run cancel "$RUN_ID" --repo "$GITHUB_REPOSITORY" 2>/dev/null || true
```

```bash
grep -cE 'gh workflow run shipwright-pipeline.yml \\$' .github/workflows/shipwright-watchdog.yml || true
grep -n 'gh run cancel' .github/workflows/shipwright-watchdog.yml
```

Expected: `0` (the watchdog dispatches nothing; the only `gh workflow run` left is the manual-retry hint inside the abandon comment), then two `gh run cancel` lines: the stuck branch's, and the abandon branch's, which now comes after its `SHIPWRIGHT-WATCHDOG-ABANDON` comment.

- [ ] **Step 4: `shipwright-auto-retry.yml` — checkout, bot-only markers, skip abandoned runs**

In `.github/workflows/shipwright-auto-retry.yml`, replace:

```yaml
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

    steps:
      - name: Extract issue number from failed run
```

with:

```yaml
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      GH_REPO: ${{ github.repository }}

    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Extract issue number from failed run
```

In `.github/workflows/shipwright-auto-retry.yml`, replace:

```yaml
            for issue in $OPEN_ISSUES; do
              HAS_RUN=$(gh issue view "$issue" --repo "$GITHUB_REPOSITORY" --json comments \
                --jq "[.comments[] | select(.body | contains(\"$RUN_ID\"))] | length" 2>/dev/null || echo "0")
```

with:

```yaml
            for issue in $OPEN_ISSUES; do
              # Bot-authored comments only (ADR-0007); RUN_ID goes to jq as data.
              HAS_RUN=$(scripts/ci/bot-comments.sh "$issue" 2>/dev/null \
                | jq --arg run "$RUN_ID" '[.[] | select(.body | contains($run))] | length' 2>/dev/null || echo "0")
```

In `.github/workflows/shipwright-auto-retry.yml`, replace:

```yaml
          # Extract failed stage from issue comments (SHIPWRIGHT-RESULT marker)
          COMMENTS=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
            --json comments --jq '.comments[].body' 2>/dev/null || echo "")
```

with:

```yaml
          # Extract failed stage from bot-authored comments only (SHIPWRIGHT-RESULT marker);
          # a marker typed by anyone else is ignored (ADR-0007).
          COMMENTS=$(scripts/ci/bot-comments.sh "$ISSUE_NUMBER" 2>/dev/null | jq -r '.[].body' 2>/dev/null || echo "")
```

In `.github/workflows/shipwright-auto-retry.yml`, replace:

```yaml
          # Read retry count from issue comments (hidden HTML marker)
          COMMENTS=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
            --json comments --jq '.comments[].body' 2>/dev/null || echo "")
```

with:

```yaml
          # Read retry count from bot-authored comments only (hidden HTML marker). If they
          # cannot be read, do not retry: a missing count would restart the loop at 0.
          if ! BOT_JSON=$(scripts/ci/bot-comments.sh "$ISSUE_NUMBER"); then
            echo "Cannot read bot comments for #$ISSUE_NUMBER — not retrying"
            echo "should_retry=false" >> "$GITHUB_OUTPUT"
            echo "skip_reason=unreadable" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          COMMENTS=$(echo "$BOT_JSON" | jq -r '.[].body')

          # A run the watchdog abandoned (silent over 2h) is never retried automatically.
          if echo "$COMMENTS" | grep -qF "SHIPWRIGHT-WATCHDOG-ABANDON: $RUN_ID"; then
            echo "Run $RUN_ID was abandoned by the watchdog — not retrying"
            echo "should_retry=false" >> "$GITHUB_OUTPUT"
            echo "skip_reason=abandoned" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

In `.github/workflows/shipwright-auto-retry.yml`, replace:

```yaml
          # Build a summary of all retry attempts from issue comments
          COMMENTS=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
            --json comments --jq '.comments[].body' 2>/dev/null || echo "")
```

with:

```yaml
          # Build a summary of all retry attempts from bot-authored comments
          COMMENTS=$(scripts/ci/bot-comments.sh "$ISSUE_NUMBER" 2>/dev/null | jq -r '.[].body' 2>/dev/null || echo "")
```

- [ ] **Step 5: `shipwright-auto-retry.yml` — gate the retry (replaces the budget step)**

In `.github/workflows/shipwright-auto-retry.yml`, replace:

```yaml
      - name: Post retry comment with root cause
        if: steps.strategy.outputs.should_retry == 'true'
```

with:

```yaml
      - name: Safety gates
        id: gates
        if: steps.strategy.outputs.should_retry == 'true'
        uses: ./.github/actions/safety-gates
        with:
          attempt: ${{ steps.strategy.outputs.retry_count }}

      - name: Post retry comment with root cause
        if: steps.strategy.outputs.should_retry == 'true' && steps.gates.outputs.allowed == 'true'
```

In `.github/workflows/shipwright-auto-retry.yml`, delete the budget step and re-condition the dispatch step — replace:

```yaml
      - name: Check budget before retry
        if: steps.strategy.outputs.should_retry == 'true'
        id: budget
        run: |
          # Ensure Shipwright is available
          if command -v shipwright &>/dev/null || [ -x ./node_modules/.bin/sw ]; then
            REMAINING=$(shipwright cost remaining-budget 2>/dev/null || echo "100")
          else
            REMAINING="100"
          fi
          echo "remaining=$REMAINING" >> "$GITHUB_OUTPUT"
          if [ "$(echo "$REMAINING < 10" | bc 2>/dev/null || echo "0")" -eq 1 ]; then
            echo "Budget too low (\$$REMAINING remaining), skipping retry"
            echo "skip=true" >> "$GITHUB_OUTPUT"
          else
            echo "Budget OK (\$$REMAINING remaining)"
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Dispatch retry pipeline
        if: steps.strategy.outputs.should_retry == 'true' && steps.budget.outputs.skip != 'true'
```

with:

```yaml
      - name: Dispatch retry pipeline
        if: steps.strategy.outputs.should_retry == 'true' && steps.gates.outputs.allowed == 'true'
```

- [ ] **Step 6: Lint the workflows and run the workflow rule**

```bash
actionlint -ignore 'SC2086:info' -ignore 'SC2129:style' .github/workflows/shipwright-dispatch.yml .github/workflows/shipwright-watchdog.yml .github/workflows/shipwright-auto-retry.yml; echo "actionlint=$?"
bun tools/arch/workflow-injection.ts; echo "injection=$?"
grep -c 'gh issue view' .github/workflows/shipwright-auto-retry.yml || true
```

Expected: `actionlint=0` (the two ignored codes are the 4 SC2086 infos and 3 SC2129 styles already present before this change); `injection=0`; `0` (no unfiltered comment reads left in auto-retry).

- [ ] **Step 7: Run the definition of done**

```bash
bun run format && git add -A .github && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 8: Commit**

```bash
git add -A .github
git commit -m "ci: gate dispatch and auto-retry, skip auto-filed issues; watchdog only cancels"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 15: Dashboard hardening and its typecheck

**Files:**
- Create: `dashboard/services/request-guard.ts`, `dashboard/tsconfig.server.json`, `tools/arch/rules/dashboard-no-shell-from-data.yml`, `tools/arch/rule-tests/dashboard-no-shell-from-data-test.yml`
- Modify: `dashboard/server.ts`, `dashboard/src/core/api.ts`, `dashboard/src/core/api.test.ts`, `package.json`
- Test: `dashboard/services/request-guard.test.ts`, `dashboard/src/core/api.test.ts`

All request policy lives in one pure module, `dashboard/services/request-guard.ts`, which `server.ts` calls before routing (`guardRequest`) and on every response (`withCors`). To do that, the 3,100-line `fetch` method body moves out of the `Bun.serve` options into `async function routeRequest(req, server)` with three text edits; the body itself is unchanged (it stays indented one level deeper — cosmetic). The browser client already sends JSON from `post/patch/del`; its raw `request()` calls (approve/reject gates, webhooks, claim/release, team invite) now default to `Content-Type: application/json`. The team view's claim/release keeps working through a signed-in session. Typechecking `server.ts`, `services/` and `middleware/` (now part of `bun run typecheck`, so CI's Typecheck step covers it) needs three small fixes with no behavior change: two fields the predictions route reads but nothing sets become optional (both read as 0 today), and the WebSocket data type is declared. The interim rule from spec §3.3 lands here: in `dashboard/` (not the browser bundle in `dashboard/src`), `execSync`/`exec` take only a constant string literal, no `shell: true`, no `Bun.$`. The existing constant `execSync` calls pass; Wave 3 removes them.

- [ ] **Step 1: Write the failing guard test**

```ts
// @vitest-environment node
// (happy-dom drops the Origin header, which these tests need.)
import { describe, expect, it } from "vitest";
import {
  type GuardConfig,
  guardRequest,
  isFleetRoute,
  loadGuardConfig,
  presentedToken,
  startupProblem,
  tokenMatches,
  withCors,
} from "./request-guard";

const LOCAL = "http://localhost:8767";
const JSON_CT = { "Content-Type": "application/json" };
const cfg = (over: Partial<GuardConfig> = {}): GuardConfig => ({
  fleetToken: "",
  host: "127.0.0.1",
  allowedOrigins: [LOCAL],
  ...over,
});
const req = (method: string, path: string, headers: Record<string, string> = {}) =>
  new Request(`http://127.0.0.1:8767${path}`, {
    method,
    headers,
    body: method === "GET" ? undefined : "{}",
  });
const guard = (r: Request, c: GuardConfig = cfg(), hasSession = false) =>
  guardRequest(r, c, hasSession);

describe("loadGuardConfig", () => {
  it("allows the local origins plus SW_DASHBOARD_ORIGINS", () => {
    const c = loadGuardConfig(
      { SHIPWRIGHT_FLEET_TOKEN: "t", SW_DASHBOARD_ORIGINS: " https://a.example , " },
      "0.0.0.0",
      9000,
    );
    expect(c).toEqual({
      fleetToken: "t",
      host: "0.0.0.0",
      allowedOrigins: ["http://localhost:9000", "http://127.0.0.1:9000", "https://a.example"],
    });
  });
});

describe("startupProblem", () => {
  it("allows anything on loopback", () => {
    expect(startupProblem(cfg(), false)).toBeNull();
  });
  it("refuses auth=none on a public address", () => {
    expect(startupProblem(cfg({ host: "0.0.0.0" }), false)).toMatch(/auth=none/);
  });
  it("refuses a public address without a fleet token", () => {
    expect(startupProblem(cfg({ host: "0.0.0.0" }), true)).toMatch(/SHIPWRIGHT_FLEET_TOKEN/);
  });
  it("accepts a public address with auth and a fleet token", () => {
    expect(startupProblem(cfg({ host: "0.0.0.0", fleetToken: "t" }), true)).toBeNull();
  });
});

describe("guardRequest", () => {
  it("lets GETs through", () => {
    expect(guard(req("GET", "/api/status"))).toBeNull();
  });
  it("rejects a non-JSON POST with 415", () => {
    const r = guard(req("POST", "/api/daemon/pause", { "Content-Type": "text/plain" }));
    expect(r?.status).toBe(415);
  });
  it("accepts a JSON POST with a charset parameter", () => {
    const ct = { "Content-Type": "application/json; charset=utf-8" };
    expect(guard(req("POST", "/api/daemon/pause", ct))).toBeNull();
  });
  it("exempts the login form under /auth/", () => {
    const form = { "Content-Type": "application/x-www-form-urlencoded" };
    expect(guard(req("POST", "/auth/pat-login", form))).toBeNull();
  });
  it("rejects a mutating request from a foreign origin with 403", () => {
    const r = guard(req("POST", "/api/daemon/stop", { ...JSON_CT, Origin: "https://evil.example" }));
    expect(r?.status).toBe(403);
  });
  it("allows a same-origin mutating request", () => {
    expect(guard(req("POST", "/api/daemon/stop", { ...JSON_CT, Origin: LOCAL }))).toBeNull();
  });
  it("allows a fleet route without a token only when none is set on loopback", () => {
    expect(guard(req("POST", "/api/claim", JSON_CT))).toBeNull();
    expect(guard(req("POST", "/api/claim", JSON_CT), cfg({ host: "0.0.0.0" }))?.status).toBe(401);
  });
  it.each(["/api/claim", "/api/claim/release", "/api/connect/heartbeat", "/api/webhook/ci"])(
    "requires the fleet token on %s once one is configured",
    (path) => {
      const c = cfg({ fleetToken: "s3cret" });
      expect(guard(req("POST", path, JSON_CT), c)?.status).toBe(401);
      const wrong = { ...JSON_CT, "X-Shipwright-Token": "nope00" };
      expect(guard(req("POST", path, wrong), c)?.status).toBe(401);
      const right = { ...JSON_CT, "X-Shipwright-Token": "s3cret" };
      expect(guard(req("POST", path, right), c)).toBeNull();
      const bearer = { ...JSON_CT, Authorization: "Bearer s3cret" };
      expect(guard(req("POST", path, bearer), c)).toBeNull();
    },
  );
  it("lets a signed-in dashboard session use fleet routes without the token", () => {
    const c = cfg({ host: "0.0.0.0", fleetToken: "s3cret" });
    expect(guard(req("POST", "/api/claim", JSON_CT), c, true)).toBeNull();
  });
});

describe("helpers", () => {
  it("classifies fleet routes", () => {
    expect(isFleetRoute("/api/connect/disconnect")).toBe(true);
    expect(isFleetRoute("/api/claims")).toBe(false);
  });
  it("reads the token header before Authorization", () => {
    const r = req("GET", "/", { "X-Shipwright-Token": "a", Authorization: "Bearer b" });
    expect(presentedToken(r)).toBe("a");
    expect(presentedToken(req("GET", "/"))).toBeNull();
  });
  it("compares tokens exactly", () => {
    expect(tokenMatches("abc", "abc")).toBe(true);
    expect(tokenMatches("abc", "abd")).toBe(false);
    expect(tokenMatches("abc", "ab")).toBe(false);
    expect(tokenMatches("abc", null)).toBe(false);
  });
});

describe("withCors", () => {
  it("echoes an allowed origin and never sends *", () => {
    const res = withCors(new Response("ok"), req("GET", "/", { Origin: LOCAL }), cfg());
    expect(res?.headers.get("Access-Control-Allow-Origin")).toBe(LOCAL);
    expect(res?.headers.get("Vary")).toContain("Origin");
  });
  it("adds nothing for a foreign or missing origin", () => {
    const foreign = withCors(new Response("ok"), req("GET", "/", { Origin: "https://x.y" }), cfg());
    expect(foreign?.headers.get("Access-Control-Allow-Origin")).toBeNull();
    const none = withCors(new Response("ok"), req("GET", "/"), cfg());
    expect(none?.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
  it("passes a WebSocket upgrade (undefined) through", () => {
    expect(withCors(undefined, req("GET", "/ws", { Origin: LOCAL }), cfg())).toBeUndefined();
  });
});
```

```bash
bunx vitest run --config dashboard/vitest.config.ts services/request-guard.test.ts
```

Expected: FAIL — vitest cannot resolve `./request-guard` (`Failed to load url ./request-guard`).

- [ ] **Step 2: Implement `dashboard/services/request-guard.ts`**

```ts
// Request guard for the dashboard (spec §6.2 "Dashboard exposure", ADR-0007).
// Pure: no environment reads and no I/O. server.ts builds the config at startup and calls
// guardRequest() before any route and withCors() on every response.

export interface GuardConfig {
  /** Shared fleet token (SHIPWRIGHT_FLEET_TOKEN). Empty when none is configured. */
  readonly fleetToken: string;
  /** Address the server binds to. */
  readonly host: string;
  /** Exact origins allowed for CORS and for mutating browser requests. */
  readonly allowedOrigins: readonly string[];
}

export const TOKEN_HEADER = "x-shipwright-token";
const MUTATING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
const LOOPBACK = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

export function isLoopbackHost(host: string): boolean {
  return LOOPBACK.has(host.toLowerCase());
}

/** Fleet worker routes: claims, connect presence and CI webhooks. Browsers never call these. */
export function isFleetRoute(pathname: string): boolean {
  return (
    pathname === "/api/claim" ||
    pathname === "/api/claim/release" ||
    pathname.startsWith("/api/connect/") ||
    pathname === "/api/webhook/ci"
  );
}

export function loadGuardConfig(
  env: Readonly<Record<string, string | undefined>>,
  host: string,
  port: number,
): GuardConfig {
  const extra = (env.SW_DASHBOARD_ORIGINS ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter((o) => o.length > 0);
  return {
    fleetToken: env.SHIPWRIGHT_FLEET_TOKEN ?? "",
    host,
    allowedOrigins: [`http://localhost:${port}`, `http://127.0.0.1:${port}`, ...extra],
  };
}

/** Why the server must not start with this config, or null. auth=none is loopback-only. */
export function startupProblem(cfg: GuardConfig, authEnabled: boolean): string | null {
  if (isLoopbackHost(cfg.host)) return null;
  if (!authEnabled) {
    return `refusing to bind ${cfg.host} with auth=none: configure GITHUB_PAT + DASHBOARD_REPO (or OAuth), or bind 127.0.0.1`;
  }
  if (!cfg.fleetToken) {
    return `refusing to bind ${cfg.host} without SHIPWRIGHT_FLEET_TOKEN: /api/claim, /api/connect/* and /api/webhook/ci would be unauthenticated`;
  }
  return null;
}

/** The token a fleet worker presented: `X-Shipwright-Token`, else `Authorization: Bearer`. */
export function presentedToken(req: Request): string | null {
  const header = req.headers.get(TOKEN_HEADER);
  if (header) return header;
  const auth = req.headers.get("authorization") ?? "";
  return auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : null;
}

/** Constant-time comparison so response timing does not leak the token. */
export function tokenMatches(expected: string, given: string | null): boolean {
  if (given === null || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

const reject = (status: number, error: string): Response =>
  new Response(JSON.stringify({ error }), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function isJson(req: Request): boolean {
  const type = (req.headers.get("content-type") ?? "").split(";")[0] ?? "";
  return type.trim().toLowerCase() === "application/json";
}

function fleetAuth(req: Request, cfg: GuardConfig, hasSession: boolean): Response | null {
  if (hasSession) return null; // a signed-in dashboard user (team view claim/release)
  if (!cfg.fleetToken) {
    return isLoopbackHost(cfg.host) ? null : reject(401, "fleet token not configured");
  }
  return tokenMatches(cfg.fleetToken, presentedToken(req))
    ? null
    : reject(401, "missing or invalid fleet token");
}

/**
 * A rejection, or null when the request may be routed. Mutating requests must be JSON (so a
 * cross-site form cannot post without a CORS preflight) and, when a browser names an origin, come
 * from an allowed one. Fleet routes need the fleet token or a signed-in session, except on
 * loopback with no token configured. `hasSession`: auth is enabled and the request has a session.
 */
export function guardRequest(req: Request, cfg: GuardConfig, hasSession: boolean): Response | null {
  const { pathname } = new URL(req.url);
  if (MUTATING.has(req.method)) {
    const origin = req.headers.get("origin");
    if (origin !== null && !cfg.allowedOrigins.includes(origin)) {
      return reject(403, "origin not allowed");
    }
    if (!pathname.startsWith("/auth/") && !isJson(req)) {
      return reject(415, "mutating requests must be application/json");
    }
  }
  return isFleetRoute(pathname) ? fleetAuth(req, cfg, hasSession) : null;
}

/** Adds `Access-Control-Allow-Origin` for allowed origins only (never `*`). */
export function withCors(
  res: Response | undefined,
  req: Request,
  cfg: GuardConfig,
): Response | undefined {
  const origin = req.headers.get("origin");
  if (!res || origin === null || !cfg.allowedOrigins.includes(origin)) return res;
  const out = new Response(res.body, res);
  out.headers.set("Access-Control-Allow-Origin", origin);
  out.headers.append("Vary", "Origin");
  return out;
}
```

```bash
bunx vitest run --config dashboard/vitest.config.ts services/request-guard.test.ts
```

Expected: `Tests  23 passed (23)`.

- [ ] **Step 3: Add the server typecheck and see it fail**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Preserve",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "types": ["bun-types"]
  },
  "files": ["server.ts"],
  "include": ["services/**/*.ts", "middleware/**/*.ts"],
  "exclude": ["services/**/*.test.ts"]
}
```

In `package.json`, replace:

```json
"typecheck": "tsc -p tsconfig.json",
```

with:

```json
"typecheck": "tsc -p tsconfig.json && tsc -p dashboard/tsconfig.server.json",
```

```bash
bunx tsc -p dashboard/tsconfig.server.json
```

Expected: FAIL — exactly three errors: `server.ts(2750,11): error TS2322` (WebSocket `data`), `server.ts(4347,25): error TS2551: Property 'total_spent' does not exist on type 'CostInfo'`, `server.ts(4350,62): error TS2339: Property 'cost' does not exist on type 'Pipeline'`.

- [ ] **Step 4: Wire the guard into `dashboard/server.ts` and fix the three type errors**

In `dashboard/server.ts`, replace:

```ts
} from "./services/subprocess-guards.js";
import { Database } from "bun:sqlite";
```

with:

```ts
} from "./services/subprocess-guards.js";
import {
  guardRequest,
  loadGuardConfig,
  startupProblem,
  withCors,
} from "./services/request-guard.js";
import { Database } from "bun:sqlite";
```

In `dashboard/server.ts`, replace:

```ts
  testsPassing: boolean;
}

interface QueueItem
```

with:

```ts
  testsPassing: boolean;
  /** Not populated today; the predictions route reads it (so it is always 0). */
  cost?: number;
}

interface QueueItem
```

In `dashboard/server.ts`, replace:

```ts
interface CostInfo {
  today_spent: number;
```

with:

```ts
interface CostInfo {
  /** Not populated today; the predictions route reads it (so it is always 0). */
  total_spent?: number;
  today_spent: number;
```

In `dashboard/server.ts`, replace:

```ts
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

const server = Bun.serve({
  port: PORT,
  hostname: HOST,

  async fetch(req, server) {
    const url = new URL(req.url);
```

with:

```ts
// Access-Control-Allow-Origin is added per request by withCors(), for allowlisted origins only.
const CORS_HEADERS = {
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Shipwright-Token, Authorization",
};

type WsData = { type?: string; lastEventId?: number } | undefined;

// Request guard (spec §6.2, ADR-0007): token on fleet routes, JSON-only mutations, CORS
// allowlist, and auth=none only on loopback.
const GUARD = loadGuardConfig(process.env, HOST, PORT);
const guardProblem = startupProblem(GUARD, isAuthEnabled());
if (guardProblem) {
  console.error(`✗ dashboard: ${guardProblem}`);
  process.exit(1);
}

async function routeRequest(
  req: Request,
  server: Bun.Server<WsData>,
): Promise<Response | undefined> {
    const url = new URL(req.url);
```

In `dashboard/server.ts`, replace:

```ts
        const upgraded = server.upgrade(req);
```

with:

```ts
        const upgraded = server.upgrade(req, { data: undefined });
```

In `dashboard/server.ts`, replace:

```ts
    return new Response("Not Found", { status: 404 });
  },

  websocket: {
```

with:

```ts
    return new Response("Not Found", { status: 404 });
}

const server = Bun.serve<WsData>({
  port: PORT,
  hostname: HOST,

  async fetch(req, server) {
    const hasSession = isAuthEnabled() && getSession(req) !== null;
    const blocked = guardRequest(req, GUARD, hasSession);
    if (blocked) return withCors(blocked, req, GUARD);
    return withCors(await routeRequest(req, server), req, GUARD);
  },

  websocket: {
```

```bash
bun run typecheck
```

Expected: both `tsc` runs pass with no errors.

- [ ] **Step 5: The browser client sends JSON on every mutating request**

In `dashboard/src/core/api.ts`, replace:

```ts
async function request<T>(url: string, options?: RequestInit): Promise<T> {
  const resp = await fetch(url, options);
```

with:

```ts
// The server rejects mutating requests that are not application/json (ADR-0007).
function withJsonContentType(options?: RequestInit): RequestInit | undefined {
  const method = (options?.method ?? "GET").toUpperCase();
  if (method === "GET" || method === "HEAD") return options;
  const headers = (options?.headers ?? {}) as Record<string, string>;
  if (Object.keys(headers).some((h) => h.toLowerCase() === "content-type")) return options;
  return { ...options, headers: { ...headers, "Content-Type": "application/json" } };
}

async function request<T>(url: string, options?: RequestInit): Promise<T> {
  const resp = await fetch(url, withJsonContentType(options));
```

Five exact-call assertions in `dashboard/src/core/api.test.ts` now see the header. In each block below, add the `headers` line after the `method` line:

In `dashboard/src/core/api.test.ts`, replace:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/approve", {
        method: "POST",
        body: JSON.stringify({ stage: "build" }),
```

with:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/approve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ stage: "build" }),
```

In `dashboard/src/core/api.test.ts`, replace:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/reject", {
        method: "POST",
        body: JSON.stringify({ stage: "build", reason: "Failed QA" }),
```

with:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/reject", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ stage: "build", reason: "Failed QA" }),
```

In `dashboard/src/core/api.test.ts`, replace:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "DELETE",
        body: JSON.stringify({ url: "https://slack.com/hook" }),
```

with:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: "https://slack.com/hook" }),
```

In `dashboard/src/core/api.test.ts`, replace:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/claim/release", {
        method: "POST",
        body: JSON.stringify({ issue: 42, machine: "m1" }),
```

with:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/claim/release", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ issue: 42, machine: "m1" }),
```

In `dashboard/src/core/api.test.ts`, replace:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "POST",
        body: JSON.stringify({
```

with:

```ts
      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
```

```bash
bunx vitest run --config dashboard/vitest.config.ts
```

Expected: `Test Files  18 passed (18)` and `Tests  378 passed (378)`.

- [ ] **Step 6: Add the interim dashboard rule (spec §3.3) with its test**

```yaml
id: dashboard-no-shell-from-data
valid:
  - 'execSync("git rev-parse --show-toplevel", { encoding: "utf-8" });'
  - 'execSync("nproc");'
  - 'execFileSync("gh", ["issue", "view", String(n)], { timeout: 5000 });'
  - 'spawn("ssh", sshArgv(host, cmd), { stdio: "pipe" });'
  - 'db.exec("PRAGMA journal_mode=WAL;");'
invalid:
  - 'execSync(`gh issue view ${n}`);'
  - 'execSync("gh issue view " + n, { encoding: "utf-8" });'
  - 'execSync(cmd);'
  - 'exec(`kill ${pid}`, cb);'
  - 'spawn("sh", ["-c", c], { shell: true });'
  - 'execFileSync("git", args, { cwd, shell: true });'
  - 'await Bun.$`git log ${ref}`;'
```

```yaml
id: dashboard-no-shell-from-data
language: TypeScript
severity: error
message: "Dashboard: run subprocesses with execFileSync/spawn and an argv array. A shell command must be a constant string literal; never build one from data (#8534, spec §3.3 interim rule until the Wave 3 port)."
files:
  - "dashboard/**/*.ts"
ignores:
  - "dashboard/**/*.test.ts"
  - "dashboard/src/**"
rule:
  any:
    # execSync / exec with anything but a plain string literal as the command
    - all:
        - any:
            - pattern: execSync($CMD, $$$)
            - pattern: execSync($CMD)
            - pattern: exec($CMD, $$$)
            - pattern: exec($CMD)
        - not:
            has:
              field: arguments
              has:
                nthChild: 1
                kind: string
    # spawn / execFile with shell: true
    - all:
        - any:
            - pattern: spawn($$$)
            - pattern: spawnSync($$$)
            - pattern: execFile($$$)
            - pattern: execFileSync($$$)
        - has:
            field: arguments
            has:
              kind: object
              has:
                kind: pair
                regex: '^shell\s*:\s*true$'
    # Bun shell
    - pattern: Bun.$
```

```bash
bunx ast-grep test --skip-snapshot-tests
printf 'import { execSync } from "child_process";\nexport const f = (n: string) => execSync(`echo ${n}`);\n' > dashboard/services/zz-probe.ts
bunx ast-grep scan; echo "exit=$?"
rm dashboard/services/zz-probe.ts
bunx ast-grep scan; echo "exit=$?"
```

Expected: `PASS dashboard-no-shell-from-data` and `test result: ok. 5 passed; 0 failed;`; the probe scan reports `error[dashboard-no-shell-from-data]` and `exit=1`; after deleting it, `exit=0` (every remaining `execSync` in `server.ts` takes a constant string).

- [ ] **Step 7: Smoke-test the hardened server on loopback with a token**

```bash
T=$(mktemp -d); mkdir -p "$T/.shipwright"
(HOME=$T SHIPWRIGHT_FLEET_TOKEN=s3cret bun dashboard/server.ts 18997 > "$T/srv.log" 2>&1 &)
sleep 3
curl -s -o /dev/null -w 'health=%{http_code}\n' http://127.0.0.1:18997/api/health
curl -s -o /dev/null -w 'claim-no-token=%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18997/api/claim
curl -s -o /dev/null -w 'text-post=%{http_code}\n' -X POST -d x http://127.0.0.1:18997/api/daemon/pause
curl -s -o /dev/null -w 'foreign-origin=%{http_code}\n' -X POST -H 'Origin: https://evil.example' -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18997/api/daemon/pause
curl -s -D - -o /dev/null -H 'Origin: http://localhost:18997' http://127.0.0.1:18997/api/health | grep -i '^access-control-allow-origin'
pkill -f 'dashboard/server.ts 18997'
(HOME=$T SW_DASHBOARD_HOST=0.0.0.0 bun dashboard/server.ts 18996; echo "public-noauth-exit=$?")
```

Expected: `health=200`, `claim-no-token=401`, `text-post=415`, `foreign-origin=403`, `Access-Control-Allow-Origin: http://localhost:18997`; then `✗ dashboard: refusing to bind 0.0.0.0 with auth=none: …` and `public-noauth-exit=1`.

- [ ] **Step 8: Run the definition of done**

```bash
bun run format && git add -A dashboard package.json tools/arch/rules/dashboard-no-shell-from-data.yml tools/arch/rule-tests/dashboard-no-shell-from-data-test.yml && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 9: Commit**

```bash
git add -A dashboard package.json tools/arch/rules/dashboard-no-shell-from-data.yml tools/arch/rule-tests/dashboard-no-shell-from-data-test.yml
git commit -m "fix(dashboard): fleet token, JSON-only mutations, CORS allowlist, server typecheck"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 16: Fleet workers send the token

**Files:**
- Modify: `scripts/lib/safety-gates.sh`, `scripts/sw-lib-safety-gates-test.sh`, `scripts/lib/daemon-state.sh`, `scripts/sw-connect.sh`, `scripts/sw-connect-test.sh`

The daemon's claim/release calls (`scripts/lib/daemon-state.sh`) and the connect heartbeat/disconnect (`scripts/sw-connect.sh`) now send `X-Shipwright-Token: $SHIPWRIGHT_FLEET_TOKEN`. `fleet_curl` passes the header on stdin (`curl -H @-`, curl ≥ 7.55), so the token never appears in argv or `ps`; with no token set, no header is sent and loopback dashboards keep working. Set the same `SHIPWRIGHT_FLEET_TOKEN` on the dashboard host and every worker.

- [ ] **Step 1: Add the failing `fleet_curl` tests**

In `scripts/sw-lib-safety-gates-test.sh`, replace the final line (the fleet section goes before it):

```bash
print_test_results
```

with:

```bash
# ─── fleet_curl ───────────────────────────────────────────────────────────
print_test_section "fleet_curl"

SHIPWRIGHT_FLEET_TOKEN="s3cret-token" fleet_curl -s -X POST "http://127.0.0.1:8767/api/claim"
assert_contains "token sent as a header on stdin" "$(cat "$CURL_STDIN")" \
    "X-Shipwright-Token: s3cret-token"
assert_contains "curl reads headers from stdin" "$(cat "$CURL_ARGS")" "@-"
assert_eq "token never in argv" "0" "$(grep -c 's3cret-token' "$CURL_ARGS" || true)"

print_test_results
```

```bash
bash scripts/sw-lib-safety-gates-test.sh
```

Expected: FAIL — `fleet_curl: command not found`, then the ERR trap exits non-zero.

- [ ] **Step 2: Append `fleet_curl` to `scripts/lib/safety-gates.sh`**

```bash
# fleet_curl <curl args...> — curl with the fleet token header ($SHIPWRIGHT_FLEET_TOKEN), passed
# on stdin so it never appears in argv or `ps`. An empty token sends no header.
fleet_curl() {
    printf 'X-Shipwright-Token: %s\n' "${SHIPWRIGHT_FLEET_TOKEN:-}" | curl -H @- "$@"
}
```

```bash
bash scripts/sw-lib-safety-gates-test.sh
```

Expected: `All 19 tests passed`.

- [ ] **Step 3: Send the token from the daemon's claim and release**

In `scripts/lib/daemon-state.sh`, replace:

```bash
[[ -n "${_DAEMON_STATE_LOADED:-}" ]] && return 0
_DAEMON_STATE_LOADED=1
```

with:

```bash
[[ -n "${_DAEMON_STATE_LOADED:-}" ]] && return 0
_DAEMON_STATE_LOADED=1
# shellcheck source=safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety-gates.sh"
```

In `scripts/lib/daemon-state.sh`, replace:

```bash
        resp=$(curl -s --max-time 5 -X POST "${DASHBOARD_URL}/api/claim" \
```

with:

```bash
        resp=$(fleet_curl -s --max-time 5 -X POST "${DASHBOARD_URL}/api/claim" \
```

In `scripts/lib/daemon-state.sh`, replace:

```bash
    curl -s --max-time 5 -X POST "${DASHBOARD_URL}/api/claim/release" \
```

with:

```bash
    fleet_curl -s --max-time 5 -X POST "${DASHBOARD_URL}/api/claim/release" \
```

- [ ] **Step 4: Send the token from connect**

In `scripts/sw-connect.sh`, replace:

```bash
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
```

with:

```bash
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/safety-gates.sh
[[ -f "$SCRIPT_DIR/lib/safety-gates.sh" ]] && source "$SCRIPT_DIR/lib/safety-gates.sh"
```

In `scripts/sw-connect.sh`, replace:

```bash
        http_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
```

with:

```bash
        http_code="$(fleet_curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
```

In `scripts/sw-connect.sh`, replace:

```bash
    curl -s -o /dev/null --max-time 5 \
        -X POST \
```

with:

```bash
    fleet_curl -s -o /dev/null --max-time 5 \
        -X POST \
```

`sw-connect-test.sh` copies `sw-connect.sh` and its libraries into a temp dir; copy the new library too:

In `scripts/sw-connect-test.sh`, replace:

```bash
    [[ -f "$SCRIPT_DIR/lib/config.sh" ]] && cp "$SCRIPT_DIR/lib/config.sh" "$TEST_TEMP_DIR/lib/" 2>/dev/null || true
```

with:

```bash
    [[ -f "$SCRIPT_DIR/lib/config.sh" ]] && cp "$SCRIPT_DIR/lib/config.sh" "$TEST_TEMP_DIR/lib/" 2>/dev/null || true
    cp "$SCRIPT_DIR/lib/safety-gates.sh" "$TEST_TEMP_DIR/lib/"
```

- [ ] **Step 5: Syntax, shellcheck (as CI) and the hermetic suites**

```bash
for f in scripts/lib/safety-gates.sh scripts/lib/daemon-state.sh scripts/sw-connect.sh scripts/sw-connect-test.sh; do bash -n "$f" || echo "SYNTAX $f"; done
shellcheck -x -S warning -e SC2034,SC1090,SC2148,SC2119,SC2120 scripts/sw scripts/sw-*.sh install.sh scripts/lib/safety-gates.sh scripts/lib/daemon-state.sh; echo "shellcheck=$?"
for p in lib-safety-gates sw-connect-test lib-daemon-state; do bash scripts/sw-test-all.sh --pattern "$p" > "/tmp/sw-$p.log" 2>&1; echo "$p=$?"; done
```

Expected: no `SYNTAX` lines; `shellcheck=0` (CI's exact file set plus the two libraries); `lib-safety-gates=0`, `sw-connect-test=0`, `lib-daemon-state=0`.

- [ ] **Step 6: Run the definition of done**

```bash
bun run format && git add -A scripts && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 7: Commit**

```bash
git add -A scripts
git commit -m "feat(fleet): send the fleet token from daemon claims and connect"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 17: ADR-0007 and agent guidance

**Files:**
- Create: `docs/adr/0007-safety-controls.md`
- Modify: `AGENTS.md`, `docs/architecture.md`, `.claude/rules/workflows.md`

- [ ] **Step 1: Write `docs/adr/0007-safety-controls.md` (write-adr format, under 60 lines)**

```markdown
# 0007. Safety controls gate every dispatch

Status: accepted · Date: 2026-10-14

## Context
On 2026-10-13 every pipeline run failed (199 of 199 in 24 hours), retries re-dispatched the same
failures, and patrol had filed ~720 open issues. Per-issue retry caps did not stop a global loop, and
the only kill switch was disabling three workflows by hand. Spec §6.2 requires the safety controls
before any delivery-loop port, and the SQLite durability adapter (Wave 1b) does not exist yet.

## Decision
The controls live in the `orchestration` context as pure policies over ports. Callers run one command,
`shipwright gates check [--attempt N] [--no-github]`, which evaluates in this order and stops at the
first closed gate: **pause → breaker → budget → review WIP → fix loop**. A source that cannot be read
closes its gate, and a missing Bun closes all of them (fail closed). The dispatch, watchdog and
auto-retry workflows call it through `.github/actions/safety-gates`; the bash daemon calls it in
`daemon_spawn_pipeline`.

- **Breaker:** recomputed on every check from the last 50 `shipwright-pipeline.yml` runs, so every
  machine and CI agree without shared state. It opens when at least 5 of the last 8 finished runs
  failed (`failure`, `timed_out`, `startup_failure`; cancelled and skipped runs are not counted).
  After 30 minutes, one probe (a run created after the cool-down) is allowed. A probe success closes
  it and a failure re-opens it. While open, it keeps one `shipwright:incident` issue, written once
  per trip under the key `breaker:open:<opened-at>`.
- **Pause:** the bash daemon's flag `~/.shipwright/daemon-pause.flag`, or the `shipwright:pause` label
  on any open issue (which stops every machine and CI).
- **Budget:** the daily UTC cap and spend from `budget.json` and `costs.json` (as `sw-cost.sh`).
  Dispatch stops when spend plus the estimate reaches the cap; no cap means unlimited.
- **Review WIP:** open, non-draft, unapproved agent PRs (author `app/github-actions` or label
  `shipwright`) plus queued and running pipeline runs must stay under 5.
- **Fix loop:** retry attempts 1–3 pass; the 4th escalates to a human.
- **Intake:** patrol files an issue only while fewer than 25 `auto-patrol` issues are open and no
  open issue has the same title fingerprint.
- **Auto-filed issues:** the dispatch workflow and the daemon skip any issue labelled `auto-patrol`.
  A human opts one in by removing that label (`ready-to-build` cannot be the opt-in: automation adds it).
- **Retries:** auto-retry is the only retry path. The watchdog cancels stuck runs and comments. For a
  run silent over 2 hours it posts `SHIPWRIGHT-WATCHDOG-ABANDON` before cancelling; auto-retry skips it.
- Workflows read `SHIPWRIGHT-*` markers only from comments by `github-actions[bot]` (type `Bot`),
  or by `$SHIPWRIGHT_BOT_LOGIN` when a GitHub App token is used.
- The thresholds are the `DEFAULT_*_POLICY` constants until the zod config adapter lands.

The incident issue is the first F10 method: `GithubWriter.ensureIncident(key, report)` in
`src/adapters/github/gh-github-writer.ts` reconciles against the key stored in the issue before it
writes. An ast-grep rule keeps `gh` write subcommands out of every other file. It takes no
`FenceToken`: no lease covers a system-wide incident. Run-scoped writes take one from Wave 1b.

The dashboard requires `SHIPWRIGHT_FLEET_TOKEN` (or a signed-in session) on `/api/claim*`,
`/api/connect/*` and `/api/webhook/ci`. It accepts only JSON for mutating requests, allows CORS only
for listed origins, and refuses to bind a non-loopback address with auth `none` or without the token.

## Consequences
- The three disabled workflows can be re-enabled behind one gate, and the composition is tested in
  one place.
- Each check costs about five GitHub API calls; intake lists every open issue (~7 s).
- Local daemon outcomes do not feed the breaker until the run journal exists (Wave 1b).
- In CI the budget gate is a no-op, because runners have no cost files; a CI budget source is
  deferred to Wave 1b/1c. The local gate stays.
- A fingerprint misses paraphrased duplicates. A semantic dedupe replaces it later.
```

- [ ] **Step 2: Update `AGENTS.md` (F10 is now enforced in part; the gates are the way to dispatch)**

In `AGENTS.md`, replace:

```markdown
F7 files ≤ 300 lines, functions ≤ 40 (baseline only shrinks) · F8 tests use `createTestEnv()`, never real paths.

Follow now; enforced later: F9 agents get no GitHub token and no permission bypass (from Wave 1) ·
F10 GitHub side effects only through the fenced, idempotent `integrations` adapter (from Wave 1 for
the first GitHub-writing port method; every integration by the end of Wave 2).
```

with:

```markdown
F7 files ≤ 300 lines, functions ≤ 40 (baseline only shrinks) · F8 tests use `createTestEnv()`, never real paths ·
F10 `gh` write subcommands only in `src/adapters/github/gh-github-writer.ts` · dashboard: no shell
command built from data (interim, until the dashboard is ported).

Follow now; enforced later: F9 agents get no GitHub token and no permission bypass (from Wave 1) ·
F10 in full: every `integrations` write method also takes a `FenceToken` (run-scoped writes, from
Wave 1b), and every integration goes through it by the end of Wave 2.
```

In `AGENTS.md`, replace:

```markdown
- Tests use `createTestEnv()`; never touch the real `HOME`, `~/.shipwright` or tmux server.
```

with:

```markdown
- Tests use `createTestEnv()`; never touch the real `HOME`, `~/.shipwright` or tmux server.
- Dispatch, retries and patrol filing pass `shipwright gates check` / `shipwright intake check` first;
  workflows read `SHIPWRIGHT-*` markers only through `scripts/ci/bot-comments.sh` (ADR-0007).
```

- [ ] **Step 3: Link the ADR from `docs/architecture.md`**

In `docs/architecture.md`, replace:

```markdown
- 0006 Credentials and capability separation (planned, Wave 1)
```

with:

```markdown
- 0006 Credentials and capability separation (planned, Wave 1)
- [0007 Safety controls gate every dispatch](adr/0007-safety-controls.md)
```

- [ ] **Step 4: Extend `.claude/rules/workflows.md`**

In `.claude/rules/workflows.md`, replace the last line:

```markdown
Pin new actions to a version tag.
```

with:

```markdown
Pin new actions to a version tag.
Gate every dispatch or retry with `.github/actions/safety-gates` or `bun src/cli.ts gates check`, and
read `SHIPWRIGHT-*` markers only through `scripts/ci/bot-comments.sh` (ADR-0007).
```

```bash
wc -l AGENTS.md docs/adr/0007-safety-controls.md
```

Expected: `78 AGENTS.md` (≤ 150) and `58 docs/adr/0007-safety-controls.md` (≤ 60).

- [ ] **Step 5: Run the definition of done**

```bash
bun run format && git add -A AGENTS.md docs .claude/rules/workflows.md && bun run check
```

Expected: every stage passes (typecheck, Biome, `bun run arch`, tests, `docs:check`, `port:check`); the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 6: Commit**

```bash
git add -A AGENTS.md docs .claude/rules/workflows.md
git commit -m "docs: ADR-0007 safety controls"
```

Expected: one new commit; `git status --short` prints nothing.

---

### Task 18: Independent verification, hand-off and the user-approved re-enable

**Files:** none

- [ ] **Step 1: Dispatch the `verifier` subagent**

Prompt: "Verify Wave 1a on branch `wave1/safety` against `docs/superpowers/plans/2026-10-14-wave-1a-safety.md`. Run `bun run check`, `bunx vitest run --config dashboard/vitest.config.ts`, CI's shellcheck command, actionlint on the three workflows, and only the hermetic bash suites listed under Conventions. Try to break the gates: an unreadable source must block, a paused system must not write an incident, auto-retry must ignore a `SHIPWRIGHT-RETRY: 0` comment from a user and skip a run the watchdog abandoned, the watchdog must never dispatch, an `auto-patrol` issue must never be dispatched by the workflow or the daemon, no `${{ }}` inside `run:`, no `gh` write outside `gh-github-writer.ts`." Expected: `PASS` with evidence. On `FAIL`, fix and re-run, up to three cycles; then report what remains.

- [ ] **Step 2: Dispatch the `reviewer` subagent on `git diff docs/ts-migration-spec...HEAD`**

For each finding, fix it or explain why it does not apply.

- [ ] **Step 3: Ask the user before pushing**

Summarize the commits and the `bun run check` time. Push and open the PR only on an explicit yes. The PR base is `docs/ts-migration-spec` while #8535 is open, `main` after it merges:

```bash
git push -u origin wave1/safety
gh pr create --base docs/ts-migration-spec --title "Wave 1a: safety controls (breaker, kill switch, budget, intake, WIP, dashboard hardening)" \
  --body "Implements docs/superpowers/plans/2026-10-14-wave-1a-safety.md and ADR-0007. bun run check is green. The three disabled workflows are gated but stay disabled until the maintainer re-enables them.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Expected: the PR URL.

- [ ] **Step 4: Re-enable the workflows — MAINTAINER ONLY, after the PR merges to `main`**

Implementers do **not** run this step. It changes repository state and needs the maintainer's explicit approval. It is listed so the order is unambiguous:

```bash
# 1. Confirm the breaker's view of recent runs (read-only)
bun src/cli.ts breaker status
# 2. Create the kill-switch label so it can be applied to any issue in one click
gh label create shipwright:pause --color 000000 --description "Stops all Shipwright dispatch (ADR-0007)"
# 3. Optional: a daily budget for local daemons (CI runners have no cost files)
shipwright cost budget set 50
# 4. Fleet hosts: set the same SHIPWRIGHT_FLEET_TOKEN on the dashboard and on every worker
# 5. Re-enable, then watch the first scheduled runs
gh workflow enable shipwright-watchdog.yml
gh workflow enable shipwright-auto-retry.yml
gh workflow enable shipwright-dispatch.yml
gh run list --workflow shipwright-dispatch.yml --limit 3
```

Expected: the dispatch run logs show the five gate lines from `.github/actions/safety-gates`. While the breaker is open after the 2026-10-13 loop, dispatch skips and one `shipwright:incident` issue exists; the first probe after the cool-down decides whether it closes. Apply the `shipwright:pause` label (or run `shipwright pause` on a daemon host) to stop everything; remove it, or run `shipwright resume`, to lift it.
