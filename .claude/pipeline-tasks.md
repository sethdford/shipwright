# Pipeline Tasks — Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings

## Implementation Checklist
- [x] 1. Signature and normalization functions in `lib/fleet-patterns.sh`
- [x] 2. Locked, atomic store read/write (record, update_fix, record_outcome, lookup, init/corruption recovery, caps)
- [x] 3. `fleet_triage_known_fix` with the demotion rule and artifact write
- [x] 4. `sw-memory.sh` capture hook plus `signature` field on failures
- [x] 5. `sw-memory.sh` analyze and outcome hooks (fix propagation)
- [x] 6. `memory_inject_context` renders `fleet-known-fix.json`
- [x] 7. `daemon-dispatch.sh` triage call and `sw-daemon.sh` sourcing
- [ ] 8. `sw-fleet.sh` env export plus the `patterns` subcommand and help
- [ ] 9. Unit, cross-repo and concurrency tests in `sw-lib-fleet-patterns-test.sh`, plus the `sw-fleet-test.sh` assertion
- [ ] 10. Event schema, docs and full `npm test` run
- [ ] With fleet mode on, a failure captured in any repo appears in `~/.shipwright/fleet-patterns.json` under its signature, and is still written to that repo's `failures.json`.
- [ ] Signatures follow `<error_type>:<hash>` and match across repos for the same failure even when paths and line numbers differ.
- [ ] `daemon_spawn_pipeline` surfaces a matching known fix (log line, `fleet.pattern_hit` event, `fleet-known-fix.json`) before the pipeline or loop starts, and build-stage memory injection includes it.
- [ ] The cross-repo unit test passes: learned in repoA, surfaced during triage of repoB.
- [ ] With fleet mode off, behaviour is the same as before (existing suites stay green).
- [ ] `shipwright fleet patterns list` and `lookup --text` work.
- [ ] Bash 3.2 safe, `set -euo pipefail` clean, writes are atomic and locked, and `npm test` is green.

## Context
- Pipeline: standard
- Branch: feat/share-failure-patterns-fleet-wide-so-dae-8328
- Issue: #8328
- Generated: 2026-10-10T18:24:31Z
