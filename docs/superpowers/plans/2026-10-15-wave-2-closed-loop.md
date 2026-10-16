# Wave 2: Closed-Loop Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. **This is a plan.** Nothing here is implemented yet. Each tranche starts only after the maintainer accepts the open questions it depends on.

**Status:** proposed. Draft PR #8588, epic #8587. Supersedes the draft at `3a137b453`, which the independent review found NOT-READY as written. This revision restructures the work into tranches and expands Tranche 1 to the Wave 1a bar.

**Goal:** make Shipwright measure its delivery outcomes and change behaviour only when a measured change beats the incumbent, starting with the failures that stopped dispatch on 2026-10-13..15.

**Architecture:** pure policies in `src/contexts/*/domain` (F1: domain imports only its own domain and `src/shared/kernel`), use cases over ports in `application/` (F2), adapters in `src/adapters` (F5). Bash changes are one-line bridges to TypeScript commands; `run_ts` routes new commands in `scripts/sw`. Run state goes through the durability ports (ADR-0005) in later tranches.

**Tech stack:** Bun 1.2.19, TypeScript strict with `noUncheckedIndexedAccess`, zod 4 (adapters only), Biome, dependency-cruiser, ast-grep, bash 3.2, `gh`.

---

## How to read this plan

| Tranche | Keys | Scope | Detail level |
|---|---|---|---|
| 1 (P0, needs no ledger, unblocks dispatch; W2-06 and W2-20 wait for #8610) | W2-01 to W2-07, W2-20 | failure classification, auth retry, progress verdict, stall stop, wall-clock cap, model routing hygiene | **Exact code, tests, commands and expected output for every step.** |
| 2 | W2-08 to W2-12 | run ledger, CI ledger, decisions, routing and difficulty, CI cost and runtime budget | Task level, with the review fixes applied. Each task gets a full expansion before it starts. |
| 3 | W2-13 to W2-18 | eval corpus and paired ratchet, trusted replay, verifier stage, legacy retirement, holdout MVP, scorecard | Task level, with the review fixes applied. |
| Deferred | W2-19 | E5 fitter, full H2 fence, GitHub twin, merge tiers I1 to I3 and I5, self-improving harness (J) | Listed only. Each needs its own plan. |

**Evidence labels.** [V] verified by a fetch or by reading the repository; [J] a judgement; [U] unverified and not relied on.

---

## Key table

| Key | Tranche | Title | Blocks dispatch at scale? | Depends on |
|---|---|---|---|---|
| W2-01 | 1 | Incident fixtures | No (test input) | read-only `gh` access |
| W2-02 | 1 | Failure classifier core | Yes (stops deterministic retries) | none |
| W2-03 | 1 | Auto-retry: AUTH category, Bun before categorisation | Yes | W2-02 |
| W2-04 | 1 | Daemon classify bridge with bash fallback | Yes (local daemon) | W2-02 |
| W2-05 | 1 | Progress verdict and stall (TypeScript) | Yes | none |
| W2-06 | 1 | Loop stall stop, one progress comment, progress-aware watchdog, build wall-clock cap | Yes (silent runs) | W2-05; **#8610 merged** |
| W2-07 | 1 | Deterministic model routing hygiene | Yes (reproducible models) | none |
| W2-20 | 1 | Arch ratchet: real-service test suites gated on `SHIPWRIGHT_E2E_REAL` (after #8610) | No (protects the loop's test gate) | #8610 merged; issue created by the maintainer |
| W2-08 | 2 | Ledger core | No | W2-02 (decision shape) |
| W2-09 | 2 | Ledger on CI | No | W2-08 |
| W2-10 | 2 | Decisions in the ledger | No | W2-08 |
| W2-11 | 2 | Routing table and difficulty, tighten-only | No | W2-07, W2-08 |
| W2-12 | 2 | CI cost and runtime budget | Yes (CI budget) | W2-08, W2-11 |
| W2-13 | 3 | Eval corpus and paired ratchet rule | No (gates policy changes) | W2-08, W2-14 |
| W2-14 | 3 | Trusted replay and advisory ratchet | No | W2-13 |
| W2-15 | 3 | Verifier stage | No | sandbox and credential prerequisites |
| W2-16 | 3 | Retire legacy learners | No | W2-14 |
| W2-17 | 3 | Holdout MVP | No | Q13 (who writes scenarios) |
| W2-18 | 3 | Scorecard | No | W2-08, W2-09 |
| W2-19 | Deferred | E5 fitter, full H2 fence, H4 twin, I1 to I3 and I5, J | No | each has its own plan |

**Dispatch at scale.** Tranche 1 removes the known causes of the failures in the incident record. It is necessary but not sufficient: the breaker still reads GitHub history only, and local outcomes reach it only after Wave 1b (ADR-0007).

---

## Decisions and spec conflicts

The spec already covers most of this work. A reviewer checked it and found one new item.

| Spec section | What it says | What this plan does | Conflict? |
|---|---|---|---|
| §6.2 error fingerprinting; per-call budgets; kill switch | Classify failures, stop identical fingerprints, enforce budgets | W2-02, W2-04, W2-12 | No |
| §7.5 don't-port list | intelligence, self-optimize, adaptive, bandits and model-router learning are retired | W2-07 and W2-16 retire them | No |
| §7.4 Wave 4 "one gated optimizer" | the only learner left | the E5 fitter is W2-19, deferred | **Only the timing.** It stays in Wave 4 |
| §8 delivery evals and scorecard | 20 to 50 cases; pass^3; cost per success | W2-13, W2-14, W2-18 | No |
| §2 non-goals | no new features except §6.1, §6.2, §6.3 | Tranches 1 to 3 sit inside §6.2 and §8 | No change needed for Tranches 1 to 3 |

**Decision D-M (needs maintainer approval): model alias conversion.** Five model pins move to aliases that resolve to the 5.5 generation (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`). Templates: `autonomous.json` and `full.json` name `claude-opus-5`; `cost-aware.json` names `claude-sonnet-5`, `claude-opus-5` and `claude-haiku-4-5`. Workflows: `shipwright-pipeline.yml` triage names `claude-haiku-4-5-20251001` (becomes the `haiku` alias), and `review-remediation.yml` names `claude-sonnet-4-20250514` (becomes the `sonnet` alias). Each conversion changes the model for every run that reaches that line. **Default: convert**, because the reviewer required it and the pricing table already covers the 5.5 family. The change is recorded in the ADR as a model change.

---

## Evidence

| # | Claim | Status | Source and note |
|---|---|---|---|
| E1 | Token cost for one task varies up to 30x across runs; self-prediction correlation up to 0.39, with underestimation | [V] | [Bai et al., arXiv 2604.22750](https://arxiv.org/pdf/2604.22750). The "accuracy peaks at intermediate cost" claim is **not** verified and is not used. |
| E2 | Lights-off review benchmark: claude-opus-5 with copilot-cli catches 71.9% of bugs in its top-5 comments; opus-4.6 47.7% | [V] with two corrections | [CRBugBench, "(When) Should a Software Factory be Lights-off?", arXiv 2610.13668](https://arxiv.org/abs/2610.13668), fetched 2026-10-15. **Correction 1:** the bugs are "human-verified bugs mined from repository history", not injected bugs. **Correction 2:** the page does not say that opus-4.6 ran under the same harness, so the 71.9% and 47.7% figures may not be directly comparable. The paper also reports weaker results on complex or non-local changes and on proprietary repositories, which supports lights-on by default. |
| E3 | ModularRSI: five-module harness, restricted modification scope, contrastive trajectory analysis | [V] | [arXiv 2609.14857](https://arxiv.org/pdf/2609.14857). The paper reports no ablation of the contrastive step. |
| E4 | StrongDM's software factory: scenarios held outside the codebase; "satisfaction"; digital twins | [V] (secondary) | [Willison, 2026-02-07](https://simonwillison.net/2026/feb/7/software-factory/), read with secondary coverage. Transfer to Shipwright is [J]. |
| E5 | Weng, "Harness Engineering for Self-Improvement" (2026-07-04): read-only evaluators | [U] | Read only through secondary coverage. The specific read-only claims are not used as evidence. |
| E6 | Run `Shipwright Pipeline #8547` (run 38744601038) shows the watchdog and heartbeat gap, not an agent stall | [V] | At 16:39Z, about three hours after it started at 13:39Z, the pipeline job was still `in_progress`. The stall was environmental (E11). The gap is that nothing detected it: the heartbeat timer kept the watchdog satisfied. The W2-05 and W2-06 fixture is synthetic; a capture of this run is taken after it completes (W2-01). |
| E7 | The 288 re-runs on 2026-10-14 came from dispatch and sweep, not from auto-retry | [V] by source check; [U] whether some of the 288 runs were on issues the leaked test gate had changed (E11) | The dispatch guard matches the text "Pipeline Auth Failure" (`shipwright-dispatch.yml:107`), and the pre-flight writes that comment with `|| true`. Sweep uses "Pipeline Starting" timestamps (`shipwright-sweep.yml:95`). The exact path of each re-run is not reconstructed here. |
| E8 | "Environment setup is the largest single factor in agent success" | [U] | Not checked. W2-02 adds an environment class because the incident record shows setup failures, not because of this claim. |
| E9 | Auto-retry has no auth category and falls back to BUILD_FAILURE | [V] | `shipwright-auto-retry.yml` categorisation block, default at the "safest retry strategy" line. |
| E10 | CI heartbeat is a background timer that posts every 600 seconds regardless of progress | [V] | `shipwright-pipeline.yml:641–646`. |
| E11 | The environmental cause of the #8547 stall: the loop's test gate inherited the GitHub and Claude credentials, so `scripts/sw-e2e-integration-test.sh` ran a nested real pipeline on every iteration. It filed real issues, switched branches in the agent's checkout, and deleted `.claude/pipeline-state.md`. | [V] for the mechanism, read in the diff of PR #8610, which is **open, not merged** (`scripts/sw-e2e-integration-test.sh`, `scripts/lib/test-gate-env.sh`, `scripts/sw-loop.sh`). [U] for the counts (about 1000 issues over time; 37 open ones now closed), as the maintainer reported them. | #8610 adds `sw_test_gate_env` (tokens unset, empty `GH_CONFIG_DIR`, `SHIPWRIGHT_IN_TEST_GATE=1`) and the `SHIPWRIGHT_E2E_REAL=1` opt-in. Tracked in #8608. |

**Not cited:** StrongDM's specific figures beyond the holdout framing, Weng's specific claims, AHE and Self-Harness (not verified), and the issue #8547 run as evidence of an agent stall. #8547 is evidence of the watchdog gap only (E6). The 71.9% review figure is cited with its corrections (E2).

---

## Baseline (condensed from the survey)

| Mechanism | Writes | Read back to change behaviour? | Outcome-tested? |
|---|---|---|---|
| `classify_failure` (`scripts/lib/daemon-failure.sh:22`) | nothing | yes: auth and invalid-input skip retry | **no**: `sw-daemon-test.sh:1683` greps source for `not logged in` |
| Retry escalation (`daemon-failure.sh:204–300`) | retry count | yes: model, template and iteration escalation | no |
| CI auto-retry categorisation (`shipwright-auto-retry.yml`) | `SHIPWRIGHT-RETRY-CATEGORY` | yes, but auth falls through to BUILD_FAILURE | no |
| Loop circuit breaker and stuckness (`sw-loop.sh:124–125, 2556`) | events | yes: stops or restarts the loop | no |
| `loop-tuning.json` (`sw-loop.sh:684–698`) | **nothing: no writer exists** | reads a file that is never created | no |
| `iteration-model.json` (`sw-self-optimize.sh`) | per-complexity means | yes: iteration and cycle limits | no |
| `template-weights.json` (`sw-self-optimize.sh`) | weights | yes: template choice (`daemon-triage.sh:421`) | no |
| UCB1 model selection (`pipeline-execution.sh:694–698`) | route stats | yes: sets `CLAUDE_MODEL` **before** the template's model | no |
| `$RANDOM` A/B (`pipeline-execution.sh:731–753`) | none | yes: 20% of stages use the recommended model | no |
| Recruit override (`pipeline-stages-build.sh:395–408`) | none | yes: sets the build model when `--model` is absent | no |
| Memory injection (`sw-memory.sh`) | memory files | yes: injected into prompts | bookkeeping only |
| CI heartbeat | a comment every 10 min | yes: watchdog treats it as liveness | no |
| Stall detector (`sw-stall-detector.sh`) | state file | **no**: not wired into any workflow | no |
| Cost and budget (`sw-cost.sh`, `costs.json`) | cost entries | yes locally; CI has no cost data | no |

**What the survey shows.** Several mechanisms change behaviour from data, so the problem is not that nothing reads the data. The problems are: no outcome is measured against a baseline; the CI heartbeat is a timer; auth failures have no category; one read path has no writer; several tests grep source instead of checking behaviour; and three learners (UCB1, the `$RANDOM` A/B and recruit) set the build model, so **the build model is set by them, not by the template** (answering Q8).

---

## Conventions

- Run commands from the worktree root `/Users/sethford/Documents/shipwright-wave2`. Do not run `bun install` in a worktree; `node_modules` is a symlink.
- Biome: every new or edited TypeScript file, and every TypeScript block in this plan, passes `bunx biome check --write <files>` followed by `bunx biome check <files>` before any `check` step. `biome.json` checks `src/**` and `tools/**` only.
- Standard gates: `bun test <path>` for the task; `bun run check:fast` after each change; `bun run check` before a commit. A change that adds or edits a CLI command also needs `bun run docs:gen` and `bun run docs:check`.
- Hermetic bash suites: `bash scripts/sw-test-all.sh --pattern <name>`, output not piped. Never run the tmux suites locally: `sw-daemon-test`, `sw-lib-daemon-dispatch-test`, `sw-lib-daemon-patrol-test`, `sw-lib-daemon-poll-test`, `sw-tmux-*`, or `sw-test-all.sh` without `--pattern`.
- Workflow rules (`.claude/rules/workflows.md`): no `${{ }}` inside `run:`; pass values through `env:`. Pin new actions to a full SHA. The Bun setup used everywhere in this plan is the one `.github/actions/safety-gates/action.yml` already pins: `oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2.2.0` with `bun-version: 1.2.19`, followed by `bun install --frozen-lockfile --ignore-scripts`.
- Bash rules (`.claude/rules/bash.md`): Bash 3.2; no `eval`; arguments as arrays; JSON only through `jq --arg` or `--argjson`; atomic writes through a temporary file and `mv`.
- Scratch verification: the TypeScript domain, application and CLI files of W2-02 and W2-05, and the bash bridge and daemon helper of W2-04 and W2-06, were executed in an isolated scratch copy against minimal stubs of the real interfaces. **44 TypeScript tests pass**, and the bridge and helper cases behave as specified. The repository run for each task is the verification step listed under it. Nothing in the repository was changed by the scratch run.

---

## Tranche 1 (P0): exact steps

Tranche 1 needs no ledger. It can be merged and verified without GitHub writes.

### W2-01: incident fixtures

**Purpose:** fixtures for the classifier (W2-02, W2-03), the progress verdict (W2-05) and the stall stop (W2-06). The fixtures are test inputs, so they must not contain credentials.

**Files:**
- Create: `src/testing/fixtures/wave2/preflight-auth.log` (synthetic; replaced by a capture in Step 1)
- Create: `src/testing/fixtures/wave2/stall-snapshots.json` (synthetic; replaced by a capture in Step 1)
- Create: `src/testing/fixtures/wave2/fixtures.test.ts`

- [ ] **Step 1: Capture the real fixtures (read-only).** Run 38744601038 is still in progress (E6). After it completes, capture its failed-step log, and do not commit the raw log:

```bash
gh run view 38744601038 --repo sethdford/shipwright --json status --jq '.status'
```
Expected: `completed`. If it still prints `in_progress`, keep the synthetic fixtures and record the capture as open.

```bash
gh run view 38744601038 --repo sethdford/shipwright --log-failed > "$SCRATCH/38744601038.failed.log"
grep -En 'ghp_|gho_|ghs_|github_pat_|sk-ant-|CLAUDE_CODE_OAUTH_TOKEN=' "$SCRATCH/38744601038.failed.log" || echo "no credential-shaped strings"
```
Expected: `no credential-shaped strings`. If anything matches, redact it by hand before copying any excerpt into a fixture.

- [ ] **Step 2: Commit the synthetic fixtures (or the redacted capture).** The synthetic pre-flight fixture reproduces the exact text the workflow writes (`.github/workflows/shipwright-pipeline.yml`, step "Pre-flight auth check"):

`src/testing/fixtures/wave2/preflight-auth.log`:
```text
Verifying Claude Code authentication...
::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret
--- stderr ---
Error: 401 authentication_error: OAuth token has expired
--- end ---
```

`src/testing/fixtures/wave2/stall-snapshots.json` (four iterations with no test movement and one repeated error, shaped like the snapshot type in W2-05):
```json
[
  {"index": 1, "passingTests": null, "failingTests": ["suite"], "diffLines": 2, "newCommits": 0, "errorFingerprint": "execution:0a1b2c3d", "loopCompleteClaimed": false},
  {"index": 2, "passingTests": null, "failingTests": ["suite"], "diffLines": 2, "newCommits": 0, "errorFingerprint": "execution:0a1b2c3d", "loopCompleteClaimed": false},
  {"index": 3, "passingTests": null, "failingTests": ["suite"], "diffLines": 2, "newCommits": 0, "errorFingerprint": "execution:0a1b2c3d", "loopCompleteClaimed": false},
  {"index": 4, "passingTests": null, "failingTests": ["suite"], "diffLines": 2, "newCommits": 0, "errorFingerprint": "execution:0a1b2c3d", "loopCompleteClaimed": false}
]
```

- [ ] **Step 3: Write the fixture test.**

```ts
// src/testing/fixtures/wave2/fixtures.test.ts
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";

const dir = new URL("./", import.meta.url);
const SECRET =
  /ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|CLAUDE_CODE_OAUTH_TOKEN=\S+/;

describe("wave2 incident fixtures", () => {
  test("no fixture contains a credential-shaped string", () => {
    for (const name of readdirSync(dir)) {
      if (name.endsWith(".test.ts")) continue;
      expect(readFileSync(new URL(name, dir), "utf8")).not.toMatch(SECRET);
    }
  });

  test("the pre-flight fixture carries the auth failure line", () => {
    const text = readFileSync(new URL("preflight-auth.log", dir), "utf8");
    expect(text).toContain("Claude Code authentication failed");
  });

  test("the stall fixture is four iterations of one repeated error", () => {
    const snapshots = JSON.parse(
      readFileSync(new URL("stall-snapshots.json", dir), "utf8"),
    ) as Array<{ errorFingerprint: string }>;
    expect(snapshots).toHaveLength(4);
    expect(new Set(snapshots.map((s) => s.errorFingerprint)).size).toBe(1);
  });
});
```

- [ ] **Step 4: Run.**

Run: `bun test src/testing/fixtures`
Expected: `3 pass`, `0 fail`.

---

### W2-02: failure classifier core

**Purpose:** classify a failed run from its typed kind or its log, decide retry or escalate, and expose the decision as a command. It writes nothing and calls nothing. It also adds a `contamination` class: a run that reached a real service through the test gate, or changed the agent's checkout, is never retried, because a retry repeats real side effects (E11). The signals are the test-gate refusal text, and the `CONTAMINATION:` lines the loop records (W2-06 Step 3). Setup and hermeticity failures are their own classes: `environment` (retried once) and `contamination` (never retried).

**Files:**
- Create: `src/contexts/learning/domain/failure.ts`, `retry.ts`, `failure.test.ts`, `retry.test.ts`
- Create: `src/contexts/learning/application/classify.ts`
- Create: `src/contexts/learning/index.ts`
- Modify: `src/shared/kernel/ports.ts` (add the `FileReader` port)
- Create: `src/adapters/state/node-file-reader.ts`
- Create: `src/testing/fake-file-reader.ts`
- Modify: `src/testing/cli-harness.ts` (`commandContext` takes a file reader)
- Modify: `src/cli/command.ts` (add `files` to `CommandContext`)
- Modify: `src/main.ts` (provide `files`)
- Create: `src/cli/commands/failure.ts`, `failure.test.ts`
- Modify: `src/cli/commands/index.ts` (register `failureCommand`)
- Modify: `scripts/sw` (router line)
- Modify: `docs/plans/port/progress.json` (entry)
- Regenerate: `docs/reference/cli.md`

**Design note (F1):** the domain imports `AgentFailureKind` from `src/shared/kernel/ports.ts`. F1 allows imports from `src/shared/kernel`, so the kind names are not redeclared. The `KIND_CLASS` table is typed `Record<AgentFailureKind, FailureClass>`, so a new kind fails the typecheck until it is mapped.

- [ ] **Step 1: Domain classifier.** Copy this file as written (`src/contexts/learning/domain/failure.ts`):

```ts
import type { AgentFailureKind } from "../../../shared/kernel/ports";

// Failure classes (spec §6.2 error fingerprinting). Pure: F1 allows importing shared/kernel types.
export const FAILURE_CLASSES = [
  "auth",
  "invalid_input",
  "environment",
  "transient",
  "budget",
  "max_turns",
  "refusal",
  "schema",
  "truncated",
  "timeout",
  "execution",
  "contamination",
  "unknown",
] as const;
export type FailureClass = (typeof FAILURE_CLASSES)[number];

export interface FailureEvidence {
  /** The typed agent failure kind when the caller has one. It always wins over text. */
  readonly kind?: AgentFailureKind;
  /** Log or error text, for example the tail of a run log. */
  readonly text?: string;
}

// Exhaustive over AgentFailureKind: a new kind fails the typecheck until it is mapped here.
const KIND_CLASS: Readonly<Record<AgentFailureKind, FailureClass>> = {
  auth: "auth",
  transient: "transient",
  budget: "budget",
  max_turns: "max_turns",
  refusal: "refusal",
  schema: "schema",
  truncated: "truncated",
  timeout: "timeout",
  execution: "execution",
  aborted: "execution",
};

// Error lines: only these lines are searched by rules scoped to "error" (anchoring, B6).
const ERROR_LINE = /error|fail|fatal|exception|::error::|enoent|eacces|not found|lockfile/i;

interface Rule {
  readonly pattern: RegExp;
  readonly cls: FailureClass;
  /** "error" rules search error lines only; "any" rules search the whole text. */
  readonly scope: "any" | "error";
}

// First match wins. Auth comes first: retrying an auth failure cannot help, so a rate-limit line
// in the same log must not mask it. The bare token variable name is deliberately not a rule.
const RULES: readonly Rule[] = [
  {
    // Checked first: a contaminated run's other symptoms (auth, rate limit) are side effects of the
    // contamination, and a retry would repeat real side effects. Signals: the test-gate refusal
    // printed by sw-e2e-integration-test.sh (PR #8610), or a CONTAMINATION line the loop records when
    // it finds .claude/pipeline-state.md missing or the branch switched mid-run.
    pattern:
      /refusing to run inside a build-loop test gate|^CONTAMINATION: (pipeline-state-missing|branch-switched)/im,
    cls: "contamination",
    scope: "any",
  },
  {
    pattern:
      /authentication[ _]failed|invalid api key|api error: 401|oauth token (is )?(expired|invalid)|not logged in|unauthorized/i,
    cls: "auth",
    scope: "any",
  },
  {
    pattern: /issue not found|api error: 404|no body|could not resolve|issue.*does not exist/i,
    cls: "invalid_input",
    scope: "any",
  },
  {
    pattern:
      /command not found|enoent.*(node_modules|\.bin|tsconfig|package\.json)|eacces.*(node_modules|\.bin|\.cache)|error: lockfile|lockfile is frozen|could not (install|resolve) (dependencies|packages)/i,
    cls: "environment",
    scope: "error",
  },
  {
    pattern:
      /rate.?limit|overloaded|api error: (429|5\d\d)|econnreset|etimedout|socket hang up|service unavailable|econnrefused|eai_again/i,
    cls: "transient",
    scope: "any",
  },
];

export function errorLines(text: string): string {
  return text
    .split("\n")
    .filter((line) => ERROR_LINE.test(line))
    .join("\n");
}

/** The last line that looks like an error; the last non-empty line when there is none. */
export function lastErrorLine(text: string): string {
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "");
  const errors = lines.filter((line) => ERROR_LINE.test(line));
  return errors.at(-1) ?? lines.at(-1) ?? "";
}

export function classifyFailure(evidence: FailureEvidence): FailureClass {
  if (evidence.kind !== undefined) return KIND_CLASS[evidence.kind];
  const text = evidence.text ?? "";
  for (const rule of RULES) {
    const haystack = rule.scope === "error" ? errorLines(text) : text;
    if (rule.pattern.test(haystack)) return rule.cls;
  }
  return "unknown";
}

/** FNV-1a, 32-bit: a pure, dependency-free hash for grouping identical failures. */
export function fnv1a(input: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

/** Groups identical failures: the normalised last error line, not the whole tail. */
export function failureFingerprint(cls: FailureClass, text: string): string {
  const normalised = lastErrorLine(text)
    .toLowerCase()
    .replace(/\/[^\s'":]+/g, "<path>")
    .replace(/\d{4}-\d{2}-\d{2}t?[\d:.z+-]*/g, "<time>")
    .replace(/0x[0-9a-f]+|\b[0-9a-f]{7,40}\b/g, "<hex>")
    .replace(/\d+/g, "0")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
  return `${cls}:${fnv1a(normalised)}`;
}
```

- [ ] **Step 2: Retry decision.** Copy this file as written (`src/contexts/learning/domain/retry.ts`):

```ts
import { FAILURE_CLASSES, type FailureClass } from "./failure";

export interface Attempt {
  readonly cls: FailureClass;
  readonly fingerprint: string;
}

export interface RetryPolicy {
  /** Total runs allowed, first run included. */
  readonly maxAttempts: number;
  readonly maxTransient: number;
  readonly baseDelayMs: number;
  readonly maxDelayMs: number;
}

export type RetryDecision =
  | { readonly action: "retry"; readonly delayMs: number; readonly reason: string }
  | { readonly action: "escalate"; readonly reason: string };

/** Adaptation may only tighten these caps; it never raises them (ADR-0007, ADR-0009). */
export const DEFAULT_RETRY_POLICY: RetryPolicy = {
  maxAttempts: 4,
  maxTransient: 3,
  baseDelayMs: 30_000,
  maxDelayMs: 3_600_000,
};

// A retry repeats real side effects (contamination) or cannot help (auth, invalid input).
const NEVER_RETRY: ReadonlySet<FailureClass> = new Set<FailureClass>([
  "auth",
  "invalid_input",
  "contamination",
]);

/** Decides from the attempt history of one issue. Pure; the caller records the decision. */
export function decideRetry(history: readonly Attempt[], policy: RetryPolicy): RetryDecision {
  const last = history.at(-1);
  if (last === undefined) return { action: "escalate", reason: "no attempt to decide on" };
  if (NEVER_RETRY.has(last.cls)) {
    return { action: "escalate", reason: `${last.cls}: retrying cannot help; a human must act` };
  }
  if (history.length >= policy.maxAttempts) {
    return { action: "escalate", reason: `attempt cap ${policy.maxAttempts} reached` };
  }
  if (last.cls === "environment") return environmentDecision(history);
  const prev = history.at(-2);
  if (prev !== undefined && prev.fingerprint === last.fingerprint && last.cls !== "transient") {
    return { action: "escalate", reason: `same failure twice (${last.fingerprint})` };
  }
  if (last.cls === "transient") return retryTransient(history, policy);
  return { action: "retry", delayMs: 0, reason: `${last.cls}: retry within caps` };
}

function environmentDecision(history: readonly Attempt[]): RetryDecision {
  const environmentRuns = history.filter((a) => a.cls === "environment").length;
  if (environmentRuns > 1) {
    return { action: "escalate", reason: "environment: fix the setup; retrying will not help" };
  }
  return { action: "retry", delayMs: 0, reason: "environment: one retry, then escalate" };
}

function retryTransient(history: readonly Attempt[], policy: RetryPolicy): RetryDecision {
  const transients = history.filter((a) => a.cls === "transient").length;
  if (transients > policy.maxTransient) {
    return { action: "escalate", reason: `transient failures exceed ${policy.maxTransient}` };
  }
  const delayMs = Math.min(policy.baseDelayMs * 2 ** (transients - 1), policy.maxDelayMs);
  return { action: "retry", delayMs, reason: `transient (${transients}): backoff` };
}

const CLASS_SET: ReadonlySet<string> = new Set<string>(FAILURE_CLASSES);

/** Validates the `--attempts FILE` JSON: an array of {cls, fingerprint}. Fails closed. */
export function parseAttempts(
  value: unknown,
):
  | { readonly ok: true; readonly attempts: readonly Attempt[] }
  | { readonly ok: false; readonly reason: string } {
  if (!Array.isArray(value)) return { ok: false, reason: "attempts must be a JSON array" };
  const attempts: Attempt[] = [];
  for (const [i, item] of value.entries()) {
    if (typeof item !== "object" || item === null)
      return { ok: false, reason: `attempt ${i} is not an object` };
    const { cls, fingerprint } = item as Record<string, unknown>;
    if (typeof cls !== "string" || !CLASS_SET.has(cls))
      return { ok: false, reason: `attempt ${i}: unknown class` };
    if (typeof fingerprint !== "string" || fingerprint.length === 0) {
      return { ok: false, reason: `attempt ${i}: missing fingerprint` };
    }
    attempts.push({ cls: cls as FailureClass, fingerprint });
  }
  return { ok: true, attempts };
}
```

- [ ] **Step 3: Domain tests.** Copy these two files as written:

`src/contexts/learning/domain/failure.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import { classifyFailure, failureFingerprint, lastErrorLine } from "./failure";

describe("classifyFailure", () => {
  test("a typed kind wins over text", () => {
    expect(classifyFailure({ kind: "auth", text: "rate limit exceeded" })).toBe("auth");
  });

  test("the pre-flight auth text from ci.yml is an auth failure", () => {
    const text =
      "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret";
    expect(classifyFailure({ text })).toBe("auth");
  });

  test("auth outranks transient when a log has both", () => {
    expect(classifyFailure({ text: "429 rate limit\nAPI Error: 401 unauthorized" })).toBe("auth");
  });

  test("a mention of the token variable alone is not an auth failure", () => {
    expect(classifyFailure({ text: "CLAUDE_CODE_OAUTH_TOKEN is documented in README" })).toBe(
      "unknown",
    );
  });

  test("bun install logs with a healthy lockfile are not environment failures", () => {
    const text = "bun install v1.2.19\nLockfile: bun.lock\nInstalled 812 packages";
    expect(classifyFailure({ text })).toBe("unknown");
  });

  test("a missing binary on an error line is an environment failure", () => {
    expect(classifyFailure({ text: "setup step\nbun: command not found" })).toBe("environment");
  });

  test("a permission error outside node_modules is not an environment failure", () => {
    expect(classifyFailure({ text: "EACCES: permission denied, open '/etc/hosts'" })).toBe(
      "unknown",
    );
  });

  test("text with no known pattern is unknown, not a guess", () => {
    expect(classifyFailure({ text: "TypeError: cannot read properties of undefined" })).toBe(
      "unknown",
    );
  });
});

describe("contamination signals (one test per signal)", () => {
  test("the test-gate refusal from sw-e2e-integration-test.sh is contamination", () => {
    const text = "⚠ Skipping integration tests: refusing to run inside a build-loop test gate";
    expect(classifyFailure({ text })).toBe("contamination");
  });

  test("a loop-recorded missing .claude/pipeline-state.md is contamination", () => {
    expect(
      classifyFailure({ text: "iteration 4 done\nCONTAMINATION: pipeline-state-missing\n" }),
    ).toBe("contamination");
  });

  test("a loop-recorded branch switch is contamination", () => {
    expect(classifyFailure({ text: "CONTAMINATION: branch-switched wave2/plan -> main" })).toBe(
      "contamination",
    );
  });
});

describe("failureFingerprint", () => {
  test("is stable across digits and paths in the last error line", () => {
    const a = failureFingerprint("execution", "build failed at /tmp/x/42 line 7");
    const b = failureFingerprint("execution", "build failed at /tmp/y/9 line 3");
    expect(a).toBe(b);
  });

  test("ignores a different preamble when the last error line is the same", () => {
    const a = failureFingerprint("execution", "step 1 ok\nbuild failed: tsc exit 2");
    const b = failureFingerprint(
      "execution",
      "compiling 900 files\nstep 9\nbuild failed: tsc exit 2",
    );
    expect(a).toBe(b);
  });

  test("differs when the class differs", () => {
    expect(failureFingerprint("auth", "x fail")).not.toBe(
      failureFingerprint("transient", "x fail"),
    );
  });

  test("lastErrorLine prefers the last error-looking line", () => {
    expect(lastErrorLine("ok\nerror: first\nmore output\nfatal: last\ntrailer")).toBe(
      "fatal: last",
    );
  });
});
```

`src/contexts/learning/domain/retry.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import {
  type Attempt,
  DEFAULT_RETRY_POLICY,
  decideRetry,
  parseAttempts,
  type RetryPolicy,
} from "./retry";

const policy: RetryPolicy = {
  maxAttempts: 4,
  maxTransient: 3,
  baseDelayMs: 1000,
  maxDelayMs: 60_000,
};
const att = (cls: Attempt["cls"], fingerprint = `${cls}:x`): Attempt => ({ cls, fingerprint });

describe("decideRetry", () => {
  test("auth is never retried; it escalates on the first attempt", () => {
    expect(decideRetry([att("auth")], policy).action).toBe("escalate");
  });

  test("invalid input is never retried", () => {
    expect(decideRetry([att("invalid_input")], policy).action).toBe("escalate");
  });

  test("the same non-transient failure twice escalates", () => {
    const same = att("execution", "execution:abc");
    const d = decideRetry([same, same], policy);
    expect(d.action).toBe("escalate");
    if (d.action === "escalate") expect(d.reason).toContain("same failure twice");
  });

  test("an environment failure is retried once, then escalates", () => {
    expect(decideRetry([att("environment", "e:1")], policy).action).toBe("retry");
    expect(decideRetry([att("environment", "e:1"), att("environment", "e:2")], policy).action).toBe(
      "escalate",
    );
  });

  test("contamination escalates on the first attempt: a retry would repeat real side effects", () => {
    const d = decideRetry([att("contamination", "c:1")], policy);
    expect(d.action).toBe("escalate");
  });

  test("two distinct budget failures are retried within caps", () => {
    expect(decideRetry([att("budget", "b:1"), att("budget", "b:2")], policy).action).toBe("retry");
  });

  test("transient failures back off exponentially", () => {
    const d = decideRetry([att("transient", "t:1"), att("transient", "t:1")], policy);
    expect(d).toMatchObject({ action: "retry", delayMs: 2000 });
  });

  test("transient failures escalate once they exceed maxTransient", () => {
    const many = Array.from({ length: 4 }, () => att("transient", "t:1"));
    expect(decideRetry(many, { ...policy, maxAttempts: 10 }).action).toBe("escalate");
  });

  test("the attempt cap cannot be exceeded", () => {
    const four = [att("budget", "1"), att("budget", "2"), att("budget", "3"), att("budget", "4")];
    expect(decideRetry(four, policy).action).toBe("escalate");
  });

  test("no history means no decision to act on: escalate", () => {
    expect(decideRetry([], policy).action).toBe("escalate");
  });

  test("the default policy never allows more than four runs", () => {
    const four = [1, 2, 3, 4].map((n) => att("budget", `b:${n}`));
    expect(decideRetry(four, DEFAULT_RETRY_POLICY).action).toBe("escalate");
  });
});

describe("parseAttempts", () => {
  test("accepts a well-formed array", () => {
    const r = parseAttempts([{ cls: "transient", fingerprint: "transient:1" }]);
    expect(r.ok).toBe(true);
  });

  test("refuses an unknown class rather than guessing", () => {
    const r = parseAttempts([{ cls: "weather", fingerprint: "x" }]);
    expect(r).toEqual({ ok: false, reason: "attempt 0: unknown class" });
  });

  test("refuses a non-array document", () => {
    expect(parseAttempts({})).toEqual({ ok: false, reason: "attempts must be a JSON array" });
  });
});
```

- [ ] **Step 4: Run the domain tests.**

Run: `bun test src/contexts/learning/domain`
Expected: `29 pass`, `0 fail`. (15 classifier tests, including 3 contamination-signal tests; 11 `decideRetry` tests, including the contamination test; 3 `parseAttempts` tests.)

- [ ] **Step 5: The file-reader port.** Add to `src/shared/kernel/ports.ts`, after the existing `IssueTracker` block:

```ts
// ── Files (read-only; commands take this port, adapters implement it) ────────
/** Reads a text file. Command code uses this port; only adapters touch the filesystem (F5). */
export interface FileReader {
  readText(path: string): Promise<Result<string, AdapterError>>;
}
```

- [ ] **Step 6: The adapter.** Create `src/adapters/state/node-file-reader.ts`:

```ts
import { readFile } from "node:fs/promises";
import type { AdapterError, FileReader } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

export class NodeFileReader implements FileReader {
  async readText(path: string): Promise<Result<string, AdapterError>> {
    try {
      return ok(await readFile(path, "utf8"));
    } catch (cause) {
      const missing = (cause as { code?: string }).code === "ENOENT";
      return err({ kind: missing ? "not_found" : "failed", message: String(cause) });
    }
  }
}
```

- [ ] **Step 7: The fake and the harness.** Create `src/testing/fake-file-reader.ts`:

```ts
import type { AdapterError, FileReader } from "../shared/kernel/ports";
import { err, ok, type Result } from "../shared/kernel/result";

/** In-memory FileReader for command tests. A missing path is `not_found`. */
export class FakeFileReader implements FileReader {
  constructor(private readonly files: Readonly<Record<string, string>>) {}

  async readText(path: string): Promise<Result<string, AdapterError>> {
    const text = this.files[path];
    return text === undefined
      ? err({ kind: "not_found", message: `no fake file ${path}` })
      : ok(text);
  }
}
```

Replace `commandContext` in `src/testing/cli-harness.ts` with this version. It keeps the existing `safety` handling and adds `files`:

```ts
/** A command context. `files()` throws unless a reader is given (commands that read none need none). */
export function commandContext(
  io: CliIO,
  safety?: SafetyPorts,
  env: Readonly<Record<string, string | undefined>> = {},
  files?: FileReader,
): CommandContext {
  return {
    io,
    version: "3.3.0",
    env,
    safety: () => {
      if (!safety) throw new Error("this command was not given safety ports");
      return safety;
    },
    files: () => {
      if (!files) throw new Error("this command was not given a file reader");
      return files;
    },
  };
}
```
Add `import type { FileReader } from "../shared/kernel/ports";` to the top of that file.

In `src/cli/command.ts`, replace the `CommandContext` interface with this version. The only addition is `files`, and `FileReader` is imported from `../shared/kernel/ports`:

```ts
export interface CommandContext {
  readonly io: CliIO;
  readonly version: string;
  /** The process environment (read in main.ts; commands never touch process.env). */
  readonly env: Readonly<Record<string, string | undefined>>;
  /** Adapters for the safety commands, built on first call (commands that need none never call it). */
  readonly safety: () => SafetyPorts;
  /** File reads for commands; built by main.ts from the adapter (commands never touch node:fs). */
  readonly files: () => FileReader;
}
```

In `src/main.ts`, add the import `import { NodeFileReader } from "./adapters/state/node-file-reader";` and a module-level `const fileReader = new NodeFileReader();`, then pass `files: () => fileReader` in the `command.run(...)` context object next to `safety`.

- [ ] **Step 8: Application.** Copy this file as written (`src/contexts/learning/application/classify.ts`):

```ts
import type { AgentFailureKind } from "../../../shared/kernel/ports";
import { classifyFailure, type FailureClass, failureFingerprint } from "../domain/failure";
import {
  type Attempt,
  DEFAULT_RETRY_POLICY,
  decideRetry,
  type RetryDecision,
  type RetryPolicy,
} from "../domain/retry";

export interface ClassifyInput {
  readonly kind?: AgentFailureKind;
  readonly text: string;
  readonly attempts: readonly Attempt[];
}

export interface ClassifyResult {
  readonly class: FailureClass;
  readonly fingerprint: string;
  readonly decision: RetryDecision;
}

/** Pure composition: classify this run, then decide with the prior attempts. Writes nothing. */
export function classifyAndDecide(
  input: ClassifyInput,
  policy: RetryPolicy = DEFAULT_RETRY_POLICY,
): ClassifyResult {
  const cls = classifyFailure(
    input.kind === undefined ? { text: input.text } : { kind: input.kind, text: input.text },
  );
  const fingerprint = failureFingerprint(cls, input.text);
  const decision = decideRetry([...input.attempts, { cls, fingerprint }], policy);
  return { class: cls, fingerprint, decision };
}
```

Copy this file as written (`src/contexts/learning/index.ts`), the only file other contexts and the CLI import from:

```ts
export { type ClassifyInput, type ClassifyResult, classifyAndDecide } from "./application/classify";
export {
  classifyFailure,
  FAILURE_CLASSES,
  type FailureClass,
  type FailureEvidence,
  failureFingerprint,
} from "./domain/failure";
export {
  type Attempt,
  DEFAULT_RETRY_POLICY,
  decideRetry,
  parseAttempts,
  type RetryDecision,
  type RetryPolicy,
} from "./domain/retry";
```

- [ ] **Step 9: The command.** Copy this file as written (`src/cli/commands/failure.ts`):

```ts
import { type Attempt, classifyAndDecide, parseAttempts } from "../../contexts/learning";
import type { AgentFailureKind } from "../../shared/kernel/ports";
import type { Command, CommandContext } from "../command";

const KINDS: readonly string[] = [
  "refusal",
  "max_turns",
  "budget",
  "schema",
  "truncated",
  "timeout",
  "aborted",
  "transient",
  "auth",
  "execution",
];

const usage = `USAGE
  shipwright failure classify --log FILE [--kind KIND] [--attempts FILE] [--json]

DESCRIPTION
  Classifies one failed run from its log (and an optional typed agent kind) and decides retry or
  escalate. Pure: it writes nothing. Auth and invalid-input failures always escalate; an environment
  failure is retried once. --attempts is a JSON array of {cls, fingerprint} from earlier runs.

EXIT CODES
  0  retry      3  escalate      1  could not read or decide (fails closed)      2  usage error`;

interface Flags {
  readonly log: string;
  readonly kind?: string;
  readonly attempts?: string;
  readonly json: boolean;
}

function parseFlags(args: readonly string[]): Flags | string {
  let log: string | undefined;
  let kind: string | undefined;
  let attempts: string | undefined;
  let json = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--json") {
      json = true;
    } else if (arg === "--log" || arg === "--kind" || arg === "--attempts") {
      const value = args[i + 1];
      if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
      if (arg === "--log") log = value;
      else if (arg === "--kind") kind = value;
      else attempts = value;
      i++;
    } else {
      return `unknown option: ${arg}`;
    }
  }
  if (log === undefined) return "--log is required";
  return {
    log,
    json,
    ...(kind === undefined ? {} : { kind }),
    ...(attempts === undefined ? {} : { attempts }),
  };
}

async function readAttempts(
  ctx: CommandContext,
  path: string,
): Promise<readonly Attempt[] | string> {
  const raw = await ctx.files().readText(path);
  if (!raw.ok) return `cannot read attempts: ${raw.error.message}`;
  let json: unknown;
  try {
    json = JSON.parse(raw.value);
  } catch {
    return "--attempts is not JSON";
  }
  const checked = parseAttempts(json);
  return checked.ok ? checked.attempts : checked.reason;
}

async function classify(args: readonly string[], ctx: CommandContext): Promise<number> {
  const flags = parseFlags(args);
  if (typeof flags === "string") {
    ctx.io.err(`✗ ${flags}`);
    ctx.io.out(usage);
    return 2;
  }
  if (flags.kind !== undefined && !KINDS.includes(flags.kind)) {
    ctx.io.err(`✗ unknown --kind: ${flags.kind}`);
    return 2;
  }
  const log = await ctx.files().readText(flags.log);
  if (!log.ok) {
    ctx.io.err(`✗ cannot read log: ${log.error.message}`);
    return 1;
  }
  const attempts = flags.attempts === undefined ? [] : await readAttempts(ctx, flags.attempts);
  if (typeof attempts === "string") {
    ctx.io.err(`✗ ${attempts}`);
    return 1;
  }
  const result = classifyAndDecide({
    ...(flags.kind === undefined ? {} : { kind: flags.kind as AgentFailureKind }),
    text: log.value,
    attempts,
  });
  const line = {
    class: result.class,
    fingerprint: result.fingerprint,
    action: result.decision.action,
    reason: result.decision.reason,
  };
  ctx.io.out(flags.json ? JSON.stringify(line) : `${line.action}: ${line.class} (${line.reason})`);
  return line.action === "retry" ? 0 : 3;
}

export const failureCommand: Command = {
  name: "failure",
  aliases: [],
  summary: "Classify a failed run and decide retry or escalate (ADR-0009)",
  usage,
  async run(args, ctx) {
    const [sub, ...rest] = args;
    if (sub === undefined || sub === "--help" || sub === "-h") {
      ctx.io.out(usage);
      return sub === undefined ? 2 : 0;
    }
    if (sub !== "classify") {
      ctx.io.err(`✗ unknown subcommand: ${sub}`);
      ctx.io.out(usage);
      return 2;
    }
    return classify(rest, ctx);
  },
};
```

- [ ] **Step 10: Command tests.** Copy this file as written (`src/cli/commands/failure.test.ts`). It uses `commandContext(io, undefined, {}, files)` with the new signature:

```ts
import { describe, expect, test } from "bun:test";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { failureCommand } from "./failure";

const files = new FakeFileReader({
  "/logs/pre.log":
    "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret\n",
  "/logs/rate.log": "API Error: 429 rate limit\n",
});

describe("failure classify", () => {
  test("auth text escalates with exit 3 and class auth", async () => {
    const io = captureIO();
    const code = await failureCommand.run(
      ["classify", "--log", "/logs/pre.log", "--json"],
      commandContext(io, undefined, {}, files),
    );
    expect(code).toBe(3);
    expect(JSON.parse(io.outLines[0] ?? "{}")).toMatchObject({ class: "auth", action: "escalate" });
  });

  test("an unreadable log fails closed with exit 1", async () => {
    const io = captureIO();
    expect(
      await failureCommand.run(
        ["classify", "--log", "/nope.log"],
        commandContext(io, undefined, {}, files),
      ),
    ).toBe(1);
  });

  test("a missing --log is a usage error with exit 2", async () => {
    const io = captureIO();
    expect(await failureCommand.run(["classify"], commandContext(io, undefined, {}, files))).toBe(
      2,
    );
  });

  test("a first transient failure retries with exit 0", async () => {
    const io = captureIO();
    expect(
      await failureCommand.run(
        ["classify", "--log", "/logs/rate.log"],
        commandContext(io, undefined, {}, files),
      ),
    ).toBe(0);
  });
});
```

- [ ] **Step 11: Register the command and the router.** Add `failureCommand` to the array in `src/cli/commands/index.ts` (import from `./failure`). In `scripts/sw`, add this block immediately after the `gates)` block, before `*)`:

```bash
        failure)
            run_ts failure "$@"
            ;;
```

- [ ] **Step 12: Port entry and generated reference.** Append to `docs/plans/port/progress.json`:

```json
  {
    "command": "failure",
    "aliases": [],
    "script": null,
    "context": "learning",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 2 (W2-02): failure classification and retry decision (ADR-0009). No bash predecessor; bash classify_failure calls it (W2-04)."
  }
```
If `bun run port:check` rejects `"script": null`, use the file name of the nearest bash predecessor (`sw-daemon.sh`) and record why in `notes`.

Run: `bun run docs:gen && bun run docs:check`
Expected: both exit 0; `docs/reference/cli.md` now lists `failure`.

- [ ] **Step 13: Run.**

Run: `bunx biome check --write src/contexts/learning src/cli/commands/failure.ts src/cli/commands/failure.test.ts`
Run: `bun test src/contexts/learning src/cli/commands/failure.test.ts`
Expected: `33 pass`, `0 fail`.

Run: `bun run check:fast`
Expected: exit 0.

Run: `bun run port:check`
Expected: exit 0.

---

### W2-03: auto-retry, AUTH category, Bun before categorisation

**Purpose:** an auth failure is never retried, and the categorisation is typed. Two steps install Bun before the categorisation step, so the classifier is available on CI.

**Files:** Modify `.github/workflows/shipwright-auto-retry.yml` only.

- [ ] **Step 1: Install Bun before categorisation.** Insert these two steps immediately before the step named `Categorize error from run logs`:

```yaml
      # Bun runs the TypeScript failure classifier (W2-02). Pinned like the safety-gates action;
      # no lifecycle scripts run.
      - name: Set up Bun for the failure classifier
        if: steps.extract.outputs.issue_number != ''
        uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2.2.0
        with:
          bun-version: 1.2.19

      - name: Install the Shipwright CLI dependencies
        if: steps.extract.outputs.issue_number != ''
        shell: bash
        run: bun install --frozen-lockfile --ignore-scripts
```

- [ ] **Step 2: Classify before the regex categories.** In the step `Categorize error from run logs`, insert this block immediately before the line `# Check for TRANSIENT patterns: timeouts, rate limits, connection errors`. It runs after the no-changes and cancelled checks, so it is the last word on the auth category:

```bash
          # Typed classification (W2-02): exit 0 = retry, 3 = escalate. Any other exit fails the job.
          # Input is the failed steps' log only (I2): `--log-failed` leaves out steps that passed, so a
          # passing pre-flight step cannot produce a false auth match. Fails closed when unreadable.
          # The text is data: it reaches the classifier as a file, never as a command string.
          if ! FAILED_LOG=$(gh run view "$RUN_ID" --repo "$GITHUB_REPOSITORY" --log-failed); then
            echo "::error::cannot read the failed-step log of run $RUN_ID; not retrying"
            exit 1
          fi
          printf '%s\n' "$FAILED_LOG" > "$RUNNER_TEMP/failed-run.log"
          if bun src/cli.ts failure classify --log "$RUNNER_TEMP/failed-run.log" --json > "$RUNNER_TEMP/classify.json"; then
            CLASSIFY_RC=0
          else
            CLASSIFY_RC=$?
          fi
          if [[ "$CLASSIFY_RC" -ne 0 && "$CLASSIFY_RC" -ne 3 ]]; then
            echo "::error::failure classifier failed (exit $CLASSIFY_RC); not retrying"
            exit 1
          fi
          FAILURE_CLASS=$(jq -r '.class' "$RUNNER_TEMP/classify.json")
          echo "Classifier: $FAILURE_CLASS"
          if [[ "$FAILURE_CLASS" == "auth" ]]; then
            ERROR_CATEGORY="AUTH"
          fi
```
The later `if [[ "$ERROR_CATEGORY" == "UNKNOWN" ]]` tests leave `AUTH` alone, and the design-failure check only runs for `BUILD_FAILURE` or `UNKNOWN`.

- [ ] **Step 3: Refuse AUTH in the strategy step.** In the step `Check retry count and determine strategy`, insert this block immediately after the `fi` that closes the `abandoned` check:

```bash
          # Auth failures are never retried: a retry cannot repair a credential (W2-03).
          if [[ "$ERROR_CATEGORY" == "AUTH" ]]; then
            echo "Run $RUN_ID failed authentication: not retrying; the credential needs a human"
            echo "should_retry=false" >> "$GITHUB_OUTPUT"
            echo "skip_reason=auth" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

- [ ] **Step 4: Post the AUTH comment.** Add this step after the step `Handle INFRA failure (no retry)`. It uses the same `if:` pattern and the wording that dispatch already recognises (`shipwright-dispatch.yml:107`):

```yaml
      - name: Handle AUTH failure (no retry)
        if: steps.strategy.outputs.skip_reason == 'auth' && steps.extract.outputs.issue_number != ''
        shell: bash
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ISSUE_NUMBER: ${{ steps.extract.outputs.issue_number }}
          RUN_ID: ${{ steps.extract.outputs.run_id }}
        run: |
          BODY="$RUNNER_TEMP/auth-body.md"
          {
            echo "## Pipeline Auth Failure"
            echo
            echo "Run [$RUN_ID]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$RUN_ID) failed authentication. Shipwright will not retry it."
            echo
            echo 'Check the `CLAUDE_CODE_OAUTH_TOKEN` secret, and run `claude setup-token` locally to replace it.'
            echo
            echo "<!-- SHIPWRIGHT-RETRY-CATEGORY: AUTH -->"
          } > "$BODY"
          gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$BODY"
```

- [ ] **Step 5: Lint and fitness.**

Run: `actionlint .github/workflows/shipwright-auto-retry.yml`
Expected: no output, exit 0.

Run: `bun run arch`
Expected: exit 0. The `workflow-injection` and `workflow-fail-closed` rules pass.

**Known residual (not fixed here):** sweep re-dispatches on its own timestamp logic (E7). W2-03 stops the auto-retry path only. The sweep path is covered by W2-06's progress marker and by W2-09's ledger.

---

### W2-04: daemon classify bridge with bash fallback

**Purpose:** the local daemon uses the typed classifier for the three classes that change behaviour. Everything else keeps the bash regex, so `build_failure` and `context_exhaustion` behave as before.

**Files:**
- Modify: `scripts/lib/daemon-failure.sh`
- Modify: `scripts/sw-lib-daemon-failure-test.sh` (new block before `print_test_results`)
- Modify: `scripts/sw-daemon-test.sh` (remove `test_classify_failure_auth` and its registration; the test greps source, and the behaviour is now tested in the hermetic suite)

- [ ] **Step 1: The helper.** Add this function immediately above `classify_failure()` in `scripts/lib/daemon-failure.sh`:

```bash
# _daemon_classify_ts <log> — prints the TypeScript classifier's class (W2-04). Exit 0 with a
# class; non-zero when Bun or the classifier is unavailable, so the caller falls back to regex.
# Exit 3 (escalate) still carries a class and is accepted here.
_daemon_classify_ts() {
    local log_path="$1"
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/cli.ts}"
    command -v "$bun_bin" >/dev/null 2>&1 || return 1
    local out rc=0
    out=$("$bun_bin" "$cli" failure classify --log "$log_path" --json 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then return 1; fi
    jq -r '.class // empty' <<<"$out" 2>/dev/null || return 1
}
```

- [ ] **Step 2: The bridge.** In `classify_failure()`, insert this block immediately after the line `tail_content=$(tail -200 "$log_path" 2>/dev/null || true)`, and leave the regex body below it unchanged:

```bash
    # W2-04: the typed classifier decides only the three classes that change behaviour. Anything
    # else (build_failure, context_exhaustion, unknown) falls through to the regex below, as before.
    local ts_class=""
    if ts_class=$(_daemon_classify_ts "$log_path" 2>/dev/null); then
        case "$ts_class" in
            auth) echo "auth_error"; return ;;
            transient) echo "api_error"; return ;;
            invalid_input) echo "invalid_issue"; return ;;
        esac
    fi
