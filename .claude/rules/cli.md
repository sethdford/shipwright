---
paths:
  - "src/cli/**"
---
A command parses arguments, calls one use case through a context's `index.ts`, and renders the
result. No business logic here. `usage` text is the help output and feeds `docs/reference/cli.md`;
run `bun run docs:gen` after changing it.
