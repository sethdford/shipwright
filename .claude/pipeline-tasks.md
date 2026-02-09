# Pipeline Tasks — shipwright doctor should validate dashboard dependencies and port availability

## Implementation Checklist
- [x] `shipwright doctor` shows Bun check with install instructions if missing
- [x] Dashboard file existence verified (server.ts + public assets)
- [x] Port availability checked (with lsof/ss/netstat fallbacks)
- [x] Tests exist and are part of `npm test`

## Context
- Pipeline: standard
- Branch: docs/shipwright-doctor-should-validate-dashbo-6
- Issue: #6
- Generated: 2026-02-09T23:46:34Z