```

- [ ] **Step 3: Behaviour tests in the hermetic suite.** Insert this block in `scripts/sw-lib-daemon-failure-test.sh` immediately before the final `print_test_results` line:

```bash
# ─── W2-04: classify_failure behaviour (typed classifier with bash fallback) ───
printf '%s\n' "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret" > "$LOG_DIR/issue-42.log"
assert_eq "pre-flight auth text is auth_error" "auth_error" "$(classify_failure 42)"
assert_eq "the bash fallback still says auth_error when Bun is missing" "auth_error" \
    "$(SW_BUN=/nonexistent/bun classify_failure 42)"
printf '%s\n' "build failed: test suite red" > "$LOG_DIR/issue-43.log"
assert_eq "a build failure keeps the bash class" "build_failure" "$(classify_failure 43)"
printf '%s\n' "OAuth token is invalid" > "$LOG_DIR/issue-44.log"
assert_eq "the typed classifier reads 'OAuth token is invalid' as auth_error (needs Bun and an installed tree)" "auth_error" "$(classify_failure 44)"
assert_eq "without Bun the regex fallback misses it (a documented gap, not a regression)" "unknown" "$(SW_BUN=/nonexistent/bun classify_failure 44)"
```

- [ ] **Step 4: Remove the source grep.** In `scripts/sw-daemon-test.sh`, delete the function `test_classify_failure_auth` (it begins at line 1683) and its registration entry (the line containing `"test_classify_failure_auth:Intelligence: classify_failure detects auth errors"`, near line 1940). Do not run this suite locally (tmux).

- [ ] **Step 5: Verify (hermetic).**

Run: `bash scripts/sw-test-all.sh --pattern sw-lib-daemon-failure-test`
Expected: exit 0, and the suite's summary reports 0 failures.

Run: `bun run arch`
Expected: exit 0. Bash findings must not grow; `daemon-failure.sh` adds argv-only calls.

Verified in scratch: the helper returns the class for exit 0 and exit 3, and falls back (non-zero) for exit 1, as specified.

---

### W2-05: progress verdict and stall (TypeScript)

**Purpose:** a run is progressing only when the test signal moves. Diff growth and new commits are activity, not progress.

**Files:**
- Create: `src/contexts/delivery/domain/progress.ts`, `progress.test.ts`
- Create: `src/contexts/delivery/application/assess.ts`
- Create: `src/contexts/delivery/index.ts`
- Create: `src/cli/commands/progress.ts`, `progress.test.ts`
- Modify: `src/cli/commands/index.ts` (register `progressCommand`)
- Modify: `scripts/sw` (router line), `docs/plans/port/progress.json` (entry), `docs/reference/cli.md` (regenerated)

- [ ] **Step 1: Domain.** Copy this file as written (`src/contexts/delivery/domain/progress.ts`):

```ts
// Progress verdict for one build loop (W2-05). Pure. Progress means test-signal movement:
// diff growth and new commits are recorded as activity, never as progress.

