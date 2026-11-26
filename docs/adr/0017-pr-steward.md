# 0017. A PR steward fixes failing CI and answers review comments after the PR opens

Status: accepted
Date: 2026-11-26

## Context

The pipeline's job ended when `gh pr create` returned. Whatever happened next (a red CI job, a review
comment from the Claude review bot or the owner) waited for a person, and pipeline PRs authored as
the owner get no reviewer, so they sat. Two of the last ten pipeline PRs merged. The `merge` stage
only waited for CI and gave up on the first failure.

The tools that close this gap work the same way: after the PR opens, read the failing job's log or
the reviewer's comment, make a bounded fix, push, reply, repeat (Copilot coding agent, Cursor Bugbot
Autofix, which moved its resolution rate from 52% to 76%, Codex, Devin). Copilot also reviews and
scans its own change before it opens the PR. The existing `review-remediation.yml` workflow tried the
review half, but its agent edits the checkout that is then pushed with `git add -A`, outside the
patch handoff (ADR-0011), and it ignores CI.

## Decision

A new pipeline stage, `steward`, runs between `pr` and `merge` in every template. Decisions live in
TypeScript (`shipwright steward`, delivery context); the bash stage only drives rounds.

1. **Inspect.** `steward inspect` reads the PR's check runs, the logs of failed Actions jobs, and its
   inline comments, review bodies and conversation comments, then picks one action from a pure state
   machine (`domain/steward-policy.ts`): `fix`, `rerun`, `wait`, `done` or `stop`.
2. **Triage CI.** A failed check is `code` (fix it), `infra` (runner, network, rate limit, missing
   secret, timeout: re-run the job once, never "fix" code for it) or `baseline` (it also fails on
   the PR's base commit: not this change's fault, and it does not hold up `done`).
3. **Triage comments.** Only authors with write access (association OWNER, MEMBER or COLLABORATOR,
   confirmed by the collaborator permission API as admin, maintain or write) and allowlisted review bots (`SHIPWRIGHT_STEWARD_BOTS`, default claude, Copilot, CodeRabbit, Cursor and Codex
   bots) can steer a fix round; anyone else is ignored. Outdated inline comments, approvals and
   "no issues found" are skipped. The steward's replies carry a marker; a marker counts only when
   posted by the steward's own login, so a forged one cannot hide a comment.
4. **Fix through the patch handoff.** A fix round is the build loop in a disposable clone with no
   credentials (ADR-0011). CI excerpts and comments reach the model as wrapped untrusted data. Only
   a judged patch comes back; protected paths, binaries and budget overruns are refused and stop the
   stage. The fixer must not skip or weaken tests or edit CI configuration.
5. **Push and reply through the F10 writer.** `steward push` fast-forwards the PR branch (never a
   force push, hooks off), and only after re-checking that the PR is open, not from a fork, still at
   the head the round started from, and that the round's own change passes the scan below (a secret
   or a focused test written by the fixer is never pushed). `steward reply` posts one reply per inline thread and one PR comment for
   the rest, rebuilt from the fixer's report: known comment ids only, a fixed status vocabulary, a
   short note with HTML, images, hidden characters and @-mentions neutralized. Every write takes an
   idempotency key and reconciles first, so a retried round never posts or pushes twice.
6. **Bounds.** At most `max_rounds` fix rounds (default 3); a failure signature targeted twice
   without change stops the stage; a comment offered twice without a report is dropped; the stage
   waits at most `wait_timeout_s` (default 3600) for checks. A commit with no checks reported yet is
   `wait`, never `done`, until `no_checks_grace_s` (default 600) has passed: then the PR is taken to
   have no CI. Numeric settings are validated and clamped, since a template can be
   repository content. `stop` and timeout fail the stage, so
   `merge` never runs on a red PR and the PR stays open for a person.
7. **Pre-PR self-scan.** Before `stage_pr` pushes, `steward scan` checks the lines the branch adds:
   a secret (private keys, AWS, GitHub, Anthropic, OpenAI, Slack, Stripe, Google keys) blocks the
   push outright; conflict markers, focused tests (`.only`) and debugger statements get one fix
   round through the handoff and block if they survive it; skipped tests and `console.log` are
   notes. There is no in-line opt-out. The scan fails closed: if it cannot run, the push stops.

`SHIPWRIGHT_STEWARD=off` skips the stage; `SHIPWRIGHT_STEWARD_SCAN=off` skips the scan.

## Consequences

- PRs get green before a person looks at them, and the owner's or a bot's review comment gets an
  answer within the round instead of waiting for the next pipeline run.
- A fix round spends model time like a short build (default 6 loop iterations).
- The steward acts only while its pipeline run is alive (up to `wait_timeout_s`). A human review
  that arrives hours later is not handled yet; the next step is a daemon or workflow entry point
  that re-enters `stage_steward` for an existing PR. When that lands, `review-remediation.yml`
  should call it instead of pushing its agent's checkout.
- In GitHub Actions a push made with `GITHUB_TOKEN` does not trigger new workflow runs, so in the CI
  pipeline the steward sees CI only for PRs whose pushes use an app or personal token. Runs on the
  owner's machine (the usual case) are unaffected.
- Known limits, accepted for now: if someone pushes to the branch during a round, the push is
  refused and the stage fails rather than rebasing; a baseline failure is matched by check name
  only; conversation comments from allowlisted bots are trusted; a comment edited after the steward
  answered it is not handled again; PRs from forks are never touched.
- Interfaces for parallel work: other signals (a learned critic, app run proof, environment reuse)
  plug in as more `CheckFailure` sources or more brief items; the state machine and the trust
  rules do not change.
