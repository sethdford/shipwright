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
  `node:os`). F9 is enforced statically (bypass spellings, token names, one module that imports the
  SDK's `query` as a value, and each `query` call's options: an object literal whose `env:` is a
  literal or a call, or a variable, and a literal `permissionMode`) and at run time (`assertAgentOptions`, which allowlists option keys and
  requires `permissionMode: "dontAsk"`).
- Bash in `scripts/`, hooks, completions and `install.sh` (ast-grep's Bash grammar): F11 code
  injection, F9 bypass flags and token scrubbing for `claude`, F10 GitHub writes.
- `dashboard/` (F12): its own dependency-cruiser layering (D1–D4), a subprocess allowlist, and no
  import or export of an allowlisted service's raw command runner.

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
- Suppression is not an option for agents: there is no in-place ignore (no `ast-grep-ignore` marker in
  any file a rule covers; `docs/` and root files outside the rules are not scanned), and widening an allowlist,
  raising a baseline or turning a rule off edits a CODEOWNERS file the maintainer must approve
  (once "require review from code owners" is on for `main`).
- Renaming a file with ratcheted findings needs a reviewed baseline edit.
- A ratchet counts, it does not locate: a fix can hide a new finding in the same file.
- The rules are syntactic: data reaching a shell through a file or a function argument, or a
  GraphQL mutation held in a variable, is not caught.
- `bun run arch` gains about 0.7 s (a second dependency-cruiser run, one scan of all rules). The
  first estimate of 1.5 s was wrong; an independent verifier measured 0.7 s.

### Known evasions (follow-up)

Found by an independent verifier or in review, not yet closed. Each is a gap in a rule, not a
decision to allow the pattern.
- F5 misses `node:vm`, `node:module` `createRequire`, `bun:ffi`, `import.meta.require`,
  `window`/`self` `["fetch"]` and the `Function` constructor reached through a value.
- The meta-test pins a rule's `ignores` but not its `files`, so narrowing `files` passes it.
- `ARCH_STEPS` is a substring check: a step followed by `|| true` still passes.
- `.github/CODEOWNERS` does not cover the other `.github/workflows/*.yml` files or `scripts/postinstall.mjs`,
  which no rule scans.
- Bash F9, F10 and F11 are evaded by quoting, absolute paths (`/usr/bin/gh`), a `command` prefix,
  variables, heredocs, pipes into an interpreter held in a variable, and `curl` to `api.github.com`
  with a write method.
- Dashboard: the subprocess rule misses `Bun` aliasing, `Reflect.get`, `import {$ as sh}`,
  `createRequire` and a `require` built by concatenation. D2 checks direct imports only, and the
  raw-runner rule does not see a dynamic `import()` of `claims.ts`.
- F9 options: a variable passed as `options` is checked at run time only (its `env` is checked for
  GitHub token names there), and an `env:` built by a helper function is not inspected for contents. The runner's
  `settingSources: ["project"]` reads the repo's own `.claude/settings.json`, which can set
  `permissions`. The runner passes `permissionMode: "dontAsk"` explicitly, but that it overrides a
  project's `defaultMode` has not been verified against the SDK.
- `bun run check` has no `--against`: the baseline comparison runs only in PR CI.
- `scripts/postinstall.mjs` is not scanned.
- The meta-test checks only that the runner's first `assertAgentOptions` comes before its first `query`,
  so a second, unguarded call in the runner passes.
- A computed `require`, `createRequire` or `import.meta.require` of the SDK inside `src/adapters` is not
  matched (F9-sdk-query-single-importer sees static imports, `import()` and `require()` only).
- `risesAgainst` skips a group the base does not have (`if (!known) continue`), so a new rule id can be
  seeded with any count. PINNED and CODEOWNERS are the only guard.
- Prototype pollution (`Object.prototype.extraArgs = ...`): the guard reads own data properties, but the
  SDK's reads of options it does not own are not checked.
- The ignore ban does not cover `tools/arch/rule-tests/*.yml`, so a marker there is not caught.
- `settingSources` including `"user"` or `"local"` is not refused: the runner sets only `"project"`, and
  the guard does not check the list.
