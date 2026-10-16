# 0007. Safety controls gate every dispatch

Status: accepted · Date: 2026-10-14

## Context
On 2026-10-13 every pipeline run failed (199 of 199 in 24 hours), retries re-dispatched the same
failures, and patrol had filed ~720 open issues. On 2026-10-14 the cause of a second wave was found:
an expired `CLAUDE_CODE_OAUTH_TOKEN` failed every run at the pre-flight auth check, and dispatch and
sweep re-dispatched those issues forever (288 failed runs that day). Per-issue retry caps did not
stop a global loop; the only kill switch was disabling the four workflows by hand. Spec §6.2
requires these controls before any delivery-loop port; the durability adapter (Wave 1b) is not built.

## Decision
The controls are pure policies in the `orchestration` context over ports. One composition,
`shipwright gates check --retry N [--no-github] [--json]`, evaluates **pause → breaker → budget →
review WIP → fix loop** and stops at the first closed gate. Every gate fails closed: exit 0 is the
only "go"; a block, an unreadable or indeterminate source, a usage error, a missing Bun or a signal
all stop dispatch. `--no-github` checks only the local flag, is refused on GitHub Actions, and has no
`NO_GITHUB` env bypass. Single gates: `paused --gate`, `breaker check`, `budget check`,
`intake check --label L`. Runbook: [safety-runbook.md](../safety-runbook.md).
- **Breaker:** folded on every check from the last 50 `shipwright-pipeline.yml` runs, so machines and
  CI agree without shared state. Opens at 5 failures (`failure`, `timed_out`, `startup_failure`) in
  the last 8 finished runs (`cancelled` not counted); after 30 minutes one probe run decides. A full
  history page with fewer than 8 countable runs is indeterminate and blocks. While open it keeps one
  `shipwright:incident` issue, written once per trip (F10's first method, `ensureIncident`, no fence).
- **Pause:** `~/.shipwright/daemon-pause.flag`, or `shipwright:pause` on any open issue (all
  machines and CI). **Budget:** daily UTC cap from `budget.json`/`costs.json`; blocks when spend
  plus the estimate reaches the cap.
- **Review WIP:** open, non-draft, unapproved agent PRs plus queued/running pipeline runs < 5.
  **Fix loop:** the first run plus 3 retries (`--retry 4` blocks). **Intake:** auto-filing only while
  < 25 issues carry the site's label and no open issue shares the title fingerprint.
- **Daemon:** gates once per poll cycle and per spawn; a refusal returns 75 and ends the cycle; a
  refused retry is a final failure (`.final_failed {ts, marked}` when the watch label stays).
  Selection skips `auto-patrol` and `shipwright-stuck`. Every auto-filing site goes through
  `patrol_issue_create` (intake); decompose files at most 8 subtasks.
- **Workflows:** dispatch and auto-retry call `.github/actions/safety-gates` (setup-bun pinned by SHA;
  the token reaches only the gate step). The labeled entry point is `shipwright-label-dispatch.yml`:
  it reads the retry count with `scripts/ci/retry-state.sh`, calls the same action with
  `on-refusal: notice` (a refusal is decided from `gates check --json`: allowed false, a blocked gate and
  no error gate), applies the first-dispatch rule through `scripts/ci/issue-dispatch-state.sh` (the same
  as dispatch), then dispatches through `.github/actions/dispatch-pipeline` (the same marker and dispatch
  as dispatch's loop). Held labels are skipped as in dispatch. The job runs in a per-issue concurrency
  group at job level, so unrelated labels never join it. Manual `workflow_dispatch` of the pipeline is an
  operator action and is not gated. The pipeline's `on:` is exactly `workflow_dispatch` (arch rule). Dispatch skips `auto-patrol`, `shipwright-stuck`,
  `shipwright-failed`, `shipwright-infra-issue` and `claimed:*`, posts a bot `SHIPWRIGHT-DISPATCHED`
  marker before `gh workflow run`, and never re-dispatches an issue with a bot dispatch, retry,
  pipeline or auth-failure comment. Auto-retry is the only retry path: count = highest bot
  `SHIPWRIGHT-RETRY` marker, at most 3, refused when only non-bot markers exist; one at a time;
  backoff, then gates. The watchdog cancels stuck runs and sweep labels them; neither dispatches.
  Markers come only from `github-actions[bot]` with type `Bot` (`scripts/ci/bot-comments.sh`, or
  `$SHIPWRIGHT_BOT_LOGIN`); it, `retry-state.sh` and `pipeline-active.sh` fail closed, and
  `tools/arch/workflow-fail-closed.ts` forbids swallowing their errors.
- **Dashboard and fleet:** exposure model, fleet token, Origin/Host/CORS allowlists, JSON-only writes,
  OAuth state, single-use join tokens: [dashboard-exposure.md](../dashboard-exposure.md).
  `fleet_curl` sends the token to curl on stdin, never in argv. Join and invite tokens are sent in
  headers only, never in URL paths: [join and invite tokens](../dashboard-exposure.md#join-and-invite-tokens).

## Consequences
- Dispatch, watchdog, auto-retry and sweep can be re-enabled behind one tested gate (runbook). Each
  check costs about five GitHub API calls; intake lists every open issue (~7 s).
- Local daemon outcomes do not feed the breaker until the run journal exists (Wave 1b).
- Accepted residual races (review round 3). Neither is closed by a lock, and both are bounded:
  - Label dispatch and scheduled dispatch use different concurrency groups (a per-issue label group and
    a single scheduled group). So a label and a scheduled scan can both see `ready` for one issue inside
    the run-listing lag, before either's DISPATCHED marker or pipeline run is visible. Bounds: the
    first-dispatch marker each one posts before dispatching, the pipeline start cap (6 starts per issue),
    and the per-run dispatch cap of 3 in the scheduled scan.
  - Labels on different issues while the breaker is half-open can each start a probe before any probe
    run is listed, because the per-issue groups do not serialise them. The number of extra probes is
    bounded only by how many labels arrive in that window, not by one. Bound: a failed probe re-opens the
    breaker and the cool-down applies again. Closing this needs a shared probe lock (a fence on the
    half-open state, Wave 1b's durability port), which is not built yet.
- The `issues: labeled` entry point is gated (Wave 1c, `shipwright-label-dispatch.yml`). A refusal is
  a `::notice::` and a successful run, not a failure, and the label workflow is not in the breaker's
  history (`GhRunHistory` lists `shipwright-pipeline.yml` only), so refused labels cannot re-open or
  trip the breaker or open an incident. Relabels after a run are refused with a notice, not dispatched. Manual `workflow_dispatch` stays ungated by design (operator
  action), bounded by the operator.
- Gaps (tracked in the Wave 1a plan's follow-ups): the budget is not enforced on CI (no cost data);
  org-mode `.final_failed` entries written before the `owner/repo:number` key keep the bare number and
  block that number in every repo until cleared. A title fingerprint misses paraphrased duplicates.