export interface IterationSnapshot {
  readonly index: number;
  /** Null when the test summary could not be parsed. */
  readonly passingTests: number | null;
  readonly failingTests: readonly string[];
  readonly diffLines: number;
  readonly newCommits: number;
  readonly errorFingerprint: string | null;
  readonly loopCompleteClaimed: boolean;
}

export interface ProgressPolicy {
  /** Trailing iterations with no test movement that stall the run. */
  readonly stallIterations: number;
  /** Trailing iterations with the same error fingerprint that stall the run. */
  readonly repeatFingerprint: number;
}

export const DEFAULT_PROGRESS_POLICY: ProgressPolicy = { stallIterations: 3, repeatFingerprint: 3 };

export type ProgressKind = "progressing" | "plateau" | "stalled" | "converged";

export interface ProgressVerdict {
  readonly kind: ProgressKind;
  readonly reasons: readonly string[];
}

/** True when the failing set strictly shrank, or the passing count rose (or was first measured). */
export function movedTests(prev: IterationSnapshot, cur: IterationSnapshot): boolean {
  const before = new Set(prev.failingTests);
  const after = new Set(cur.failingTests);
  const shrank = after.size < before.size && [...after].every((name) => before.has(name));
  const passedMore =
    prev.passingTests === null
      ? cur.passingTests !== null
      : cur.passingTests !== null && cur.passingTests > prev.passingTests;
  return shrank || passedMore;
}

