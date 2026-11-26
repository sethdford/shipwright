# 0010. Agent output crosses into the trusted pipeline only as a patch

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
2. **Export.** The pipeline reads the agent's directory as plain files through a scratch git dir it owns
   (objects borrowed read-only from the trusted repo). It never runs git with the agent's `.git`, so the
   agent's config, hooks, filters, refs and replace objects have no effect. Attributes come from the empty
   tree, so an in-tree `.gitattributes` cannot hide or reshape a change.
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
- Rollout is opt-in (`SW_PATCH_HANDOFF=true`) until a real pipeline run has gone through it; then it becomes
  the default.
- Each build gets a fresh clone, so loop `--resume` does not apply under handoff.
- **Not covered yet**: the TDD and self-heal agents still run in the trusted checkout; test commands run the
  agent's code in the trusted checkout (credentials are already stripped, #8608); the agent runs as the same
  OS user, so isolation from the host is the sandbox backends' job. Base sha, goal and branch should come only
  from the out-of-repo record (#8671).
- The TS port's `delivery` context and `SideEffects` port should take this as their design.
