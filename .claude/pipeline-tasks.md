# Pipeline Tasks — Split sw-memory.sh into capture, query, and pattern-aggregation modules

## Implementation Checklist
- [ ] T1: Record the baseline (test counts, help output, function list, `declare -f` bodies)
- [ ] T2: Create `lib/memory-common.sh` (paths, repo identity, embedding store) with a guard
- [ ] T3: Create `lib/memory-capture.sh` (9 write functions) with a guard
- [ ] T4: Create `lib/memory-query.sh` (9 read/inject functions) with a guard
- [ ] T5: Create `lib/memory-aggregate.sh` (global rollup, finalize, DORA baseline, stats, A/B, decay) with a guard
- [ ] T6: Create `lib/memory-admin.sh` (show, search, forget, export, import) with a guard
- [ ] T7: Reduce `sw-memory.sh` to bootstrap + strict module loader + help + router
- [ ] T8: Mechanical equivalence check (function set and `declare -f` bodies identical)
- [ ] T9: Line-count (≤800) and Bash 3.2 grep, plus `bash -n` and shellcheck gates
- [ ] T10: Add `sw-lib-memory-modules-test.sh` and register it in `package.json`
- [ ] T11: Add the lib files to the `sw-upgrade.sh` manifest
- [ ] T12: ADR plus CLAUDE.md architecture note; run `shipwright docs sync`
- [ ] T13: `sw-memory-test.sh` passes **unmodified**; related suites pass; `npm test` green
- [ ] `sw-memory.sh` ≤ ~200 lines and contains only bootstrap, loader, help and router
- [ ] 5 `lib/memory-*.sh` modules, each ≤ 800 lines, each with a double-source guard
- [ ] Function set and bodies mechanically identical to the baseline
- [ ] `sw-memory-test.sh` passes with **zero** edits; the new module suite passes; `npm test` green
- [ ] `shipwright memory help` output is byte-identical to the baseline
- [ ] No `declare -A`, `readarray`, `mapfile`, `${,,}` or `${^^}` in the new files; `bash -n` is clean
- [ ] `sw-upgrade.sh` installs the new lib files; ADR written; docs synced

## Context
- Pipeline: standard
- Branch: refactor/split-sw-memory-sh-into-capture-query-an-7690
- Issue: #7690
- Generated: 2026-10-05T07:01:49Z
