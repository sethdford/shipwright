# Tasks — Fix hygiene scan false positives on the word "hardcoded" instead of numeric literals

## Status: In Progress
Pipeline: standard | Branch: fix/fix-hygiene-scan-false-positives-on-the-5846

## Checklist
- [ ] 1. Make `REPO_DIR` overridable (blocks 9)
- [ ] 2. Add the regex constants (blocks 3)
- [ ] 3. Add the `_hygiene_literal_lines` helper (blocks 4, 5)
- [ ] 4. Replace the `hardcoded` count; add `literal_defaults` and `hardcoded_mentions` (blocks 6)
- [ ] 5. Switch the findings sample to literals plus markers, and cap it at 25
- [ ] 6. Extend the JSON report, info line and `emit_event`
- [ ] 7. Update the help and info text
- [ ] 8. Add `literal_defaults` to the strategic summary
- [ ] 9. Add the fixture regression tests (depends on 1–6)
- [ ] 10. Run the hygiene, doctor and strategic suites, then `npm test`
- [ ] 11. Confirm on the real repo that `hardcoded` is several hundred (was 49) and that `lib/session-restart.sh:215/350/398/403` appear in the raw literal lines
- [ ] `counts.hardcoded` no longer changes when the word "hardcoded" is added in a comment or string (fixture test).
- [ ] `counts.hardcoded` drops when `[[ $n -ge 3 ]]` is rewritten as `${LIMIT:-3}` or `_smart_int` (fixture test).
- [ ] Exit-code comparisons, 0/1 checks, comment lines and `*-test.sh` files are excluded.
- [ ] The word count is still available as `counts.hardcoded_mentions`.
- [ ] doctor and strategic still work with both old and new JSON (`// 0` fallbacks).
- [ ] The hygiene, doctor and strategic suites pass, and `npm test` shows no regressions.

## Notes
- Generated from pipeline plan at 2026-09-25T07:01:07Z
- Pipeline will update status as tasks complete
