---
paths:
  - "src/adapters/**"
---
Adapters implement a port from `src/shared/kernel/ports.ts` or a context's `ports.ts`.
Run programs with `ProcessRunner` and an argv array — never a shell string. Set a timeout on every
external call. Validate external data with zod before returning it. Every adapter has tests that use
`FakeProcessRunner` or `createTestEnv()`; none touch the real system.
