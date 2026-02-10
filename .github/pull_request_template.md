## Summary

<!-- Briefly explain what this PR does and why -->

## Changes

<!-- List the key changes made in this PR -->

-
-
-

## Test Plan

- [ ] All existing tests pass (`npm test`)
- [ ] New tests added for new functionality
- [ ] Manual verification performed

<!-- Describe any manual testing or edge cases you verified -->

## Shipwright Standards Checklist

- [ ] Bash 3.2 compatible (no `declare -A`, `readarray`, `${var,,}`, `${var^^}`)
- [ ] Uses `jq --arg` for JSON construction (no string interpolation)
- [ ] Atomic file writes (tmp file + `mv`, not direct `echo > file`)
- [ ] Error handling with `set -euo pipefail` and `ERR` trap
- [ ] `VERSION` variable at top of new scripts
- [ ] Output uses `info()`, `success()`, `warn()`, `error()` helpers
- [ ] Event logging with `emit_event()` if applicable
- [ ] No hardcoded credentials or secrets

## Related Issues

<!-- Link any related issues: Closes #123, Related to #456 -->

Closes #

## Additional Context

<!-- Add any other context that reviewers should know about -->
