---
paths:
  - "dashboard/**"
---
Run subprocesses only with `execFileSync`/`spawn` and an argv array, never `execSync`, `exec`,
`spawn(..., { shell: true })` or `Bun.$` built from a string. Validate every input (PIDs as integers,
names against an allowlist) before it reaches a subprocess, and never interpolate request data
(params, query, body, headers) into a command (#8534). Bind `127.0.0.1` by default; mutating routes
need a token; CORS is an allowlist, not `*`. Spec §6.2 "Dashboard exposure".
