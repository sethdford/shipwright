# Pipeline Tasks — Add --json output flag to shipwright status command

## Implementation Checklist
- [x] `shipwright status --json` outputs valid JSON
- [x] All sections present: teams, daemon, heartbeats, machines (plus tasks and timestamp)
- [x] `shipwright status` (without flag) still works identically
- [x] Tests validate JSON output structure

## Context
- Pipeline: standard
- Branch: feat/add-json-output-flag-to-shipwright-statu-4
- Issue: #4
- Generated: 2026-02-09T22:27:27Z
