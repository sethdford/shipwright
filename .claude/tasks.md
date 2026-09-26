# Tasks — Add pre-build validation checks to catch broken environments before the build loop starts

## Status: In Progress
Pipeline: standard | Branch: ci/add-pre-build-validation-checks-to-catch-6428

## Checklist
- [ ] Task 1: Create `scripts/lib/loop-prebuild.sh` with source guard, defaults and output-helper fallbacks
- [ ] Task 2: Implement `_pbv_check_deps` (node/python/rust/go/ruby/java/dotnet; fatal vs. fixable)
- [ ] Task 3: Implement `_pbv_resolve_base_ref`, `_pbv_changed_files` (capped, `< <()` loops) and `_pbv_check_syntax`
- [ ] Task 4: Implement `_pbv_check_test_runner` and `_pbv_classify_runner_output` (timeout-bound; skip when there is no timeout binary)
- [ ] Task 5: Implement `pre_build_validate` orchestration, atomic `pre-build-validation.json`, and merged/atomic `error-summary.json`
- [ ] Task 6: Add config, CLI flags, help text and lib sourcing to `sw-loop.sh`
- [ ] Task 7: Add call sites in `run_single_agent_loop` and the multi-agent `main` path, with abort handling
- [ ] Task 8: Add the `pre_build_failed` short-circuit in `run_loop_with_restarts`
- [ ] Task 9: Add the pre-build prompt heading variant in `loop-iteration.sh` (normal path unchanged)
- [ ] Task 10: Add `environment_error` handling in `pipeline-stages-build.sh` and `daemon-failure.sh`
- [ ] Task 11: Register the new events in `config/event-schema.json`
- [ ] Task 12: Write `scripts/sw-lib-loop-prebuild-test.sh` (pass/fail/skip with mock layouts)
- [ ] Task 13: Add wiring tests to `sw-loop-test.sh` and a classification test to `sw-lib-daemon-failure-test.sh`
- [ ] Task 14: Document in `.claude/CLAUDE.md` (Build Loop Capabilities and Loop Configuration)
- [ ] Task 15: Run `npm test`, `shipwright docs check` and `shellcheck` on the new and changed files
- [ ] `pre_build_validate()` runs before the first build iteration (single-agent and multi-agent paths), and not on session restarts
- [ ] It can be skipped via `--no-pre-build-validate`, `LOOP_PRE_BUILD_VALIDATE=0` or `loop.pre_build_validate: false`; the timeout is configurable via `loop.pre_build_timeout`
- [ ] It detects missing or broken dependency installs, syntax errors in changed files (`.sh`, `.js`, `.json`, `.py`), and a test runner that fails to start
- [ ] On failure, it writes `error-summary.json` in the existing shape (additive fields only, atomic write), and iteration 1's prompt consumes it
- [ ] Fatal environment failures abort in seconds, do **not** trigger session restarts, are classified `environment_error` by the pipeline and daemon, and get at most 1 daemon retry

## Notes
- Generated from pipeline plan at 2026-09-26T00:24:45Z
- Pipeline will update status as tasks complete
