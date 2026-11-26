# 0012. Head-to-head benchmark: Shipwright against bare Claude Code on hidden tests

Status: proposed (stacked on PR #8735) · Date: 2026-11-26

## Context
Shipwright claims that a pipeline around Claude Code (plan, build loop, tests, review, and since
PR #8744 a tournament of parallel attempts) ships better changes than Claude Code alone. Nothing
measures that claim. The scorecard (#8735) measures delivery on our own PRs, which has no control
group: we cannot tell what bare Claude Code would have done with the same issue. Published agent
results (SWE-bench and similar) are the yardstick readers trust, and they compare agents on the same
tasks, graded by tests the agent never saw.

## Decision
Add `shipwright bench`, a harness in the `quality` context that runs several **arms** on the same
**tasks** and grades every run with **hidden tests**.

- **Arms.** `claude-code` is `claude -p` with the same model, the same permission policy
  (`config/agent-permissions.json`) and the same time limit Shipwright's agents get. `shipwright`
  is the local headless pipeline (`pipeline start --local --headless`), with `attempts` parallel
  tries (tournament mode when above 1). `command` runs any other agent CLI from an argv template.
  Arms take `SHIPWRIGHT_*`/`PIPELINE_*` environment variables, so lesson and governance ablations
  (ADR-0010) are arms too. No arm gets a GitHub token.
- **Tasks.** Two suites. *SWE-bench Verified*: a seeded, reproducible sample drawn from the
  official export (`bench sample-swebench`), graded by the official Docker harness
  (`export-swebench`, then `import-swebench`), so our numbers are comparable with published ones.
  *Holdout*: mined from this repository's merged PRs that close an issue (`bench mine-holdout`),
  SWE-bench style: the issue is the problem, the merge commit's parent is the base, the PR's test
  changes are the hidden oracle, and the merge commit is the gold fix. `bench validate` keeps only
  tasks whose oracle fails on base and passes on gold. The holdout manifest stays out of the
  repository (it would leak the oracle into future agents' context); its name and task count are
  published with the results.
- **Grading.** Before the hidden test patch is applied, every file it touches is reset to the base
  commit, so an agent cannot pass by editing the oracle. Every test command must exit 0 in time.
  Errors and timeouts count as unresolved. An empty patch is unresolved.
- **Metrics.** Resolve rate with a 95% Wilson interval; pass^k (#8735) over trials; reported
  spend, and $ per resolved task only when every run reported spend; median wall time; an exact
  two-sided sign test of each arm against the baseline on per-task results.
- **Cost control.** `bench run` requires `--budget` and stops before any run the budget cannot
  cover (the rule from #8734: spent < cap and spent + estimate <= cap; unknown spend counts at the
  arm's estimate). The log is append-only and the run is resumable, interleaved by task so a
  stopped run stays paired. `bench plan` prints the run count and estimate before any spend.
- **Ratchet.** `bench export-eval` writes one arm in the `eval` results format, so
  `eval ratchet` (W2-13) can judge a candidate arm against an incumbent on the same cases.

## Consequences
- Shipwright's spend is read from the cost ledger for the run's time window, so benchmark runs are
  sequential and the daemon must be stopped while they run. Concurrency is a later change that
  needs per-run cost attribution (the pipeline id from #8740).
- SWE-bench tasks run on the host checkout without the instance's Python environment, for every
  arm alike; agents cannot run the project's tests there. This is a fair comparison, but absolute
  numbers will be lower than harnesses that run agents inside the evaluation image.
- Holdout tasks come from a public repository whose issues may be in a model's training data. Each
  task records the issue's `createdAt`; publish results only for tasks filed after the model's
  training cutoff, and say so on the page.
- Live runs need model credentials; they run on a maintainer machine, not in CI.
