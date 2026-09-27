# Tasks — `shipwright doctor --fix` Auto-Remediation for Common Setup Failures

## Status: In Progress
Pipeline: autonomous | Branch: feat/-shipwright-doctor-fix-auto-remediation-3153

## Checklist
- [ ] T1: Fix-tracking primitives and `--help` (step 1). *Blocks T3–T7.*
- [ ] T2: Convert the existing `doctor_fix_*` helpers from echo to exit codes (step 2). *Depends on T1.*
- [ ] T3: `doctor_fix_path` and `_doctor_check_path`, including fish and backup handling (step 3). *Depends on T1.*
- [ ] T4: `doctor_fix_hooks_exec` and the repaired `doctor_fix_hooks` (steps 4–5). *Depends on T1.*
- [ ] T5: Wire fix-and-recheck into the overlay, hooks, PATH, subcommands and scaffold checks (step 6). *Depends on T2–T4.*
- [ ] T6: `doctor_not_fixable` on the dependency checks (step 7). *Depends on T1.*
- [ ] T7: Replace the stub re-run with the real summary (step 8). *Depends on T5–T6.*
- [ ] T8: Tests T-a through T-g (step 9). *Depends on T5–T7.*
- [ ] T9: Strengthen existing Test 25, which currently passes on any output containing "fixed". *Depends on T7.*
- [ ] T10: shellcheck, `bash -n`, and a Bash 3.2 lint (no `declare -A`, no `${x,,}`, no `readarray`).
- [ ] T11: Run the full `npm test` and update docs if they mention doctor flags.
- [ ] `shipwright doctor --fix` re-checks each fixable failing check right after fixing it, and the summary counts reflect the post-fix state (T-a, T-c, T-g).
- [ ] Missing tmux, jq, claude, node and git are left as diagnostics with their existing guidance, and are listed as "not auto-fixable" (T-d).
- [ ] Every file change made under `--fix` is printed as `changed: <action> <path>`. Only `.claude/`, `~/.shipwright`, `~/.claude/hooks`, `~/.tmux*`, the shell rc file and Shipwright's install dir are ever written. Backups are made before any rc or tmux.conf edit.
- [ ] `--fix-dry` changes nothing (T-e).
- [ ] Output of plain `doctor` without `--fix` is unchanged. `sw-doctor-test.sh`, `sw-init-test.sh` and `sw-setup-test.sh` pass.
- [ ] shellcheck is clean, the code is Bash 3.2 compatible, and `VERSION` is unchanged.

## Notes
- Generated from pipeline plan at 2026-09-27T03:47:07Z
- Pipeline will update status as tasks complete
