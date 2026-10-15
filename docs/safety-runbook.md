# Safety runbook

Operating the Wave 1a safety controls: kill switch, breaker, budget, intake and the gated workflows.
Why they exist and how they compose: [ADR-0007](adr/0007-safety-controls.md). Dashboard and fleet
token setup: [dashboard-exposure.md](dashboard-exposure.md).

Every gate fails closed. If a source cannot be read (GitHub down, a bad token, a malformed cost file,
no Bun), nothing is dispatched, retried or filed. Fix the source; do not bypass the gate.

## Stop everything

| Scope | Stop | Lift |
|---|---|---|
| Every machine and CI | Add the `shipwright:pause` label to any open issue | Remove it from every open issue |
| This machine's daemon | `shipwright pause [reason]` (writes `~/.shipwright/daemon-pause.flag`) | `shipwright resume` |

Check: `shipwright paused` (exit 0 = paused, or unknown) for humans; scripts use
`shipwright paused --gate` (exit 0 = safe to dispatch). Create the label once if it is missing:
`gh label create shipwright:pause --color 000000 --description "Stops all Shipwright dispatch (ADR-0007)"`.

Labelling an issue `shipwright` runs the gates first: `shipwright-label-dispatch.yml` checks pause,
breaker, budget, review WIP and the fix loop, with the retry count from the bot's `SHIPWRIGHT-RETRY`
markers, before it posts the dispatch marker and starts the pipeline. A closed gate ends that run with a
notice, not a failure, so the pause label stops it too. Its runs are not in the breaker's history, so a
refused label never moves the breaker. Manual `workflow_dispatch` of `shipwright-pipeline.yml` is an
operator action and is **not** gated (see Re-run an issue manually).

## Read the gates

All read-only except `breaker check` and `gates check`, which open or update the
`shipwright:incident` issue when the breaker is open. Never run those two against the real repo
just to look.

- `shipwright breaker status [--json]`: `closed`, `open` (with when it opened and when the probe is
  allowed) or `half_open`. Opens at 5 failures in the last 8 finished pipeline runs; after 30 minutes
  the next run is the probe, and its result closes or re-opens it. A history with too few countable
  runs is reported as an error (indeterminate) and blocks.
- `shipwright budget status`: today's UTC spend against the cap. Set a cap with
  `shipwright cost budget set <usd>`. On CI runners there are no cost files, so the budget is not
  enforced there.
- `shipwright intake check --title "<title>" [--label <label>]`: whether automation may file an issue.
- `shipwright gates check --retry 0 --no-github`: the local view (pause flag, budget, fix loop); it
  skips the breaker, review WIP and the label. Refused on GitHub Actions.

To lift an open breaker, fix the cause (see the 2026-10-14 token failure in ADR-0007), then let one
run through: the first run created after the cool-down is the probe.

## Why an issue is not dispatched

- **Held labels.** Dispatch and auto-retry skip `auto-patrol`, `shipwright-stuck`,
  `shipwright-failed`, `shipwright-infra-issue` and `claimed:*`; the daemon skips `auto-patrol` and
  `shipwright-stuck`. A human opts an auto-filed issue in by removing `auto-patrol`.
- **Already handled.** `shipwright-dispatch.yml` dispatches an issue once. An issue with a bot
  comment containing `SHIPWRIGHT-DISPATCHED`, `SHIPWRIGHT-RETRY`, `Shipwright Pipeline` or
  `Pipeline Auth Failure` is never dispatched again automatically; retries belong to
  `shipwright-auto-retry.yml` (at most 3, from the highest bot `SHIPWRIGHT-RETRY` marker).
- **Daemon final failure.** A failed issue loses the watch label and gets `pipeline/failed`. If the
  watch label could not be removed, `.final_failed` in the daemon state holds it until a human
  removes the labels it was marked with.
- **A closed gate.** The dispatch and auto-retry logs show one line per gate; the daemon logs
  `Safety gates closed (rc=N)`.

## Re-run an issue manually

1. Check the gates by hand: `shipwright paused` and `shipwright breaker status`. A manual run bypasses
   them.
2. Remove any held label you want to override.
3. `gh workflow run shipwright-pipeline.yml -f issue_number=N` (add `-f template=full` if needed).

Do not delete old pipeline or retry comments to make dispatch pick an issue up again: that also
resets its retry count. For a daemon host, re-add the watch label (`shipwright`) after removing the failure labels.

## Re-enable the workflows (maintainer only)

`shipwright-dispatch.yml`, `-watchdog.yml` and `-auto-retry.yml` are disabled since the 2026-10-13
loop, `shipwright-sweep.yml` since 2026-10-14. In order:

1. Rotate `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) and confirm one manual pipeline run passes
   "Pre-flight auth check".
2. Merge the Wave 1a branch first. Until then keep `shipwright-sweep.yml` disabled: the old version
   re-dispatches failed issues. After the merge, confirm sweep and watchdog contain no
   `gh workflow run` outside comment text.
3. `shipwright breaker status`: closed, or open and cooling down after the failures.
4. Create the `shipwright:pause` label (above) so it is one click away.
5. Fleet hosts: set the same token on the dashboard and every worker, preferably as
   `SHIPWRIGHT_FLEET_TOKEN_FILE` (mode 600; workers warn otherwise), else `SHIPWRIGHT_FLEET_TOKEN`.
   Workers send it as `X-Shipwright-Token` on curl's stdin, never in argv; pipelines unset it so
   agents never see it. For CI's dashboard notifications, set the repository secrets
   `SHIPWRIGHT_FLEET_TOKEN` and `DASHBOARD_URL`. A claim the dashboard answers `401`/`403` fails
   (no GitHub-label fallback): check the token if the daemon logs "dashboard rejected the claim".
6. Clear `shipwright-stuck`, `shipwright-failed`, `shipwright-infra-issue` or stale `claimed:*`
   labels only on issues a human wants run again. Issues that already carry a dispatch, retry,
   pipeline or auth-failure comment are never dispatched again automatically; re-run them by hand
   (above).
7. Enable one at a time, checking each first scheduled run: `gh workflow enable` for
   `shipwright-watchdog.yml`, then `shipwright-sweep.yml`, `shipwright-auto-retry.yml`,
   `shipwright-dispatch.yml`.
8. In dispatch logs: the gate lines, at most 3 dispatches, a `SHIPWRIGHT-DISPATCHED` comment before
   each, no read failures. In auto-retry logs: the backoff before the gates, and skips that name
   `held`, `active`, `abandoned`, `exhausted` or `infra`.
9. Keep `shipwright:pause` ready. Labelling an issue `shipwright` passes the gates first (the label
   workflow above); a closed gate ends that run with a notice and nothing starts. Manual
   `workflow_dispatch` is an operator action and is not gated: check the gates by hand first.