/** Trailing iterations, counting back from the last, with no test movement. */
export function quietStreak(history: readonly IterationSnapshot[]): number {
  let streak = 0;
  for (let i = history.length - 1; i > 0; i--) {
    const cur = history[i];
    const prev = history[i - 1];
    if (cur === undefined || prev === undefined || movedTests(prev, cur)) break;
    streak++;
  }
  return streak;
}

/** Trailing iterations that share the last non-null error fingerprint. */
export function repeatStreak(history: readonly IterationSnapshot[]): number {
  const last = history.at(-1)?.errorFingerprint;
  if (last === null || last === undefined) return 0;
  let streak = 0;
  for (let i = history.length - 1; i >= 0 && history[i]?.errorFingerprint === last; i--) streak++;
  return streak;
}

export function assessProgress(
  history: readonly IterationSnapshot[],
  policy: ProgressPolicy,
): ProgressVerdict {
  const last = history.at(-1);
  if (last === undefined) return { kind: "progressing", reasons: ["no iterations yet"] };
  // A completion claim alone is not convergence: the tests must be green in the same iteration.
  if (last.loopCompleteClaimed && last.failingTests.length === 0 && last.passingTests !== null) {
    return { kind: "converged", reasons: ["completion claimed and tests green"] };
  }
  const quiet = quietStreak(history);
  const repeats = repeatStreak(history);
  if (quiet >= policy.stallIterations) {
    return { kind: "stalled", reasons: [`no test movement for ${quiet} iterations`] };
  }
  if (repeats >= policy.repeatFingerprint) {
    return { kind: "stalled", reasons: [`same error for ${repeats} iterations`] };
  }
  if (quiet >= 2) return { kind: "plateau", reasons: [`no test movement for ${quiet} iterations`] };
  return { kind: "progressing", reasons: ["test signal moved recently or history is short"] };
}

/** Validates the `progress assess --history FILE` JSON: an array of iteration snapshots. */
export function parseSnapshots(
  value: unknown,
):
  | { readonly ok: true; readonly snapshots: readonly IterationSnapshot[] }
  | { readonly ok: false; readonly reason: string } {
  if (!Array.isArray(value)) return { ok: false, reason: "history must be a JSON array" };
  const snapshots: IterationSnapshot[] = [];
  for (const [i, item] of value.entries()) {
    if (typeof item !== "object" || item === null)
      return { ok: false, reason: `snapshot ${i} is not an object` };
    const s = item as Record<string, unknown>;
    const valid =
      typeof s.index === "number" &&
      (s.passingTests === null || typeof s.passingTests === "number") &&
      Array.isArray(s.failingTests) &&
      s.failingTests.every((name) => typeof name === "string") &&
      typeof s.diffLines === "number" &&
      typeof s.newCommits === "number" &&
      (s.errorFingerprint === null || typeof s.errorFingerprint === "string") &&
      typeof s.loopCompleteClaimed === "boolean";
    if (!valid) return { ok: false, reason: `snapshot ${i} is malformed` };
    snapshots.push(item as IterationSnapshot);
  }
  return { ok: true, snapshots };
}
```

- [ ] **Step 2: Domain tests.** Copy this file as written (`src/contexts/delivery/domain/progress.test.ts`):

```ts
import { describe, expect, test } from "bun:test";
import {
  assessProgress,
  DEFAULT_PROGRESS_POLICY,
  type IterationSnapshot,
  movedTests,
  parseSnapshots,
} from "./progress";

const snap = (index: number, over: Partial<IterationSnapshot> = {}): IterationSnapshot => ({
  index,
  passingTests: null,
  failingTests: ["suite"],
  diffLines: 2,
  newCommits: 0,
  errorFingerprint: null,
  loopCompleteClaimed: false,
  ...over,
});

describe("assessProgress", () => {
  test("no test movement + repeated error → stalled", () => {
    const history = [1, 2, 3, 4].map((i) => snap(i, { errorFingerprint: "execution:abc" }));
    const v = assessProgress(history, DEFAULT_PROGRESS_POLICY);
    expect(v.kind).toBe("stalled");
  });

  test("diff growth and commits alone do not count as progress", () => {
    const history = [1, 2, 3, 4].map((i) => snap(i, { diffLines: i * 40, newCommits: i }));
    expect(assessProgress(history, DEFAULT_PROGRESS_POLICY).kind).toBe("stalled");
  });

  test("a shrinking failing set is progress", () => {
    const history = [
      snap(1, { failingTests: ["a", "b"] }),
      snap(2, { failingTests: ["a", "b"] }),
      snap(3, { failingTests: ["a"] }),
    ];
    expect(assessProgress(history, DEFAULT_PROGRESS_POLICY).kind).toBe("progressing");
  });

  test("two quiet iterations are a plateau, not a stall", () => {
    const history = [
      snap(1, { failingTests: ["a"] }),
      snap(2, { failingTests: ["a"] }),
      snap(3, { failingTests: ["a"] }),
    ];
    const v = assessProgress(history, { stallIterations: 4, repeatFingerprint: 9 });
    expect(v.kind).toBe("plateau");
  });

  test("a completion claim with red tests is not converged", () => {
    const history = [snap(1, { failingTests: ["a"], loopCompleteClaimed: true })];
    expect(assessProgress(history, DEFAULT_PROGRESS_POLICY).kind).not.toBe("converged");
  });

  test("a completion claim with green tests is converged", () => {
    const history = [snap(1, { passingTests: 10, failingTests: [], loopCompleteClaimed: true })];
    expect(assessProgress(history, DEFAULT_PROGRESS_POLICY).kind).toBe("converged");
  });

  test("an empty history is progressing, not stalled", () => {
    expect(assessProgress([], DEFAULT_PROGRESS_POLICY).kind).toBe("progressing");
  });
});

