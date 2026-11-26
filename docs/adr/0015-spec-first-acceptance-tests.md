# 0015. Spec-first acceptance tests: proven red, locked, and the build gate

Status: accepted · Date: 2026-11-26

## Context
The pipeline's "test first" stage (`stage_test_first`) was opt-in (`--tdd`), failed open (`|| true`), never ran the
tests it wrote, and wrote model-chosen paths without checking them (a `../` path escaped the repository). New test
files were rarely committed, because it looked for them with `git diff`, which does not list untracked files. The
build prompt asked the agent not to edit the tests, and nothing checked. The test stage ran the whole suite only, so
a build passed whenever the existing tests passed, whether or not the issue was done.

Research on agent correctness points the other way. SWE-bench grades a patch by fail-to-pass tests: tests that fail
before the change and pass after it. Reproduction-test-first agents (Otter, SWE-agent's reproduction step, TDD-Bench)
and test-driven code generation (TGen, "Tests as prompt") gain most when the tests are executable, fail for the right
reason before the change, and cannot be edited by the agent that is graded by them. Agents that may edit the tests
learn to weaken them.

## Decision
Every pipeline run turns the issue into executable acceptance tests before implementation, unless the mode is off.

1. **Contract.** A test writer (one agent call, text only) answers with `acceptance.json`, holding numbered criteria
   (AC-1...) and new test files, and with one fenced block per file. Every criterion needs a test; every test names its
   criteria in its own source. `shipwright acceptance materialize` writes the answer all or nothing: only new files,
   only test-shaped paths inside the repository (not `.git`, `.github`, `.claude`). A writer that edits the repository
   with its tools has its changes undone and its answer rejected.
2. **Red for the right reason.** `verify-red` runs each file alone, without credentials (`test-gate-exec.sh`). It must
   fail on an assertion or on the missing feature (missing module, export, symbol), and the output must name the file
   or a criterion. Passing, no tests, timeouts, syntax errors in the test, missing frameworks and unexplained failures
   are rejected with the reason and the output tail, and the writer retries (3 attempts).
3. **Lock.** The files are committed alone, and `lock` records that commit and each blob id. Git objects cannot change.
   The lock the gate reads lives in the state dir (outside the `./**` the build agent may write); the artifacts
   hold a copy for people. A resumed run reuses a lock whose commit is in the branch's history.
4. **Gate.** The test stage first runs `verify-green`: it checks the diff since the lock (edited acceptance tests,
   deleted tests, added skip/only/todo markers, fewer assertions, narrowed test collection block; other test-config
   edits warn), restores each locked file byte for byte, and requires every one to pass. Then the full suite runs.
   A failure goes into the self-healing retry, which tells the builder to change the code, not the tests.
5. **Per-file command.** A configured argv (`acceptance.command`, with `{file}`, `{dir}` or `{stem}`), else one derived
   from the project's test command (bun, vitest, jest, pytest, go, cargo, npm, ...), else the writer's proposal if it
   names a known runner. Never a shell string.
6. **Modes.** `SW_ACCEPTANCE` or `acceptance.mode`: `enforce` (default; no proven-red tests stops the run before the
   build), `warn` (report only), `off` (ablation for the ADR-0009 ratchet). `not_testable` with a reason is allowed for
   changes with no observable behavior; it is recorded in the artifacts. No test command: skipped with a warning.

Decisions live in a new `planning` context (`src/contexts/planning`); `scripts/lib/acceptance-tests.sh` only
orchestrates.

## Consequences
- A pipeline PR now carries tests that failed before its change and pass after it: a fail-to-pass signal per issue,
  which the scorecard and the tournament judge (#8744) can use, and which a reviewer can read as the spec.
- Runs cost one more agent call (more on retries), and issues the writer cannot test stop in enforce mode instead of
  producing an unverified PR. The default should be checked with a paired eval run (`SW_ACCEPTANCE=off` vs enforce).
- The red check is pattern based. Runner output it does not know reads as "unexplained" and fails closed; add the
  pattern to `run-verdict.ts` with a test.
- Not covered yet: the issue text is not wrapped as untrusted input (#8738), and a builder can still add tests that
  pass trivially beside the locked ones (the locked ones still have to pass).
