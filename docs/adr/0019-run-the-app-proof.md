# 0019. Run-the-app proof in the PR, inside the trust boundary

Status: accepted
Date: 2026-11-26

## Context

Shipwright checks agent work in depth before a PR opens: tests, cross-tests, the rubric, the merge
verifier. None of that shows a reviewer the change working. Cursor's cloud agents and Factory's
Droids attach screenshots and video of the app running to their PRs, and reviewers trust a PR
they can see. A green test suite can also hide a page that crashes on load, a server that needs an
unset variable, or a CLI that no longer starts, because tests rarely boot the real app.

`scripts/sw-evidence.sh` already existed, but it curls URLs listed in Shipwright's own
`config/policy.json` (it always resolves the repository it ships in, not the target), takes no
screenshots and runs its CLI collector through `bash -c` from config strings. It is not a
proof of the change.

Starting the app means running agent-written code. The test gate already does that without
credentials (#8608, `test-gate-exec.sh`), and pages a browser loads can call out to anywhere.

## Decision

`shipwright proof run` (quality context) starts the app the branch changed, drives the changed
flows, and returns a "Proof it runs" section for the PR body. The bash PR stage calls it through
`scripts/lib/proof-gate.sh` right after the merge verifier.

- **What to run.** `.shipwright/proof.json` in the target repository wins field by field.
  Without it, detection proposes argv arrays from root files: a `dev`/`start` script (with the
  framework's port flag and the lockfile's runner), a `package.json` bin, a Cargo or Go main.
  Pages come from the changed files for file-system routers (Next.js, SvelteKit, Astro, Nuxt,
  Remix), always starting at `/`; dynamic routes are skipped. A CLI gets a `--help` run.
- **Flows are data.** proof.json steps are `goto`, `click`, `fill`, `press`, `waitFor`,
  `expectText`, `screenshot`, each mapped to one fixed Playwright call. Nothing is evaluated, so
  an agent may write proof.json for its own change without widening what the stage can do.
- **Trust boundary.** The app and every CLI run go through `test-gate-exec.sh`: no GitHub, git
  or Claude credentials, an empty gh and Claude config. The app gets its own process group; the
  whole group is killed afterwards, and also if Shipwright itself is stopped. Its port must be
  free before it starts, so a different server cannot answer for it. In the browser, requests
  and WebSockets to anything but the app's own origin and proof.json's `allowHosts` are aborted
  (other localhost ports included) and service workers are off. Logs and transcripts pass through
  `redact()` (tokens, keys, `*_PASSWORD=`, URL credentials) before they are written.
- **Artifacts cannot be swapped.** The app runs as the same user as Shipwright, so it could
  rewrite a screenshot with a secret file before the push. The run folder is a fresh `mkdtemp`
  outside the worktree; screenshots and videos reach it as bytes handed over by the driver, and
  every write records its sha256. Writes refuse symlinked folders. The publisher opens each file
  with `O_NOFOLLOW`, checks the digest, and copies it to a private staging folder; one mismatch
  stops the publish. Only the files the report names are published.
- **The agent cannot switch it off.** A proof.json that this change made invalid, or turned off,
  is a failure (it blocks in `enforce`); an invalid one is otherwise ignored and the app detected.
- **Verdict.** Fail: the app does not start, a step fails, a changed page answers 4xx/5xx or
  throws, a CLI run exits unexpectedly. Console errors are noted, not failed (dev servers are
  noisy). No browser available, or nothing detected, is `skipped`. `SHIPWRIGHT_PROOF` is
  `off`, `advisory` (default: never blocks, always reports) or `enforce` (blocks on fail). A proof
  that cannot run at all never blocks.
- **Publishing.** GitHub has no API to attach images to a PR body, so the artifacts are pushed to
  the repository's `shipwright-proof` branch and the section links them by commit
  (`github.com/<repo>/raw/<sha>/...`), which renders inline for anyone who can read the repo. The
  push (F10: a GitHub side effect) lives in `src/adapters/github/git-proof-branch.ts` behind the
  `ProofBranchWriter` port, keyed by an `IdempotencyKey` recorded in the commit message, so a
  retry reuses the commit. All git work happens in a throwaway bare repository that fetches only
  the proof branch tip: the user's clone is never fetched into (or made shallow), and its hooks,
  `.gitattributes` filters and config never run in the process that holds push credentials
  (only the origin URL and actions/checkout's auth header are read). Blobs are stored with
  `--no-filters`; hooks are off and the push uses `--no-verify`. Each commit holds only its own
  run's files and sits on the previous tip, so the tip stays small while old URLs keep working. `SHIPWRIGHT_PROOF_PUBLISH=off` or `NO_GITHUB`
  keeps everything local.

Playwright is an optional dependency, loaded at run time from Shipwright's or the global install.

## Consequences

- `SHIPWRIGHT_PROOF_TIMEOUT` (default 900 s) caps a whole run from the gate.
- Every pipeline PR for a web app or CLI shows it running: screenshots inline, a video and the
  server log one click away, or the server log's last lines when it did not start.
- A broken app is caught before review even when tests pass; in `enforce` it never becomes a PR.
- The `shipwright-proof` branch grows by one small commit per run. Pruning old runs is a
  follow-up (a scheduled job can squash the branch; old links then break, which is acceptable for
  merged PRs).
- Proofs for apps that need a database or secrets will fail to start in the sandbox. That is the
  honest answer; proof.json can point `start` at a seeded or mocked mode. Reusing an environment
  the agent built (`env init`, gap 5) is the planned fix.
- Not done here: a model judging the screenshots against the issue (a vision critic), and
  recording flows from the agent's own browser session. Both can build on the report this stage
  writes (`report.json` next to the artifacts).
