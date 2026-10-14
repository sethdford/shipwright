---
name: add-command
description: Add a new Shipwright CLI command in TypeScript (not a port). Use when a feature needs a new subcommand.
---
1. Choose the bounded context (AGENTS.md). Write the use case test in
   `src/contexts/<ctx>/application/<name>.test.ts`, then implement it; export it from `index.ts`.
2. Create `src/cli/commands/<name>.ts` exporting a `Command` (name, aliases, summary, usage, run).
   `run` only parses args, calls the use case, renders output and returns an exit code.
3. Register it in `src/cli/commands/index.ts` and add a router entry in `scripts/sw` using the
   `run_ts` helper: `<name>) run_ts <name> "$@" ;;`.
4. Add a progress.json entry with status `parity-green`, `parity: null` (new behavior) and
   `script: "sw-<name>.sh"` (no bash file needs to exist). `bun run port:check` fails for a
   `run_ts` route without an entry.
5. `bun run docs:gen && bun run check`.