describe("movedTests", () => {
  test("the first measured passing count counts as movement", () => {
    expect(movedTests(snap(1), snap(2, { passingTests: 5 }))).toBe(true);
  });

  test("an unchanged failing set and count is not movement", () => {
    expect(movedTests(snap(1, { passingTests: 5 }), snap(2, { passingTests: 5 }))).toBe(false);
  });
});

describe("parseSnapshots", () => {
  test("accepts a well-formed history", () => {
    expect(parseSnapshots([snap(1)]).ok).toBe(true);
  });
  test("refuses a malformed snapshot rather than assessing it", () => {
    expect(parseSnapshots([{ index: "1" }])).toEqual({
      ok: false,
      reason: "snapshot 0 is malformed",
    });
  });
  test("refuses a non-array document", () => {
    expect(parseSnapshots({})).toEqual({ ok: false, reason: "history must be a JSON array" });
  });
});
```

- [ ] **Step 3: Run.**

Run: `bun test src/contexts/delivery/domain`
Expected: `12 pass`, `0 fail`. (9 `assessProgress` and `movedTests` tests, and 3 `parseSnapshots` tests.)

- [ ] **Step 4: Application and index.** Copy these as written.

`src/contexts/delivery/application/assess.ts`:
```ts
import type { FileReader } from "../../../shared/kernel/ports";
import {
  assessProgress,
  DEFAULT_PROGRESS_POLICY,
  type ProgressVerdict,
  parseSnapshots,
} from "../domain/progress";

export type AssessResult =
  | { readonly ok: true; readonly verdict: ProgressVerdict; readonly iterations: number }
  | { readonly ok: false; readonly reason: string };

/** Reads a history file and returns the verdict. Any read or parse failure is `ok: false`. */
export async function assessHistoryFile(files: FileReader, path: string): Promise<AssessResult> {
  const text = await files.readText(path);
  if (!text.ok) return { ok: false, reason: `cannot read history: ${text.error.message}` };
  let json: unknown;
  try {
    json = JSON.parse(text.value);
  } catch {
    return { ok: false, reason: "history is not JSON" };
  }
  const parsed = parseSnapshots(json);
  if (!parsed.ok) return { ok: false, reason: parsed.reason };
  return {
    ok: true,
    verdict: assessProgress(parsed.snapshots, DEFAULT_PROGRESS_POLICY),
    iterations: parsed.snapshots.length,
  };
}
```

`src/contexts/delivery/index.ts`:
```ts
export { type AssessResult, assessHistoryFile } from "./application/assess";
export {
  assessProgress,
  DEFAULT_PROGRESS_POLICY,
  type IterationSnapshot,
  type ProgressKind,
  type ProgressPolicy,
  type ProgressVerdict,
  parseSnapshots,
} from "./domain/progress";
```

- [ ] **Step 5: Command and tests.** Copy these as written.

`src/cli/commands/progress.ts`:
```ts
import { assessHistoryFile } from "../../contexts/delivery";
import type { Command } from "../command";

const usage = `USAGE
  shipwright progress assess --history FILE [--json]

DESCRIPTION
  Reads a build loop's iteration history and prints the progress verdict. Progress means
  test-signal movement; diff growth and new commits alone do not count.

EXIT CODES
  0  progressing, plateau or converged   3  stalled   1  could not read or assess (treat as no progress)   2  usage error`;

export const progressCommand: Command = {
  name: "progress",
  aliases: [],
  summary: "Assess a build loop's progress from its iteration history (W2-05)",
  usage,
  async run(args, ctx) {
    const [sub, ...rest] = args;
    if (sub === undefined || sub === "--help" || sub === "-h") {
      ctx.io.out(usage);
      return sub === undefined ? 2 : 0;
    }
    if (sub !== "assess") {
      ctx.io.err(`✗ unknown subcommand: ${sub}`);
      return 2;
    }
    const json = rest.includes("--json");
    const at = rest.indexOf("--history");
    const path = at === -1 ? undefined : rest[at + 1];
    if (path === undefined || path.startsWith("--")) {
      ctx.io.err("✗ --history FILE is required");
      return 2;
    }
    const result = await assessHistoryFile(ctx.files(), path);
    if (!result.ok) {
      ctx.io.err(`✗ ${result.reason}`);
      return 1;
    }
    const line = {
      kind: result.verdict.kind,
      reasons: result.verdict.reasons,
      iterations: result.iterations,
    };
    ctx.io.out(json ? JSON.stringify(line) : `${line.kind}: ${line.reasons.join("; ")}`);
    return result.verdict.kind === "stalled" ? 3 : 0;
  },
};
```

`src/cli/commands/progress.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { progressCommand } from "./progress";

const snap = (index: number) => ({
  index,
  passingTests: null,
  failingTests: ["suite"],
  diffLines: 2,
  newCommits: 0,
  errorFingerprint: "execution:abc",
  loopCompleteClaimed: false,
});
const files = new FakeFileReader({
  "/h/stall.json": JSON.stringify([1, 2, 3, 4].map(snap)),
  "/h/bad.json": "{not json",
});

describe("progress assess", () => {
  test("the repeated-error history is stalled with exit 3", async () => {
    const io = captureIO();
    const code = await progressCommand.run(
      ["assess", "--history", "/h/stall.json", "--json"],
      commandContext(io, undefined, {}, files),
    );
    expect(code).toBe(3);
    expect(JSON.parse(io.outLines[0] ?? "{}")).toMatchObject({ kind: "stalled" });
  });

  test("an unparseable history is an error with exit 1, never progress", async () => {
    const io = captureIO();
    expect(
      await progressCommand.run(
        ["assess", "--history", "/h/bad.json"],
        commandContext(io, undefined, {}, files),
      ),
    ).toBe(1);
  });

  test("a missing --history is a usage error with exit 2", async () => {
    const io = captureIO();
    expect(await progressCommand.run(["assess"], commandContext(io, undefined, {}, files))).toBe(2);
  });
});
```

- [ ] **Step 6: Register and route.** Add `progressCommand` to `src/cli/commands/index.ts`. In `scripts/sw`, add after the `failure)` block:

```bash
        progress)
            run_ts progress "$@"
            ;;
```
Add this entry to `docs/plans/port/progress.json`, then run `bun run docs:gen`:

```json
  {
    "command": "progress",
    "aliases": [],
    "script": null,
    "context": "delivery",
    "parity": null,
    "status": "parity-green",
    "notes": "New in Wave 2 (W2-05): progress verdict from the iteration history; test-signal movement only (ADR-0009)."
  }
```

- [ ] **Step 7: Run.**

Run: `bunx biome check --write src/contexts/delivery src/cli/commands/progress.ts src/cli/commands/progress.test.ts`
Run: `bun test src/contexts/delivery src/cli/commands/progress.test.ts`
Expected: `15 pass`, `0 fail`.

Run: `bun run check:fast && bun run port:check && bun run docs:check`
Expected: exit 0 for each.

**Known limit:** `movedTests` counts the first measured passing count as movement. The bash bridge (W2-06) records a single `suite` name, so it sees movement only when the suite goes green. That is coarse, and it is accepted for Tranche 1. Per-test names are a Tranche 2 refinement.

---

### W2-06: loop stall stop, one progress comment, progress-aware watchdog, build wall-clock cap

**Depends on:** #8610 merged. Progress signals mean nothing while the test gate can run real pipelines and mutate the checkout (E11). Until #8610 is merged, this task does not start.

**Purpose:** a run whose tests stop moving stops, instead of running to the cap. The watchdog measures time since the last test movement, not since the last timer tick. The build stage has a wall-clock cap from its template. A run with no test signal is never judged: no test command means no record and no stall.

**Files:**
- Create: `scripts/lib/progress-bridge.sh` (the text below, executed in a scratch copy)
- Create: `scripts/sw-lib-progress-bridge-test.sh` (the text below, executed against a repository shim of the test helpers)
- Modify: `scripts/sw-loop.sh` (exact insertions in Step 3; syntax-checked on a scratch copy)
- Modify: `scripts/lib/pipeline-stages-build.sh` (Step 4)
- Modify: `templates/pipelines/fast.json` (Step 5)
- Modify: `.github/workflows/shipwright-pipeline.yml` (Step 6, progress comment)
- Modify: `.github/workflows/shipwright-watchdog.yml` (Step 6, progress-aware liveness)

- [ ] **Step 1: The bridge.** Copy this file as written:

# shellcheck shell=bash
# progress-bridge.sh — per-iteration progress verdict from the TypeScript assessor (W2-05, W2-06).
# Each iteration with a test signal appends a snapshot to PROGRESS_HISTORY_FILE, then asks
# `shipwright progress assess`. An iteration without a test signal records nothing (C5).
# Fails closed: an assessor error is never "progressing"; an unwritable history is a plateau.
[[ -n "${_PROGRESS_BRIDGE_LOADED:-}" ]] && return 0
_PROGRESS_BRIDGE_LOADED=1
_PROGRESS_BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROGRESS_VERDICT="progressing"
PROGRESS_RECORDED="false"

# _progress_git_signals — prints "<diff_lines> <new_commits>" for committed work since LOOP_START_COMMIT
# (0 0 if unset). The loop commits after each iteration, so uncommitted edits are not counted.
_progress_git_signals() {
    local root="${PROJECT_ROOT:-.}" start="${LOOP_START_COMMIT:-}"
    if [[ -z "$start" ]]; then
        echo "0 0"
        return 0
    fi
    local stat diff_lines commits
    stat=$(git -C "$root" diff --shortstat "${start}..HEAD" 2>/dev/null || true)
    diff_lines=$(awk '{ for (i = 1; i <= NF; i++) { if ($i ~ /^insertion/) a += $(i-1); if ($i ~ /^deletion/) d += $(i-1) } } END { print a + d + 0 }' <<<"$stat")
    commits=$(git -C "$root" rev-list --count "${start}..HEAD" 2>/dev/null || echo 0)
    echo "${diff_lines:-0} ${commits:-0}"
}

# _progress_fingerprint <test_output> — failure fingerprint of red tests, from the TS classifier.
_progress_fingerprint() {
    local output="$1" bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-${_PROGRESS_BRIDGE_DIR}/../../src/cli.ts}"
    [[ -n "$output" ]] || { echo ""; return 0; }
    local tmp out rc=0
    tmp=$(mktemp) || { echo ""; return 0; }
    printf '%s\n' "$output" > "$tmp"
    out=$("$bun_bin" "$cli" failure classify --log "$tmp" --json 2>/dev/null) || rc=$?
    rm -f "$tmp"
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then echo ""; return 0; fi
    jq -r '.fingerprint // empty' <<<"$out" 2>/dev/null || echo ""
    return 0
}

# progress_bridge_record <iteration> <tests: true|false|""> <iteration_log>
# "" means no test signal (no test command, or no result): nothing is recorded, the verdict is
# "progressing", and the marker is left alone, so runs without tests are never marked stalled.
progress_bridge_record() {
    local index="$1" tests_passed="$2" iter_log="${3:-}"
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-${_PROGRESS_BRIDGE_DIR}/../../src/cli.ts}"
    local hist="${PROGRESS_HISTORY_FILE:-}"
    PROGRESS_RECORDED="false"
    PROGRESS_VERDICT="progressing"
    [[ "$tests_passed" == "true" || "$tests_passed" == "false" ]] || return 0
    PROGRESS_VERDICT="plateau"
    [[ -n "$hist" ]] || return 0

    local failing='[]' fingerprint="" loop_complete=false
    if [[ "$tests_passed" == "false" ]]; then
        failing='["suite"]'
        fingerprint=$(_progress_fingerprint "${TEST_OUTPUT:-}")
    fi
    if [[ -n "$iter_log" && -f "$iter_log" ]] && grep -q "LOOP_COMPLETE" "$iter_log"; then
        loop_complete=true
    fi
    local signals diff_lines commits
    signals=$(_progress_git_signals)
    diff_lines=${signals%% *}
    commits=${signals##* }

    local snap existing='[]' tmp
    if ! snap=$(jq -n \
        --argjson i "$index" \
        --argjson f "$failing" \
        --argjson d "$diff_lines" \
        --argjson c "$commits" \
        --arg e "$fingerprint" \
        --argjson lc "$loop_complete" \
        '{index: $i, passingTests: null, failingTests: $f, diffLines: $d, newCommits: $c,
          errorFingerprint: (if $e == "" then null else $e end), loopCompleteClaimed: $lc}'); then
        return 0
    fi
    [[ -s "$hist" ]] && existing=$(cat "$hist")
    tmp=$(mktemp "${hist}.tmp.XXXXXX") || return 0
    if ! jq --argjson s "$snap" '. + [$s]' <<<"$existing" > "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$hist" || { rm -f "$tmp"; return 0; }
    PROGRESS_RECORDED="true"

    local out rc=0
    out=$("$bun_bin" "$cli" progress assess --history "$hist" --json 2>/dev/null) || rc=$?
    case "$rc" in
        0) PROGRESS_VERDICT=$(jq -r '.kind // "plateau"' <<<"$out" 2>/dev/null || echo "plateau") ;;
        3) PROGRESS_VERDICT="stalled" ;;
        *) PROGRESS_VERDICT="plateau" ;;
    esac
    return 0
}

# progress_bridge_marker <verdict> — the run-scoped CI marker:
#   <!-- SHIPWRIGHT-PROGRESS: <run_id> <last-movement time|none> verdict=<verdict> -->
# The time moves only on a recorded progressing or converged verdict. Nothing is written when
# nothing was recorded this iteration.
progress_bridge_marker() {
    local verdict="$1" last_file="${PROGRESS_LAST_FILE:-}" marker_file="${PROGRESS_MARKER_FILE:-}"
    [[ -n "$last_file" && -n "$marker_file" ]] || return 0
    [[ "$PROGRESS_RECORDED" == "true" ]] || return 0
    if [[ "$verdict" == "progressing" || "$verdict" == "converged" ]]; then
        date -u +%Y-%m-%dT%H:%M:%SZ > "$last_file.tmp" && mv "$last_file.tmp" "$last_file"
    fi
    local last="none" run="${GITHUB_RUN_ID:-local}"
    [[ -s "$last_file" ]] && last=$(cat "$last_file")
    printf '<!-- SHIPWRIGHT-PROGRESS: %s %s verdict=%s -->\n' "$run" "$last" "$verdict" > "$marker_file.tmp" \
        && mv "$marker_file.tmp" "$marker_file"
    return 0
}

- [ ] **Step 2: The hermetic test.** Create `scripts/sw-lib-progress-bridge-test.sh` with this text. It sources the repository helpers, `scripts/lib/test-helpers.sh`, which provide `assert_eq`, `assert_contains`, `print_test_header`, `setup_test_env`, `cleanup_test_env` and `print_test_results`:

#!/usr/bin/env bash
# sw-lib-progress-bridge-test.sh — hermetic: a fake Bun answers the verdict; a temporary git repo
# supplies the diff and commit signals. No GitHub, no tmux, no model.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: progress-bridge Tests"
setup_test_env "sw-lib-progress-bridge-test"
trap cleanup_test_env EXIT

FAKE="$TEST_TEMP_DIR/fakebun"
cat > "$FAKE" <<'FAKE_EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "failure" ]]; then echo '{"class":"execution","fingerprint":"execution:beef","action":"escalate","reason":"x"}'; exit 3; fi
case "$FAKE_VERDICT" in
  stalled) echo '{"kind":"stalled","reasons":["x"]}'; exit 3 ;;
  error) exit 1 ;;
  *) echo "{\"kind\":\"$FAKE_VERDICT\",\"reasons\":[]}"; exit 0 ;;
esac
FAKE_EOF
chmod +x "$FAKE"

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
BASE=$(git -C "$REPO" rev-parse HEAD)

export SW_BUN="$FAKE" PROJECT_ROOT="$REPO" LOOP_START_COMMIT="$BASE"
export PROGRESS_HISTORY_FILE="$TEST_TEMP_DIR/hist.json"
export PROGRESS_LAST_FILE="$TEST_TEMP_DIR/last" PROGRESS_MARKER_FILE="$TEST_TEMP_DIR/marker"
export GITHUB_RUN_ID=38744601038
source "$SCRIPT_DIR/lib/progress-bridge.sh"

printf 'a\nb\n' > "$REPO/file.txt"
assert_eq "uncommitted edits are not counted (the loop commits per iteration)" "0 0" "$(_progress_git_signals)"
git -C "$REPO" add file.txt && git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m one
assert_eq "a commit since the loop started is counted with its lines" "2 1" "$(_progress_git_signals)"

TEST_OUTPUT="FAIL suite: 2 failing"
FAKE_VERDICT=progressing progress_bridge_record 1 false
assert_eq "red tests record a snapshot and an assessor 'progressing' passes through" "progressing" "$PROGRESS_VERDICT"
assert_eq "the red-test fingerprint comes from the TS classifier" "execution:beef" "$(jq -r '.[0].errorFingerprint' "$PROGRESS_HISTORY_FILE")"
assert_eq "the history records the commit count" "1" "$(jq -r '.[0].newCommits' "$PROGRESS_HISTORY_FILE")"

FAKE_VERDICT=stalled progress_bridge_record 2 false
assert_eq "an assessor stall (exit 3) is reported as stalled" "stalled" "$PROGRESS_VERDICT"
FAKE_VERDICT=error progress_bridge_record 3 false
assert_eq "an assessor error counts as no progress, never progressing" "plateau" "$PROGRESS_VERDICT"

PROGRESS_RECORDED="false"
FAKE_VERDICT=stalled progress_bridge_record 4 ""
assert_eq "no test signal: nothing is recorded" "progressing" "$PROGRESS_VERDICT"
assert_eq "no test signal: the history is not appended" "3" "$(jq length "$PROGRESS_HISTORY_FILE")"

FAKE_VERDICT=progressing progress_bridge_record 5 true
progress_bridge_marker plateau
assert_contains "the marker is run-scoped to the CI run" "$(cat "$PROGRESS_MARKER_FILE")" "SHIPWRIGHT-PROGRESS: 38744601038 none verdict=plateau"
progress_bridge_marker progressing
assert_eq "a progressing verdict stamps an ISO time" "true" \
    "$(grep -qE 'SHIPWRIGHT-PROGRESS: 38744601038 [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z verdict=progressing' "$PROGRESS_MARKER_FILE" && echo true || echo false)"
STAMP=$(cat "$PROGRESS_LAST_FILE")
PROGRESS_RECORDED="false"
progress_bridge_marker plateau
assert_eq "an unrecorded iteration does not rewrite the marker" "true" \
    "$(grep -q "verdict=progressing" "$PROGRESS_MARKER_FILE" && echo true || echo false)"
PROGRESS_RECORDED="true"
progress_bridge_marker plateau
assert_contains "a plateau keeps the last movement time" "$(cat "$PROGRESS_MARKER_FILE")" "$STAMP"

print_test_results

- [ ] **Step 3: Insertions in `scripts/sw-loop.sh`.** Each anchor appears exactly once in the file. The block below was applied to a scratch copy and parsed with `bash -n`.

(a) After the line `[[ -f "$SCRIPT_DIR/lib/convergence.sh" ]] && source "$SCRIPT_DIR/lib/convergence.sh" 2>/dev/null || true`, add:
```bash
[[ -f "$SCRIPT_DIR/lib/progress-bridge.sh" ]] && source "$SCRIPT_DIR/lib/progress-bridge.sh"
```

(b) After `    STUCKNESS_TRACKING_FILE="$LOG_DIR/stuckness-tracking.txt"`, add (C4: CI exports these, so the loop keeps them):
```bash
    # CI exports these so the marker reaches the workflow; keep the exported values (W2-06 C4).
    : "${PROGRESS_HISTORY_FILE:=$LOG_DIR/progress-history.json}"
    : "${PROGRESS_LAST_FILE:=$LOG_DIR/progress-last.txt}"
    : "${PROGRESS_MARKER_FILE:=$LOG_DIR/progress.marker}"
    export PROGRESS_HISTORY_FILE PROGRESS_LAST_FILE PROGRESS_MARKER_FILE
