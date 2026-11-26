# 0011. Agent output crosses into the trusted pipeline only as a patch

Status: proposed (#8706; interim guard #8662) · Date: 2026-11-26

## Context

The build agent and the trusted pipeline shared one checkout, one git dir and one `.claude/` directory.
Anything the agent wrote there could steer what the pipeline did next: git config (`core.fsmonitor`,
`core.hooksPath`, `core.sshCommand`, filters), hooks, remotes, refs and replace refs, which branch `HEAD`
names, state files and `node_modules`. Four adversarial reviews of the blast-radius guard (#8662) each closed
one such path and found the next. A blocklist over a shared directory does not converge.

## Decision

The agent's work crosses the boundary as data, a binary patch, and nothing else
(`scripts/lib/patch-handoff.sh`):

1. **Prepare.** The pipeline records the base sha in its trusted checkout, then makes a disposable clone of
   it for the agent: detached at the base, no remote, no credentials. The loop runs there with GitHub and
   fleet tokens removed and an empty `gh` config.
   Uncommitted edits that earlier stages' agents (plan, design, spec) left in the trusted checkout are
   moved into the clone first, so they are judged with the build instead of riding along unjudged.
2. **Export.** The pipeline reads the agent's directory as plain files through a scratch git dir it owns
   (objects borrowed read-only from the trusted repo). It never runs git with the agent's `.git`, so the
   agent's config, hooks, filters, refs and replace objects have no effect. Attributes come from the empty
   tree, so an in-tree `.gitattributes` cannot hide or reshape a change. `.claude/` (loop and pipeline
   runtime state, agent configuration) is never part of the patch.
3. **Judge.** The patch is judged as data before it touches the trusted checkout: no symlinks or
   submodules, no binary changes by default, no protected paths (workflows, agent policy and settings,
   arch rules, ADRs, `.gitattributes`, the boundary's own scripts), no C-quoted (unusual) paths, and file,
   added-line and deleted-line budgets.
4. **Apply.** A judged patch is applied to the trusted checkout, which must be clean and at the base, and
   committed by the pipeline with hooks off. Delivery pushes that commit.

Every trusted-side git call runs without system or global config, replace objects, hooks, fsmonitor, ssh
command or external diff.

## Consequences

- The structural guarantee replaces a growing blocklist: the trusted side reads only a patch file.
- It carries over to M2/M3, where the agent may run on another machine: the patch is the interface.
- On by default. `SW_PATCH_HANDOFF=false` restores the shared-checkout build, as an escape hatch while
  the handoff gets real runs.
- Each build gets a fresh clone, so loop `--resume` does not apply under handoff.
- The branch gets one pipeline commit per build (`build: <goal>`); the loop's own commits stay in its
  clone. A build with no changes applies nothing and succeeds.
- Every other write into the trusted checkout is judged the same way: the spec-first acceptance test writer
  (ADR-0015) runs in a disposable clone at HEAD, and the test files it answers with pass `handoff_judge`
  (protected paths, symlinks, binaries, size) before `verify-red` runs them or they are committed; the PR
  stage's "commit remaining changes" and CI partial-work commits go through `handoff_commit_dirty`; a commit
  made during intake, plan, design or review is undone (`reset --mixed`) so its content meets the next judge;
  artifact commits name their paths. Self-heal re-runs the build stage, so it was already covered.
- **Not covered yet**: test commands (including `acceptance verify-red`/`verify-green`) run the
  agent's code in the trusted checkout (credentials are already stripped, #8608); the agent runs as the same
  OS user, so isolation from the host is the sandbox backends' job. Base sha, goal and branch should come only
  from the out-of-repo record (#8671).
- The TS port's `delivery` context and `SideEffects` port should take this as their design.
