# 0008. Fitness functions everywhere, with ratchets for legacy code

Status: accepted · Date: 2026-10-14

## Context
Agents write most of Shipwright's code and read `bun run check` failures as instructions. The
architecture rules (F1–F8, F10) covered only `src/`, but the 2026-10 incidents came from code
outside it: `${{ }}` injection in workflows (#8533), shell strings built from request data in the
dashboard (#8534), and bash that runs `eval`, `bash -c "$cmd"` and `curl | bash`, passes
`--dangerously-skip-permissions`, lets `claude` inherit `GH_TOKEN`, and writes to GitHub from dozens
of scripts. `scripts/` (about 175k lines) is being ported, not rewritten, so its violations cannot
be fixed first. F9 was a "follow now" rule with no check, and a rule an agent can weaken is no rule.

## Decision
Everything that runs gets fitness functions in `bun run arch`, each with a message naming the fix:
- `src/`: F5 also catches evasion (aliased globals, `globalThis?.x`, computed imports, `eval`,
  `node:os`). F9 is enforced statically (bypass spellings, token names, literal `env:` and
  `permissionMode` on SDK calls) and at run time (`assertAgentOptions`).
- Bash in `scripts/`, hooks, completions and `install.sh` (ast-grep's Bash grammar): F11 code
  injection, F9 bypass flags and token scrubbing for `claude`, F10 GitHub writes.
- `dashboard/` (F12): its own dependency-cruiser layering (D1–D4) and a subprocess allowlist.

Where existing code violates a rule, the rule is a **ratchet**, never a warning: `severity: off` with
`metadata: { ratchet: true }`. `tools/arch/ast-scan.ts` runs every ast-grep rule over the files git
knows and compares ratcheted findings per rule × file with `tools/arch/findings-baseline.json`. A new
file or a higher count fails; a lower count fails until the baseline is tightened; a rule at zero
keeps an empty entry, which fails until the rule is promoted to `severity: error`. In CI,
`--against` the PR's merge base fails if this baseline or the F7 size baseline grew.

The rules guard themselves: a meta-test requires a rule test with valid and invalid cases, a message
naming the fix, an owner and a docs anchor for every rule, pins the rule set, the ratcheted set and
every allowlist, and forbids `ast-grep-ignore`; every dependency-cruiser rule must fire on a fixture.
`.github/CODEOWNERS` gives `tools/arch/`, `sgconfig.yml`, the dependency-cruiser configs and
`package.json` to the maintainer. `docs/reference/dependency-graph.md` is generated and checked.

## Consequences
- An agent cannot add an `eval`, a `bash -c "$x"`, a bypass flag, a `gh` write or a
  `child_process` call to the ratcheted code, and porting a script shrinks the baseline.
- Suppression is not an option for agents: there is no in-place ignore, and widening an allowlist,
  raising a baseline or turning a rule off edits a CODEOWNERS file the maintainer must approve
  (once "require review from code owners" is on for `main`).
- Renaming a file with ratcheted findings needs a reviewed baseline edit.
- A ratchet counts, it does not locate: a fix can hide a new finding in the same file.
- The rules are syntactic: data reaching a shell through a file or a function argument, or a
  GraphQL mutation held in a variable, is not caught.
- `bun run arch` gains about 1.5 s (a second dependency-cruiser run, one scan of all rules).
