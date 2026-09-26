# Pipeline Tasks — Add pre-build validation checks to catch broken environments before the build loop starts

## Implementation Checklist
- [ ] **Validation Script Created**: `scripts/sw-pre-build-validate.sh` exists, runs 7+ checks, outputs valid JSON
- [ ] **Helper Library Created**: `scripts/lib/pre-build.sh` with reusable check functions tested in isolation
- [ ] **Loop Integration**: `scripts/sw-loop.sh` calls validation before iteration 1; abort on fatal, inject warnings into context
- [ ] **Event Logging**: Pre-build events registered in `config/event-schema.json` and emitted by validation script
- [ ] **Context Injection**: Validation results merged into `progress.md` and `error-summary.json`; iteration 1 receives structured feedback
- [ ] **Auto-Fix Support**: npm install auto-triggered on missing dependencies (if configured)
- [ ] **Test Coverage**: 15+ tests covering happy path, all failure modes, timeouts, race conditions
- [ ] **Configuration**: `daemon-config.json` template documents all pre-build options
- [ ] **Documentation**: `.claude/CLAUDE.md` has "Pre-Build Validation" section with examples and troubleshooting
- [ ] **No Regressions**: Existing loop tests still pass; pre-build validates on enabled but doesn't break disabled
- [ ] **Performance**: Validation completes in <15s on typical projects
- [ ] **Bash 3.2 Compliance**: All scripts use bash 3.2 compatible syntax (tested with `bash --version 3.2`)
- [ ] **Safety Checks**: Re-validation logic in place to catch environment changes between validation and iteration 1 start

## Context
- Pipeline: autonomous
- Branch: ci/issue-6428
- Issue: none
- Generated: 2026-09-26T12:11:01Z
