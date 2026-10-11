# Pipeline Tasks — Split sw-loop.sh into iteration-execution, convergence-detection, and session-management modules

## Implementation Checklist
- [ ] **T1** Baseline test counts, `--help` snapshot, function dump. *Blocks T5, T8.*
- [ ] **T2** Write the function-mover script. *Blocks T5.*
- [ ] **T3** Create `lib/loop-session.sh` with guard and `loop_session_init`. *Blocks T4, T5.*
- [ ] **T4** Extract `handle_verification_gap` (keep in `sw-loop.sh`) and replace the inline block and session-id block with calls. *Blocks T5.*
- [ ] **T5** Move functions into iteration, convergence and session modules. *Blocks T6.*
- [ ] **T6** Update source lines and add the fail-fast guard. *Blocks T7.*
- [ ] **T7** `bash -n`, shellcheck, Bash 3.2 lint. *Blocks T8.*
- [ ] **T8** Function-dump diff and `--help` diff. *Blocks T9.*
- [ ] **T9** Targeted suites, then `npm test`; confirm `git diff --exit-code main -- 'scripts/*-test.sh'`. *Blocks T10.*
- [ ] **T10** Hygiene ranking check and `wc -l` report.
- [ ] **T11** `shipwright docs sync` / `docs check` and the CLAUDE.md lib rows.
- [ ] `scripts/lib/loop-iteration.sh`, `loop-convergence.sh` and the new `loop-session.sh` hold the iteration, convergence and session logic per the map, and `sw-loop.sh` sources them
- [ ] `wc -l scripts/sw-loop.sh` ≤ ~1,200 and below `sw-memory.sh` (2,241); hygiene `script_sizes[0]` is not `sw-loop.sh`
- [ ] `git diff main -- 'scripts/*-test.sh'` is empty
- [ ] `sw-loop-test.sh`, `sw-convergence-test.sh`, `sw-heartbeat-test.sh`, `sw-recruit-test.sh`, `sw-agi-roadmap-test.sh`, `sw-autoresearch-e2e-test.sh`, `sw-session-restart-test.sh`, `sw-e2e-system-test.sh` pass with counts at least the baseline; `npm test` green
- [ ] `--help` output is byte-identical; the function-dump diff shows only the documented changes; each function is defined exactly once
- [ ] `bash -n`, shellcheck and the Bash 3.2 lint are clean on all changed files
- [ ] The fail-fast guard fires with a clear message when a required loop module is missing
- [ ] `shipwright docs check` exits 0

## Context
- Pipeline: standard
- Branch: refactor/split-sw-loop-sh-into-iteration-executio-8439
- Issue: #8439
- Generated: 2026-10-11T02:54:33Z
