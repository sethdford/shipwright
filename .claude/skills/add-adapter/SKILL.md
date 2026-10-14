---
name: add-adapter
description: Add an adapter for an external system (CLI tool, API, file format) behind a port. Use when a use case needs new I/O.
---
1. Define or extend the port interface where it is consumed (a context's `ports.ts`, or
   `src/shared/kernel/ports.ts` if several contexts need it). Types only.
2. Write tests in `src/adapters/<system>/<name>.test.ts` with `FakeProcessRunner` / `createTestEnv()`.
3. Implement with `ProcessRunner` (argv, timeout) and validate output with zod. Return `Result`.
   Never build a shell command string from request, issue, PR or model data.
4. Construct it in `src/main.ts` and pass it to the use case.
5. `bun run check` — F5 fails if I/O leaked outside `src/adapters`.
