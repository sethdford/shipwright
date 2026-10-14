---
paths:
  - "**/*.test.ts"
---
Use `bun:test`. Create paths with `createTestEnv()` and call `cleanup()`. Fake processes with
`FakeProcessRunner` (it throws on unscripted commands). Domain tests need no fakes at all.
Assert behavior, not implementation.