```

(c) Before the line `    # Ensure LOOP_START_COMMIT is set (may not be on resume/restart)`, add the contamination baseline:
```bash
    # Contamination baseline (E11): the branch and pipeline state present when the loop starts.
    : "${LOOP_START_BRANCH:=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"
    PIPELINE_STATE_SEEN=false
    [[ -f "$PROJECT_ROOT/.claude/pipeline-state.md" ]] && PIPELINE_STATE_SEEN=true
```

(d) Before the line `        # Convergence detection (issue #203) — score iteration progress and detect convergence`, add the contamination check, the progress verdict and the stall stop:
```bash
        # Contamination (E11): the loop records what it can see of a checkout changed under it.
        if [[ "${PIPELINE_STATE_SEEN:-false}" == "true" && ! -f "$PROJECT_ROOT/.claude/pipeline-state.md" ]]; then
            echo "CONTAMINATION: pipeline-state-missing" | tee -a "$LOG_FILE" >&2
        fi
        if [[ -n "${LOOP_START_BRANCH:-}" ]]; then
            _cur_branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [[ -n "$_cur_branch" && "$_cur_branch" != "$LOOP_START_BRANCH" ]]; then
                echo "CONTAMINATION: branch-switched $LOOP_START_BRANCH -> $_cur_branch" | tee -a "$LOG_FILE" >&2
            fi
        fi

        # W2-06: progress verdict from test-signal movement (C5). No test signal: nothing recorded.
        progress_bridge_record "$ITERATION" "$TEST_PASSED" "$LOG_FILE"
        progress_bridge_marker "$PROGRESS_VERDICT"
        if [[ "$PROGRESS_VERDICT" == "stalled" ]]; then
            STATUS="stalled"
            write_state
            write_progress
            warn "No test progress across recent iterations: stopping before the iteration cap"
            break
        fi
```

(e) After the three lines `    write_state` / `    write_progress` / `    show_summary` that end `run_single_agent_loop` (the block after the comment `    # Write final state after loop exits`), add:
```bash

    # A stall is neither success nor a restart candidate (W2-06): exit 4 for the caller.
    if [[ "$STATUS" == "stalled" ]]; then
        return 4
    fi
```

(f) In `run_loop_with_restarts`, immediately after the `if [[ "$STATUS" == "complete" ]]; then ... fi` block, add:
```bash
        # A stall skips the restart logic entirely (W2-06).
        if [[ "$STATUS" == "stalled" ]]; then
            return 4
        fi
```

(g) In the `show_summary` status `case`, before the line `        error)            status_display=`, add:
```bash
        stalled)          status_display="${RED}✗ Stalled (no test progress)${RESET}" ;;
```

- [ ] **Step 4: Build stage (`scripts/lib/pipeline-stages-build.sh`).** Replace the single line `sw loop "${loop_args[@]}" < /dev/null 2>"$_token_log" || {` with the block below. A local `timeout` or `gtimeout` enforces the cap. On macOS without either, the cap is enforced only on CI, where a missing timeout stops the stage (I3):
```bash
    local build_cap_min cap_cmd="" loop_cmd=(sw loop "${loop_args[@]}")
    build_cap_min=$(jq -r '(.stages[] | select(.id == "build") | .config.max_minutes) // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
    if command -v timeout >/dev/null 2>&1; then
        cap_cmd=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        cap_cmd=gtimeout
    fi
    if [[ "$build_cap_min" =~ ^[1-9][0-9]{0,3}$ ]]; then
        if [[ -n "$cap_cmd" ]]; then
            loop_cmd=("$cap_cmd" "$((build_cap_min * 60))" "${loop_cmd[@]}")
        elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            error "build wall-clock cap needs timeout(1) on CI"
            return 1
        else
            warn "build wall-clock cap not enforced: install coreutils (gtimeout) to enforce it locally"
        fi
    fi
    "${loop_cmd[@]}" < /dev/null 2>"$_token_log" || {
        local _loop_exit=$?
        if [[ "$_loop_exit" -eq 124 ]]; then
            warn "Build exceeded its ${build_cap_min}-minute wall-clock cap"
            emit_event "pipeline.build_wall_clock_cap" "issue=${ISSUE_NUMBER:-0}" "minutes=${build_cap_min}"
        fi
        if [[ "$_loop_exit" -eq 4 ]]; then
            # A stall is not context exhaustion: the context-exhaustion branch below must not run.
            warn "Build stalled: no test progress across recent iterations"
            emit_event "pipeline.build_stalled" "issue=${ISSUE_NUMBER:-0}"
            return 1
        fi
```
The original block continues with `parse_claude_tokens "$_token_log"` and the context-exhaustion check, and both stay unchanged.

- [ ] **Step 5: Template.** In `templates/pipelines/fast.json`, change the `build` stage config from `"max_iterations": 10,` to:
```json
      "max_iterations": 10,
      "max_minutes": 60,
```
Run: `python3 -c "import json;print([s['config'].get('max_minutes') for s in json.load(open('templates/pipelines/fast.json'))['stages'] if s['id']=='build'])"`
Expected: `[60]`

- [ ] **Step 6: CI progress comment and watchdog.**

(a) In `.github/workflows/shipwright-pipeline.yml`, replace the heartbeat block (from the comment `# Heartbeat: post progress marker every 10 minutes...` through `HEARTBEAT_PID=$!`) with:
```bash
          # Progress comment (W2-06): one comment, edited every 10 minutes. The marker is run-scoped and
          # holds the time of the last test movement, written by sw-loop. The alive line is a timer.
          export PROGRESS_LAST_FILE="$RUNNER_TEMP/progress.last"
          export PROGRESS_MARKER_FILE="$RUNNER_TEMP/progress.marker"
          (
            COMMENT_ID=""
            while true; do
              sleep 600
              MARKER=$(cat "$PROGRESS_MARKER_FILE" 2>/dev/null || echo "<!-- SHIPWRIGHT-PROGRESS: ${GITHUB_RUN_ID} none verdict=unknown -->")
              BODY="$MARKER"$'\n'"<!-- SHIPWRIGHT-ALIVE: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->"
              if [[ -z "$COMMENT_ID" ]]; then
                COMMENT_ID=$(gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE_NUMBER/comments" -f body="$BODY" --jq '.id') \
                  || echo "::warning::progress comment could not be created"
              else
                gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$COMMENT_ID" -f body="$BODY" >/dev/null \
                  || echo "::warning::progress comment could not be updated"
              fi
            done
          ) &
          HEARTBEAT_PID=$!
```
A failed write does not refresh the watchdog's clock, so the watchdog eventually acts. The failure is in the job log as a warning, not swallowed.

(b) In `.github/workflows/shipwright-watchdog.yml`, replace the block from `# Find the most recent SHIPWRIGHT-HEARTBEAT or SHIPWRIGHT-STAGE marker` through the closing `fi` of `if [[ -z "$LAST_SIGNAL_DATE" ]]` with:
```bash
            # Last progress signal (W2-06, I1): the newest of the run-scoped SHIPWRIGHT-PROGRESS time,
            # the SHIPWRIGHT-STAGE time and the run start. Heartbeats are timers and are not read.
            # COMMENTS_JSON is bot-authored only (scripts/ci/bot-comments.sh).
            PROGRESS_MARKER=$(jq -r --arg r "$RUN_ID" '[.[] | .body | strings | select(contains("SHIPWRIGHT-PROGRESS: \($r) "))] | last // ""' <<<"$COMMENTS_JSON")
            PROGRESS_DATE=$(sed -n 's/.*SHIPWRIGHT-PROGRESS: [^ ]* \([0-9T:Z-]*\).*/\1/p' <<<"$PROGRESS_MARKER" | tail -1)
            STAGE_DATE=$(jq -r '[.[] | select(.body | contains("SHIPWRIGHT-STAGE")) | .createdAt] | last // ""' <<<"$COMMENTS_JSON")
            START_DATE=$(jq -r --arg m "SHIPWRIGHT-RUN-ID: $RUN_ID" '[.[] | select(.body | contains($m)) | .createdAt] | last // ""' <<<"$COMMENTS_JSON")
            LAST_SIGNAL_DATE=$(printf '%s\n' "$PROGRESS_DATE" "$STAGE_DATE" "$START_DATE" "$CREATED_AT" | grep -E '^[0-9]{4}-' | sort | tail -1)
```
The code after this block, which computes elapsed minutes and applies the 45-minute and 2-hour thresholds, stays unchanged. `CREATED_AT` is always present, so `LAST_SIGNAL_DATE` is never empty. A marker written by an earlier run has a different run id and is ignored.

- [ ] **Step 7: Verify.**

Run: `bash scripts/sw-test-all.sh --pattern sw-lib-progress-bridge-test`
Expected: exit 0, `13 passed, 0 failed` in the suite's own summary.

Run: `shellcheck -x -S warning -e SC2034,SC1090,SC2148,SC2119,SC2120 scripts/lib/progress-bridge.sh scripts/sw-lib-progress-bridge-test.sh`
Expected: no output.

Run: `actionlint .github/workflows/shipwright-pipeline.yml .github/workflows/shipwright-watchdog.yml`
Expected: no output, exit 0.

Run: `bun run arch`
Expected: exit 0. Bash findings must not grow.

**Stall path (specified, not executed in this revision).** A hermetic `scripts/sw-loop-stall-test.sh` runs `sw loop --max-restarts 2` in a temporary git repository, with a test command that always prints the same failure and a fake `claude` that prints one line per call. It expects exit 4, three iteration logs (the fingerprint repeats three times), `STATUS=stalled`, and `RESTART_COUNT=0`. It runs only after #8610 is merged, and it is not part of this revision because it needs the sw-loop edits applied to the repository.

**Verified in scratch:** the bridge (13 assertions in the hermetic test, against a repository shim of the helpers), the classifier fingerprint through the bridge, the three-state test signal, committed-only diff and commit signals in a real temporary repository, and the run-scoped marker. Not executed: the sw-loop insertions beyond `bash -n` on a copy.


---

### W2-07: deterministic model routing hygiene

**Purpose:** the build model is the template's model, not a learned or random choice. The model IDs live in one file. Templates use aliases. `sw loop` accepts `xhigh`.

**Files:**
- Create: `config/models.json`
- Create: `scripts/lib/models.sh`
- Create: `tools/models/no-pinned-models.test.ts`
- Modify: `scripts/lib/pipeline-execution.sh` (two conditions)
- Modify: `scripts/lib/pipeline-stages-build.sh` (recruit guard, alias resolution)
- Modify: `scripts/sw-loop.sh` (effort validation and help text)
- Modify: `scripts/sw-strategic.sh` (model constant)
- Modify: `templates/pipelines/autonomous.json`, `full.json`, `cost-aware.json` (aliases)
- Modify: `.github/workflows/review-remediation.yml` (model from config)
- Modify: `.github/workflows/shipwright-pipeline.yml` (triage model from config)

- [ ] **Step 1: The models file.** Create `config/models.json`:

```json
{
  "version": 1,
  "aliases": {
    "opus": "claude-opus-5-5",
    "sonnet": "claude-sonnet-5-5",
    "haiku": "claude-haiku-5-5"
  },
  "efforts": ["low", "medium", "high", "xhigh"],
  "allowlist": {
    "files": [
      "config/models.json",
      "scripts/sw-cost.sh",
      "scripts/*-test.sh",
      "src/**/*.test.ts",
      "tools/models/*.test.ts"
    ]
  }
}
```
`scripts/sw-cost.sh` is allowlisted for its pricing table, which must name every generation it prices (its own comment says so). The `*-test.sh` and `*.test.ts` patterns allow fixtures.

- [ ] **Step 2: The resolver.** Create `scripts/lib/models.sh`:

