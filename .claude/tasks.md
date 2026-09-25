# Tasks — Adaptive circuit breaker threshold based on failure signature similarity

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-6176

## Checklist
- [ ] Circuit breaker threshold increases when consecutive failures share identical error signature
- [ ] Circuit breaker threshold decreases when failures have different signatures  
- [ ] Threshold respects hard bounds: min=2, max=8
- [ ] Feature can be disabled via config flag (default: false during rollout)
- [ ] Feature works offline (no external API calls)
- [ ] Backward compatible: existing loops unaffected when feature disabled
- [ ] `sw-circuit-breaker.sh` follows Shipwright conventions (set -euo pipefail, VERSION, event logging)
- [ ] All functions documented with comment block (inputs, outputs, side effects)
- [ ] Error handling for all edge cases (missing files, malformed JSON, empty signature data)
- [ ] No hardcoded paths (all use config vars from daemon-config.json)
- [ ] Unit test suite: 20+ tests covering signature extraction, similarity matching, threshold calculation
- [ ] Integration test: loop with adaptive enabled processes similar failures correctly
- [ ] Integration test: loop with adaptive enabled processes diverse failures correctly
- [ ] Backward compat test: loop with adaptive disabled behaves identically to current version
- [ ] All existing loop tests pass (no regressions)
- [ ] Test suite registered in package.json and runs via `npm test`
- [ ] CLAUDE.md updated with algorithm explanation and config examples
- [ ] Code comments explain scoring heuristics and edge cases
- [ ] Error messages are actionable (e.g., "adaptive circuit breaker: signature extraction failed, falling back to default")
- [ ] README or CHANGELOG mention new feature

## Notes
- Generated from pipeline plan at 2026-09-25T10:42:31Z
- Pipeline will update status as tasks complete
