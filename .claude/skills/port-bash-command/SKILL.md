---
name: port-bash-command
description: Port one Shipwright bash command (scripts/sw-*.sh) to TypeScript using the strangler flow and its bash test suite as the parity oracle. Use when picking up an entry from docs/plans/port/progress.json.
---
Never run a bash suite (`scripts/*-test.sh`) directly: many drive tmux and touch `HOME` and the
repo. Run suites only through the hermetic runners: `bash scripts/sw-test-all.sh --pattern <name>`
(against bash) or `bun run parity` (against TypeScript, in a sealed sandbox).

0. Check the don't-port list in §7.5 of
   `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md`. If the command (or the
   engine it belongs to) is listed there, stop and report it; do not port it.
1. Read the entry in `docs/plans/port/progress.json` (`command`, `aliases`, `script`, `context`,
   `parity`). Leave `status` at `bash` for now.
2. If `parity` is null, write `scripts/sw-<name>-test.sh` that pins today's behavior (arguments,
   exit codes, output, files written) and record it in the entry.
3. Baseline against bash: `bash scripts/sw-test-all.sh --pattern sw-<name>-test.sh` must pass
   before you change anything.
4. Implement in `src/contexts/<context>/`: pure rules in `domain/`, the use case in `application/`,
   ports for any I/O, adapters in `src/adapters/`. Write `bun:test` tests first (TDD).
5. Add the command in `src/cli/commands/` (old names in `aliases`) and register it in
   `src/cli/commands/index.ts`.
6. Set `status` to `porting` and `git add` the new files (the parity sandbox copies tracked files
   only). Run `bun run parity`. It copies the repo into a temporary sandbox with a private `HOME`,
   tmux socket and `TMPDIR` and fail-closed `claude`/`gh` shims, replaces the script of every
   entry at `porting` or later with a stub (`exec bun <sandbox>/src/cli.ts <command> "$@"`), runs
   the suite there, and fails if the real repo changed. A script shared with a command still at
   `bash` cannot be stubbed; parity reports that. Do not edit or replace the bash script: it stays
   as the reference implementation until the entry is `bash-deleted` (a separate change).
7. If an old assertion checks implementation (e.g. greps the script source), rewrite it to check
   behavior so it passes against both bash (step 3) and TypeScript (step 6), and say so in the
   commit message.
8. When parity is green, set `status` to `parity-green`, then flip the router: in `scripts/sw`
   replace the entry's `exec "$SCRIPT_DIR/<script>" "$@"` body with `run_ts <name> "$@"`, keeping
   every alias in the label, e.g. `name|alias) run_ts name "$@" ;;`. `bun run port:check` rejects a
   `run_ts` route whose entry is not `parity-green` or `bash-deleted`.
9. `bun run docs:gen`, then `bun run check` (it includes `port:check` and `parity`). Commit.