```bash
# shellcheck shell=bash
# models.sh — resolves a model alias through config/models.json (W2-07). A name that is not an
# alias passes through unchanged. The no-pinned-models test refuses any ID outside the alias values.
models_resolve() {
    local name="$1"
    local root file
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    file="${SW_MODELS_FILE:-$root/config/models.json}"
    if [[ ! -f "$file" ]]; then
        echo "models: $file is missing; cannot resolve '$name'" >&2
        return 1
    fi
    jq -r --arg a "$name" '.aliases[$a] // $a' "$file"
}
```

- [ ] **Step 3: Failing test first.** Create `tools/models/no-pinned-models.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = process.cwd();
const config = JSON.parse(readFileSync(join(ROOT, "config/models.json"), "utf8")) as {
  aliases: Record<string, string>;
  allowlist: { files: string[] };
};
const ID = /claude-(?:opus|sonnet|haiku)-[a-z0-9.-]+/g;
const TARGETS = [".github/workflows", "templates/pipelines", "scripts", "src", "tools"];
const EXTENSIONS = /\.(ya?ml|json|sh|ts)$/;

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : EXTENSIONS.test(name) ? [path] : [];
  });
}

/** `*` matches within a path segment; `**` matches any depth. Dots are literal. */
function globToRegex(glob: string): RegExp {
  const escaped = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  return new RegExp(
    `^${escaped
      .replace(/\*\*/g, "<<GLOBSTAR>>")
      .replace(/\*/g, "[^/]*")
      .replace(/<<GLOBSTAR>>/g, ".*")}$`,
  );
}

const allowed = config.allowlist.files.map(globToRegex);
const isAllowlisted = (rel: string) => allowed.some((re) => re.test(rel));
const aliasValues = new Set(Object.values(config.aliases));

describe("model IDs", () => {
  test("no file outside the allowlist names a model ID that is not an alias value", () => {
    const violations: string[] = [];
    for (const target of TARGETS) {
      for (const file of walk(join(ROOT, target))) {
        const rel = relative(ROOT, file);
        if (isAllowlisted(rel)) continue;
        for (const id of readFileSync(file, "utf8").match(ID) ?? []) {
          if (!aliasValues.has(id)) violations.push(`${rel}: ${id}`);
        }
      }
    }
    expect(violations, "name models through config/models.json aliases").toEqual([]);
  });

  test("the aliases name the Claude 5.5 family", () => {
    expect(config.aliases).toEqual({
      opus: "claude-opus-5-5",
      sonnet: "claude-sonnet-5-5",
      haiku: "claude-haiku-5-5",
    });
  });

  test("the allowlist names only test files and the pricing table", () => {
    for (const glob of config.allowlist.files) {
      const ok =
        glob.includes("test") || glob === "scripts/sw-cost.sh" || glob === "config/models.json";
      expect(ok, `unexpected allowlist entry: ${glob}`).toBe(true);
    }
  });
});
```

Run: `bun test tools/models`
Expected before Steps 4 to 6: `1 fail`. The message lists six violations: `.github/workflows/review-remediation.yml`, `.github/workflows/shipwright-pipeline.yml`, `scripts/sw-strategic.sh`, `templates/pipelines/autonomous.json`, `templates/pipelines/cost-aware.json`, `templates/pipelines/full.json`.

- [ ] **Step 4: Stop routing learners by default.** In `scripts/lib/pipeline-execution.sh`, change these two lines (both are unique in the file):

From:
```bash
        if type ucb1_select_model >/dev/null 2>&1; then
```
To:
```bash
        # W2-07: learned routing (UCB1, A/B) is off unless SW_LEGACY_MODEL_ROUTING=true.
        if [[ "${SW_LEGACY_MODEL_ROUTING:-false}" == "true" ]] && type ucb1_select_model >/dev/null 2>&1; then
```

From:
```bash
        if [[ -z "$recommended_model" ]] && type intelligence_recommend_model >/dev/null 2>&1; then
```
To:
```bash
        if [[ "${SW_LEGACY_MODEL_ROUTING:-false}" == "true" && -z "$recommended_model" ]] && type intelligence_recommend_model >/dev/null 2>&1; then
```

In `scripts/lib/pipeline-stages-build.sh`, change:

From:
```bash
    if [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
```
To:
```bash
    # W2-07: recruit's model override is off unless SW_LEGACY_MODEL_ROUTING=true.
    if [[ "${SW_LEGACY_MODEL_ROUTING:-false}" == "true" ]] && [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
```

**Answer to Q8:** with these three learners off, the build model is the template's `defaults.model` (or the stage config's model), so `fast.json` (`sonnet`) runs on Sonnet. The incident run's opus model came from one of the three learners or from the retry escalation in `daemon-failure.sh`, which sets opus on retry 1. The ledger (W2-08) records the effective model for each run, so this stops being a guess.

- [ ] **Step 5: Resolve aliases at the build stage.** At the top of `scripts/lib/pipeline-stages-build.sh`, after the existing header and before the first function, add:
```bash
source "$(dirname "${BASH_SOURCE[0]}")/models.sh"
```
Immediately before the line `    loop_args+=(--model "$build_model")` in `scripts/lib/pipeline-stages-build.sh` (around line 416), add the resolution. This is the one point where `$MODEL`, `CLAUDE_MODEL` and the template values have all been applied, so all three resolve (I4):
```bash
    build_model=$(models_resolve "$build_model") || return 1
```
Note: every other template consumer of a model (review, audit and similar stages) must also call `models_resolve`. This task covers the build stage, and W2-07 Step 9 lists the consumers that remain.

- [ ] **Step 6: Allow `xhigh`.** In `scripts/sw-loop.sh`, change line 408 from:
```bash
if [[ -n "$EFFORT_LEVEL" ]] && [[ "$EFFORT_LEVEL" != "low" && "$EFFORT_LEVEL" != "medium" && "$EFFORT_LEVEL" != "high" ]]; then
```
to:
```bash
if [[ -n "$EFFORT_LEVEL" ]] && [[ "$EFFORT_LEVEL" != "low" && "$EFFORT_LEVEL" != "medium" && "$EFFORT_LEVEL" != "high" && "$EFFORT_LEVEL" != "xhigh" ]]; then
```
and the error message on line 409 to `error "--effort must be low, medium, high or xhigh (got: $EFFORT_LEVEL)"`, and the help text on line 186 to `low|medium|high|xhigh`. Before the default route uses `xhigh`, confirm that the effort string reaches the Claude CLI unchanged (`scripts/lib/compat.sh:424–456` returns the override as-is). The Step 9 check covers this.

- [ ] **Step 7: Templates and workflows to aliases.** For the three templates, replace the quoted strings exactly:
```bash
python3 - <<'PY'
import pathlib
mapping = {'"claude-opus-5"': '"opus"', '"claude-sonnet-5"': '"sonnet"', '"claude-haiku-4-5"': '"haiku"'}
for name in ["autonomous.json", "full.json", "cost-aware.json"]:
    p = pathlib.Path("templates/pipelines") / name
    text = p.read_text()
    for old, new in mapping.items():
        text = text.replace(old, new)
    p.write_text(text)
print("converted")
PY
```
Expected: `converted`. In `scripts/sw-strategic.sh` line 52, change `STRATEGIC_MODEL="claude-sonnet-5"` to `STRATEGIC_MODEL="claude-sonnet-5-5"` (a value of the alias map, so it passes the test). In `.github/workflows/review-remediation.yml` line 136, replace `--model claude-sonnet-4-20250514` with `--model "$(jq -r '.aliases.sonnet' config/models.json)"`. In `.github/workflows/shipwright-pipeline.yml` line 211, replace `--model claude-haiku-4-5-20251001` with `--model "$(jq -r '.aliases.haiku' config/models.json)"`. Both workflow steps need the repository checked out first; confirm each step has `actions/checkout` earlier in its job.

- [ ] **Step 8: Run the policy test.**

Run: `bun test tools/models`
Expected: `3 pass`, `0 fail`.

- [ ] **Step 9: Check the remaining consumers and the effort flag.**

Run: `grep -rn "\"model\"" templates/pipelines/*.json | grep -v '"opus"\|"sonnet"\|"haiku"' || echo "all template models are aliases"`
Expected: `all template models are aliases`.

Run: `bash scripts/sw-test-all.sh --pattern sw-loop-test`
Expected: exit 0 with the existing loop assertions. This is a hermetic suite. The effort change is covered by the existing loop validation; the `xhigh` path is checked without `--help`, which exits before validation. In the hermetic test repository, run `bash scripts/sw-loop.sh --effort xhigh <a goal>` and assert that the output does not contain `--effort must be`. The loop's own exit status is not asserted.

Run: `bun run check`
Expected: exit 0.

---

### W2-20: arch ratchet for real-service test suites (after #8610 merges)

**Depends on:** #8610 merged, because the gate this rule checks (`SHIPWRIGHT_E2E_REAL`) is introduced there. The GitHub issue is created by the maintainer.

**Purpose:** a test suite that reaches real services must be gated on `SHIPWRIGHT_E2E_REAL=1`. The number of ungated suites may only go down, as with the other ratchets (ADR-0008).

**Candidate verification (read-only, done in this revision).** The reviewer's six candidates were checked. Five are false positives.

| Suite | What matched | Verdict |
|---|---|---|
| `scripts/sw-integration-claude-test.sh` | real `claude -p` calls (lines 38 to 42), wrapped in `timeout` or `gtimeout` | **true positive**, ungated |
| `scripts/sw-e2e-integration-test.sh` | real pipeline and real services | true positive, **gated by #8610** |
| `scripts/sw-agi-roadmap-test.sh` | greps the source text for `claude -p` (lines 427 to 434) | false positive: source text |
| `scripts/sw-intelligence-test.sh` | a comment (line 47) | false positive |
| `scripts/sw-tracker-providers-test.sh` | test names; a mock `gh` is put first on `PATH` (lines 65, 102, 154) | false positive: mocked |
| `scripts/sw-lib-daemon-gates-test.sh` | assertions on mock call logs (three mocks) | false positive: mocked |
| `scripts/sw-lib-safety-gates-sites-test.sh` | a structural ratchet that greps the source for `gh issue create` | false positive: source text |
| `scripts/sw-e2e-system-test.sh`, `sw-e2e-smoke-test.sh`, `sw-pipeline-test.sh` | run `sw-pipeline.sh` in a temporary project with mock `gh` and `claude` on `PATH` | mocked: outside this rule, which targets real services |

**Detector.** A finding needs an executable line (not a comment, and not inside an assertion string) that calls `gh (issue|pr) (create|edit|comment|close)` or `claude -p`, or that contains the literal `api.anthropic.com` or `api.github.com`, in a suite that puts no mock on `PATH` and does not check `SHIPWRIGHT_E2E_REAL`. Matching is by line and by suite. It is not a plain grep, which is why the false positives above are excluded.

**Files:**
- Create: `tools/arch/e2e-gate.ts` (the detector)
- Create: `tools/arch/e2e-gate.test.ts` (fixtures: a comment line gives no finding; a source-text assertion gives no finding; an executed `gh issue create` with no mock gives a finding; the same line with a mock on `PATH` gives none; a suite that checks `SHIPWRIGHT_E2E_REAL` gives none)
- Create: `tools/arch/e2e-gate-baseline.json` (the findings at landing; expected: one entry, `scripts/sw-integration-claude-test.sh`)
- Modify: `package.json` (`arch` script runs the detector)

- [ ] **Step 1: Failing fixture tests first.** Run: `bun test tools/arch/e2e-gate.test.ts`. Expected before the detector exists: a module-not-found failure.
- [ ] **Step 2: Implement and generate the baseline.** Run: `bun tools/arch/e2e-gate.ts --write-baseline`. Expected: `baseline: 1 finding (scripts/sw-integration-claude-test.sh)`.
- [ ] **Step 3: Verify.** Run: `bun test tools/arch/e2e-gate.test.ts` (expected: all pass). Run: `bun run arch` (expected: exit 0). A new ungated real-service suite fails the check, and the message names the rule and the fix: "gate this suite on SHIPWRIGHT_E2E_REAL=1 or mock its binaries".

**Ratchet rule.** The baseline may only shrink. Gating a suite or mocking its binaries removes an entry. Adding an entry fails the check.

---

## Tranche 2 (W2-08 to W2-12): task level, with fixes applied

Each task expands to Wave 1a detail before it starts.

### W2-08: ledger core

