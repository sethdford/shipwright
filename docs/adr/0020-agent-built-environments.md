# 0020. Agent-built, cached run environments

Status: accepted · Date: 2026-11-26

## Context
Every pipeline starts from a fresh git worktree, and git does not carry dependencies. Nothing in
Shipwright installed them: the daemon's issue worktrees, `sw-loop` agent worktrees and tournament
attempts all ran tests against a tree with no `node_modules` or `.venv`, and the test-gate baseline
worked around it by symlinking the main checkout's `node_modules` (wrong whenever the lockfile
differs, and nothing for any other ecosystem). Agents then spent turns and budget on "module not
found", or the test stage failed for reasons unrelated to the change.

Cloud coding agents treat the environment as a first-class, reusable artifact. Codex cloud
environments run a setup script once, cache the resulting container for hours and reuse it across
tasks, invalidating on setup or configuration changes. Devin snapshots a machine the agent set up
itself. Copilot coding agent reads `copilot-setup-steps.yml`. Cursor background agents read
`.cursor/environment.json` (install command, snapshot, terminals for services). The common shape:
a declarative recipe in the repository, written once (often by the agent), run in isolation,
snapshotted, and keyed so a lockfile or toolchain change rebuilds.

Shipwright runs on a developer's Mac and on GitHub Actions runners, not in a container fleet, so a
container snapshot is the wrong unit. The reusable unit is the set of directories setup produces.

## Decision
Add `shipwright env` (platform context) and a recipe file, `.shipwright/env.json`.

1. **The recipe** lists setup commands (argv arrays, never shell strings), the repository-relative
   paths setup produces (`cache`), the files that decide whether a cached copy still fits
   (`keyFiles`), toolchain fingerprint commands (`node --version`), a smoke command, the test
   command, non-secret variables, and services (start, ready probe, stop). It refuses credential-
   looking or loader variables (`*_TOKEN`, `LD_*`, `DYLD_*`, `PATH`), absolute and `..` paths.
   Helper logic goes in `.shipwright/setup.sh`, called as `["bash", ".shipwright/setup.sh"]`.
2. **The key** is a digest of the setup-relevant recipe fields, each key file's content, the
   fingerprint outputs, OS and architecture. Editing the smoke or test command or a service keeps
   the cache warm; a lockfile change or toolchain upgrade misses.
3. **The cache** lives in `<state>/env-cache/<repo-id>/<key>/`. The repo id is the same for every
   clone and worktree of a repository. Entries are staged and renamed into place. Restores are
   copy-on-write clones (APFS `cp -c`, Linux `cp --reflink=auto`), plain copies elsewhere, so a
   restore on a Mac costs almost no disk and finishes in about a second.
4. **`env init`** has an agent author the recipe and Shipwright prove it. The agent may only read
   the repository and write the recipe (no network, no installs; `ENV_AUTHOR_TOOLS`). Shipwright
   runs setup and the smoke command in a second, untouched clone, through `scripts/lib/env-exec.sh`
   (credentials stripped, and inside the test sandbox's write jail where it exists, ADR-0011), and
   feeds a failure's command and output back for the next attempt. The first recipe that proves
   out is cached and written into the operator's working tree to review and commit. `--no-agent`
   proves the deterministic detected recipe instead. Without any recipe, `hydrate` falls back to
   detection (bun, pnpm, yarn, npm, uv, poetry, pip, bundler, go, cargo, composer).
5. **`env hydrate`** makes a checkout ready: restore on a key hit, otherwise run setup and cache
   it. Only a committed recipe (read from a git ref of the trusted repository, default `HEAD`) or a
   detected one runs setup. A working-tree recipe runs only with `--trust-worktree`.
   `--restore-only` never runs anything, for checkouts that hold agent edits.
6. **Call sites:** the daemon hydrates each new issue worktree from the base branch's recipe;
   `sw-loop` hydrates its agent worktrees; the test-gate baseline restores before falling back to
   the old symlink; the test sandbox (ADR-0011) calls `test_sandbox_hydrate` outside its jail,
   which is restore-only. GitHub Actions uses the composite action `.github/actions/env-cache`,
   which pairs `env key --json` with `actions/cache` so the store survives between runs.
7. **Services** (`env up`, `env down`) start in order and wait for each ready probe; down runs in
   reverse and keeps going past failures. They are explicit commands, not started by hydrate,
   because parallel worktrees would collide on ports.

## Consequences
- Fresh worktrees get dependencies, so the test stage measures the change instead of the setup.
- The cache can grow large (a Node project's `node_modules` is often hundreds of MB, though clones
  share blocks on APFS and reflink filesystems). `env prune` keeps the most recently used entries.
- A cached environment is trusted as built: its key includes the lockfiles, but a setup that
  downloads unpinned packages can drift until the key changes. Prefer frozen installs.
- Setup commands execute repository code (install scripts). That is the same exposure as running
  the tests, and is why only reviewed (committed) recipes run setup and why it goes through the
  credential-stripping executor.

## Not covered yet
- Tournament attempts (`GitWorkspaces.create`) and bench task workspaces do not hydrate yet.
- Services are not started automatically by the pipeline.
- No cross-machine cache sharing other than GitHub Actions' cache.