- **Entries are typed journal rows.** A ledger entry is a `JournalEntry` (`src/shared/kernel/durability.ts`, `type`, `at`, `data`), written through `RunJournal.append(fence, entry)` (`durability.ts:98`). Every append is fenced, as AGENTS.md requires. Payload types: `run_started`, `agent_call`, `decision`, `iteration`, `outcome`, `tool_call`, `handoff`, `fence_violation`. A `tool_call` stores `argsHash` (SHA-256 of the canonical arguments), never the raw arguments.
- **`run_started` header.** Repo, issue, template, machine, mode (M1, M2 or M3), and the policy versions in force (routing, classifier, progress).
- **Partition by date.** `ledger/<yyyy-mm-dd>/<runId>.jsonl` for the JSONL adapter, so each day's directory is small and can be restored or merged separately.
- **`RunIndex.listRuns({issue, since})`.** A read-only port for finding runs. It does not write.
- **Read results carry `scope`.** `"local"` for this machine's files; `"shared"` for data read from the CI data branch or Postgres. Policies must say which scope they read.
- **Run-id validation in the port.** `validateRunId` is part of the port contract and is enforced in every `read` and `append` of every adapter. This fixes the failing A2 test: `FakeLedger.read("../x")` must return an error, not `ok`. The contract suite gets traversal and corrupt-line cases.
- **Fence.** Before Wave 1b, the JSONL adapter has no fence, so it accepts only a fence supplied by the caller. On CI the pseudo-fence is `GITHUB_RUN_ID` plus `GITHUB_RUN_ATTEMPT`, which is unique per attempt.
- **No invented run ids.** The earlier `issue-N-$(date +%s)` ids are dropped. A run id comes from the run itself (`GITHUB_RUN_ID` on CI, the daemon's job id locally).
- **Typed contract.** Zod validates persisted lines in the adapter. The domain type stays zod-free.

### W2-09: ledger on CI

- Install Bun with the pinned setup action and `bun install --frozen-lockfile --ignore-scripts` before any ledger command in `shipwright-pipeline.yml`.
- The outcome append **annotates and does not fail the job** (`::warning::`). Readers treat a missing or failed entry as missing data, never as an empty history.
- Persist ledger files with a fast-forward push and retry, never with `--force`. The force-push fallbacks at `shipwright-pipeline.yml` (around line 878) and `shipwright-optimize.yml:111` must not touch the ledger path.
- A restore sentinel: a missing or empty ledger directory counts as unreadable, not as empty (fix D4).
- **Verification:** until a sandbox is approved (Q3, default none), run one manual `shipwright-pipeline.yml` run on this repository against an issue labelled `e2e-test`. Expect a ledger file on `shipwright-data` after the run, whose last line is an `outcome`.

### W2-10: decisions in the ledger

- Every adaptive decision appends a `decision` entry with its inputs, its policy version, and its output: the failure classifier (`failure-v1`), the progress verdict (`progress-v1`), the routing choice (`routing-v1`), and the budget check.
- Replay: given the entries for a run, the decision sequence can be recomputed from the stored inputs and must match the stored outputs.
- Test: a fixture run whose recomputed decisions differ from its stored ones is reported as a replay failure.

### W2-11: routing table and difficulty, tighten-only

- **Difficulty comes from ledger history.** The model's own estimate is never an input (E1).
- **Tighten-only.** Difficulty may lower a tier's caps or escalate the route. The one exception is an up-tier after a `budget` or `max_turns` failure. This exception is recorded in ADR-0009 rule 3 with its reason.
- **Incumbent.** `routing-v1` is the current defaults. Changing it is a ratchet decision (W2-13).
- **Model IDs.** Routes name aliases; `config/models.json` (W2-07) resolves them.
- **Effort.** Every route sets `effort` explicitly, because Opus 5.5 defaults to `medium`. Routes never send `thinking: {type: "disabled"}` or `budget_tokens` to the 5.5 models, which the API rejects.

- **Contaminated history (E11).** Runs from before #8610 merged are excluded from difficulty and from the p90 caps, or tagged `contaminated` and excluded. Their outcomes came from a test gate that could file real issues and change the checkout.

### W2-12: CI cost and runtime budget

- **Cost source (Q6).** Confirm the usage fields that `claude` emits in JSON output with one approved sandbox run. Parse them with zod, and fail closed on an unknown shape.
- **Runtime budget.** A `budget run-check` bash bridge runs before each iteration. It sums the run's `agent_call` costs from the ledger, compares them with the tier cap from the routing table, and stops the run as `escalated` with reason `budget` when the next iteration would exceed it.
- **CI gate.** The day's spend is read from the ledger. A missing or unreadable ledger blocks the gate (fail closed).
- **Caps are not predictions.** Set each tier's cap from the 90th percentile of history once history exists. Until then the placeholders in `routing-v1` apply and are labelled as placeholders.

---

## Tranche 3 (W2-13 to W2-18): task level, with fixes applied

- **Contaminated history (E11).** The same rule as W2-11: runs before #8610 merged are excluded from the p90 caps, or tagged `contaminated` and excluded. E7's attribution of the 288 runs is [U] for this purpose.

### W2-13: eval corpus and paired ratchet rule

- **Corpus.** 24 cases from this repository's merged PRs, human-labelled. Sixteen are holdout and eight are dev, stratified across tiers. Count by tier: trivial, small, medium, large, and negative cases where the right outcome is escalation.
- **Honest scope.** At n=24 this is a **regression tripwire**, not a measurement of superiority. Grow the corpus to at least 50 cases before any fitter (W2-19) is considered.
- **Paired design.** Incumbent and candidate run on the same cases, in the same time window, with the same CLI and SDK version. Three runs per case. The statistic is pass^3.
- **Non-inferiority (default).** Losses minus wins is at most 0, and losses are at most 1. A loss is a case where the candidate's pass^3 is below the incumbent's; a win is the reverse.
- **Superiority, only through a sign test.** Exact one-sided sign test at p ≤ 0.05, on the discordant pairs. Minimum wins for each number of discordant pairs `n`, computed from the binomial distribution with p = 0.5:

| Discordant pairs n | Minimum wins | Exact one-sided p |
|---|---|---|
| 1 to 4 | none reachable | superiority is impossible |
| 5 | 5 | 0.0312 |
| 6 | 6 | 0.0156 |
| 7 | 7 | 0.0078 |
| 8 | 7 | 0.0352 |
| 9 | 8 | 0.0195 |
| 10 | 9 | 0.0107 |
| 11 | 9 | 0.0327 |
| 12 | 10 | 0.0193 |
| 13 | 10 | 0.0461 |
| 14 | 11 | 0.0287 |
| 15 | 12 | 0.0176 |
| 16 | 12 | 0.0384 |
| 17 | 13 | 0.0245 |
| 18 | 13 | 0.0481 |
| 19 | 14 | 0.0318 |
| 20 | 15 | 0.0207 |

  These values were computed with `math.comb`. Discordant pairs of 4 or fewer can never reach significance, so with 24 cases superiority is hard to show, which is intended.
- **Cost.** The median paired cost ratio (candidate ÷ incumbent) is at most 0.9 for a cost-motivated change.
- **Accept rule.** Accept when non-inferiority holds **and** (superiority by the sign test **or** a median cost ratio of at most 0.9). **Hard vetoes**, which reject regardless of the statistics: any fence violation, any touch of a forbidden path, any oracle tampering.
- **Anti-gaming.** One PR may not change both `evals/` and the policy. The ratchet file is owned by CODEOWNERS.

### W2-14: trusted replay and advisory ratchet

- Replays run from `git archive <base.sha>` with no `.git` directory.
- Oracle tests are restored from the trusted copy before scoring.
- Memory injection, UCB1 and recruit are disabled in replay (`SW_LEGACY_MODEL_ROUTING` unset, and the memory switch off).
- The ratchet reads only an attested artifact from the trusted replay workflow, with the policy hash checked against the PR head.
- **Advisory first.** The ratchet reports but does not block until the fence (H2) is tested. H2 is deferred (W2-19), so the ratchet stays advisory until its own plan is accepted.

- **Oracle tests run through the test gate.** Every oracle test runs through `sw_test_gate_env` with `SHIPWRIGHT_E2E_REAL` unset (`scripts/lib/test-gate-env.sh`, from #8610). A real-service call during replay is a fence-violation veto (W2-13's hard vetoes).

### W2-15: verifier stage

- **There is no verify stage in the bash pipeline today.** W2-15 adds a real stage function, not a template flag.
- **Prerequisites.** A sandbox that gives the verifier a read-only mount, and no GitHub token. Credentials reach the verifier only as the model credential it needs.
- **Behaviour.** The verifier runs the oracle tests itself and does not trust the builder's report. A `gap` verdict returns the run to build, capped by the fix-loop limit (three).
- **Structured output.** Schema-validated verdicts. No forced `tool_choice`, which Opus 5.5 and Sonnet 5.5 reject with a 400.

- **The verifier runs its checks through the same gate.** Its test runs use `sw_test_gate_env`, so it cannot file issues, switch branches or delete state. A verifier that makes a real-service call is treated as a fence violation.

### W2-16: retire legacy learners

Retire, with a "removed" stub that names the replacement and an alias, following spec §7.5:
- `sw-recruit`, `policy-learner`, `bandit-selector`, `reward-aggregator` and `process-reward` (all live today);
- the UCB1 path and the `$RANDOM` A/B, which W2-07 has switched off;
- `sw-stall-detector.sh`, after W2-05 and W2-06;
- the file heartbeat (`sw-heartbeat.sh`) as a liveness signal, after W2-06;
- `auto_template` (`daemon-poll.sh:315`), replaced by difficulty tiers (W2-11);
- `sw-predictive`, `sw-intelligence`, `sw-adaptive` and `scripts/lib/adaptive-model.sh`.

Memory injection and the outcome-feedback learned rules are **ablated, not retired**, in the eval (W2-14). Confirm where `outcome-feedback.sh` output is read before deciding (Q10, part of G6).

### W2-17: holdout MVP

- Holdout scenarios are kept in a private store, fetched only by eval and verifier jobs, and never placed in this repository.
- Scenarios are mined from repository history (merged PRs with linked issues and tests), drafted by an LLM and approved by the maintainer by PR into `sethdford/shipwright-holdout` (Q13, decided).
- Score: the fraction of each issue's scenarios satisfied, averaged over the runs. This is reported next to pass^3 and is not a gate until the judge is calibrated against human labels.
- `scripts/lib/test-holdout.sh` already exists. Reuse it or retire it here; the decision is made when W2-17 starts.

### W2-18: scorecard

- Metrics: merged without substantial rework (no human commits to the agent branch and no revert or reopen within 14 days); escaped defects; reverts; cost per merged PR; time to merge.
- Source: the ledger (W2-08) plus GitHub state. The spec §8 scorecard is the same set of measures.
- The dashboard view belongs to Wave 3 (observability). W2-18 writes the metrics.

---

## Deferred (W2-19): each needs its own plan

| Item | Why deferred | What its plan must settle |
|---|---|---|
| E5 fitter (proposes routing values from ledger statistics) | needs at least 50 cases and a live ratchet; the spec places it in Wave 4 | the fitter's inputs, its caps, and the ratchet it must pass |
| Full H2 fence | needs real-machine tests on macOS and a container test on CI | the scope: **eval replays and the verifier only**; protected-path diffs route to a human tier; the holdout is in a private store |
| H4 GitHub twin | a large, drift-prone surface; the `gh` surface is not yet enumerated | the enumerated surface, the contract suite, and its nightly run against real GitHub |
| I1 to I3 and I5 (merge tiers, review scaling, specifiability, review quality) | lights-on is the default; tiers need about 30 days of metrics first | tier thresholds backtested on the ledger; review-catch measurement |
| J self-improving harness | optional; ModularRSI shows gains on its benchmarks, not on this repository | the editable surface, the gate, the archive, and the human decision points |

---

## Verification on GitHub

Real GitHub runs create issues, labels and comments. Live checks move to `sethdford/shipwright-sandbox` once it is wired (W2-22, Q3 decided); deterministic replays use the GitHub twin (W2-21). Until then, end-to-end checks run on **this** repository, on an issue labelled `e2e-test`, as manual runs.

| Tranche | Check | Expected observable |
|---|---|---|
| 1 | W2-01 capture of run 38744601038 | Once the run completes: `completed`, and no credential-shaped strings in the capture |
| 1 | W2-03 | `actionlint` exit 0; `bun run arch` exit 0 |
| 1 | W2-06 manual run | A `SHIPWRIGHT-PROGRESS` marker appears in the issue's bot comment; the watchdog reports a time since last progress, not a heartbeat time |
| 1 | W2-20 arch ratchet | `bun run arch` exits 0; the baseline has one entry (`scripts/sw-integration-claude-test.sh`) |
| 2 | W2-09 manual run | A `ledger/<date>/<runId>.jsonl` file exists on `shipwright-data` after the run, and its last line is an `outcome` |
| 3 | W2-14 advisory replay | The ratchet report is attached to the PR and does not block it |

**What Tranche 1 does and does not fix.** It fixes the auth retry path, the silent stall, the untyped build model, and the missing wall-clock cap. It does not fix the breaker's dependence on GitHub history alone, which Wave 1b addresses. It also does not change the 288-run dispatch and sweep paths beyond what W2-03 and W2-06 touch (E7).

---

## Open questions

| # | Question | Status and default |
|---|---|---|
| Q1 | Spec amendments | **Resolved narrowly.** The only new item is the E5 timing, which stays in Wave 4 as the spec says, and E5 is now deferred. §2 needs no change for Tranches 1 to 3. |
| Q2 | Run Tranches 1 to 2 on SQLite (M1) before Postgres? | **Yes.** M2 and M3 share the ledger only once Postgres exists. |
| Q3 | Disposable sandbox repository | **Decided (2026-10-16): yes.** A dedicated private sandbox repo, `sethdford/shipwright-sandbox`, hosts live end-to-end and eval runs, so real runs never create issues, labels or PRs in this repository. Deterministic replays run offline against the GitHub digital twin (W2-19 H4, pulled forward as W2-21). Until the sandbox is wired (W2-22), checks run on this repo with an `e2e-test` issue. |
| Q4 | Eval spend cap | **Decided (2026-10-16): paired, budget-capped, change-triggered.** Policy-changing PRs (routing, models, templates, prompts, skills) get a paired incumbent-vs-candidate replay on a stratified subset; a full replay runs weekly. Hard caps: $25 per run, $100 per week, enforced at runtime by the W2-12 budget, never by model self-estimates. Sequential early stopping ends a run once the sign-test outcome is decided. Prompt caching on; grading with `claude-haiku-5-5`. No fixed nightly schedule. |
| Q5 | Incident logs as fixtures | **Read-only fetch, as approved.** Run 38744601038 is still in progress; W2-01 Step 1 captures it after it completes. |
| Q6 | CI cost source | **Verify on the first sandbox run; zod; fail closed.** The usage fields are not assumed. |
| Q7 | Triage model | **Yes, through `config/models.json` in W2-07.** |
| Q8 | Which mechanism sets the build model | **Answered.** UCB1, the `$RANDOM` A/B and recruit set the build model, not the template. W2-07 switches them off, so the template's model applies. The retry escalation in `daemon-failure.sh` sets opus on retry 1 and is separate. |
| Q9 | Refusal fallbacks in the runner | **Out of scope.** |
| Q10 | Where `outcome-feedback.sh` output is read | **Part of W2-16 (G6).** |
| Q11 | The review-benchmark citation | **Resolved.** CRBugBench is confirmed, with the two corrections in E2. |
| Q12 | Full H2 fence | **Deferred (W2-19).** |
| Q13 | Who writes holdout scenarios | **Decided (2026-10-16): mined from history, LLM-drafted, maintainer-approved.** Cases come from merged PRs with linked issues and tests (SWE-bench / CRBugBench-style mining); an LLM drafts each case's acceptance scenarios; the maintainer approves them by PR into a separate private repo, `sethdford/shipwright-holdout`, readable only by the eval and verifier jobs through a dedicated read-only token. Agents cannot read it: they have no GitHub credentials (#8624), and this repo's `GITHUB_TOKEN` cannot read another private repo. W2-17 is unblocked. |
| Q14 | GitHub twin | **Deferred (W2-19).** |
| Q15 | #8610 (the test gate) | **Blocking for W2-06 and W2-20.** #8610 is open. The maintainer merges it; no part of this plan changes its code. |
| Q16 | Who creates the W2-20 issue | **The maintainer**, as stated in the review. The key is W2-20. |
| D-M | Model alias conversion | **Decided (2026-10-16): Claude 5.5 everywhere.** Pinned IDs moved to `claude-opus-5-5` / `claude-sonnet-5-5` / `claude-haiku-5-5` in #8634; W2-07 finishes deterministic routing from one models file. |

---

## Out of scope

- Training any model. "Learning" here means fitting a small table to ledger statistics under a ratchet, and deterministic rules.
- Reinforcement learning, bandits in production, and online adaptation during a run.
- Fine-tuning.
- Automatic merging. A human merges (E2 and I-tiers in W2-19).
- Claims from the unverified sources in the Evidence table.
- The full port of `sw-loop.sh` and `daemon-failure.sh`, which belongs to the delivery and orchestration contexts.

---

## Self-review

Checked against the spec, the ADRs, AGENTS.md, the independent review, and the repository at `origin/main`.

1. **Structure.** Tranches 1 to 3 and the deferred list are separate; each item carries its key, W2-01 to W2-19. Tranche 1 has exact steps with commands and expected output. Tranches 2 and 3 are task level and say so.
2. **Verification of the code.** Every TypeScript file in Tranche 1 was executed in an isolated scratch copy against stubs of the real interfaces: 44 tests pass. The bash bridge and the daemon helper were executed against a fake Bun. The repository run for each task is listed as its verification step, and nothing has been run in the repository yet.
3. **Fitness rules.** Domain files import only their own domain and `src/shared/kernel` (F1). The application layer imports only ports and domain (F2). Command code reads files only through the `FileReader` port (F5). The CLI imports contexts only through their `index.ts` (F3). The bash changes are argv-only and add no `eval` (F11).
4. **Facts checked.** The router, the census, the pinned Bun SHA, the UCB1 and A/B lines, the recruit guard, the `EFFORT_LEVEL` validation, the auto-retry and watchdog steps, the dispatch guard text, and the pre-flight comment were all read from the repository. The incident run and CRBugBench were checked with `gh` and a fetch.
5. **Corrections to the review.** See the note below.
6. **Known gaps, stated plainly:** the sweep path is covered by W2-06 and W2-09, not by W2-03; the `timeout` cap may leave model child processes running; `movedTests` uses a single `suite` name on the bash side, which is coarse; the classifier's first-attempt rules are not exhaustive; and the 288-run attribution is a source check (E7), not a reconstruction of each re-run.

**Where I disagree with the review, or where the review needed a correction:**
1. **CRBugBench is not "injected bugs".** The paper says "human-verified bugs mined from repository history". The 71.9% and 47.7% figures may not share a harness. The plan cites both corrections (E2). Lights-on remains the default, because the paper reports weaker results on complex changes and proprietary repositories, not because of a single number.
2. **Tranche 1 does not "unblock dispatch" on its own.** It removes the known causes of the incident record, but the breaker reads GitHub history only until Wave 1b. The plan says so under "Dispatch at scale".
3. **The auth-comment mechanism (E7).** The review says dispatch and sweep caused the 288 re-runs, which I confirmed from source. The dispatch guard does match "Pipeline Auth Failure", so the mechanism is the comment's `|| true` write plus sweep's timestamp logic. I did not reconstruct each re-run, so that part stays [V] by source check only.
4. **AGENTS.md is unchanged.** Tranche 1 needs no line in it. When Tranche 2 lands, one existing line will be replaced rather than a line added.
5. **The model-alias conversion (D-M) is a real behaviour change**, not only a hygiene fix, because `claude-opus-5` becomes `claude-opus-5-5`. The plan makes that visible rather than assuming it.

The plan and ADR-0009 are the only changes in this commit.
