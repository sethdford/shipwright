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

### Known evasions

Closed by #8582 (each has an `invalid` rule-test case, and the rule-test YAML is in the ignore ban):
- F5 now catches `node:vm`, `node:module` (`createRequire`), `bun:ffi`, `import.meta.require`, and
  `window`/`self`/`globalThis` with a computed key (`window["fetch"]`).
- The meta-test pins each rule's `files` as well as its `ignores`, so narrowing coverage fails it.
- `bun run arch` must be exactly the checkers joined by `&&`; `|| true`, `; echo` and other shell
  operators fail the meta-test.
- The SDK runner must have exactly one `query` call, after `assertAgentOptions`.
- The ignore ban covers `tools/arch/rules`, `utils` and `rule-tests` YAML.
- Bash F9: `claude` is matched bare, quoted, behind an absolute path, after `command` or a wrapper
  (`timeout`, `gtimeout`, `$TIMEOUT_CMD`), or as `"$CLAUDE_BIN"`; the token must come before `claude`.
- Bash F10: `gh` is matched quoted, by absolute path or as `$GH_BIN`; the write verbs of `cache`,
  `project`, `ssh-key`, `gpg-key` and `codespace` are caught; `git push -o stash` is no longer excluded.
- Bash F11: shells under any directory (`/usr/local/bin/bash -c`), unquoted heredocs into a shell,
  `echo "$x" | bash`, `node --eval=` and `-p`, `perl -E`, `xargs sh -c` with `{}`, a download piped
  into `python`/`node`/`perl`/`ruby`/`bun`/`deno`, and `source /dev/stdin <<EOF` with an expansion.
- Dashboard: `const B = Bun`, `Reflect.get(Bun, …)`, `globalThis.Bun.spawn`, `import { $ as sh } from
  "bun"`, `import * as B from "bun"`, `createRequire`, and a computed `require`/`import` specifier.

Closed in #8582, ratcheted: `curl` to `api.github.com` with a write method or a body is
`F10-bash-curl-github-writes` (a new rule id). It has one counted finding, the GitHub App
installation-token mint in `scripts/sw-github-app.sh:169` (`curl … -d '{}' -X POST`). That call is
debt for the TypeScript port (an idempotent GithubWriter or auth-adapter method), not a rule gap; the
baseline may not grow, so it can only go down when the mint is ported.

Open, and why:
- `.github/CODEOWNERS` does not cover the other `.github/workflows/*.yml` or `scripts/postinstall.mjs`,
  which no rule scans.
- `scripts/postinstall.mjs` is not scanned by any rule.
- `bun run check` has no `--against`: the baseline comparison runs only in PR CI.
- F9 options: a variable passed as `options` is checked at run time only, and an `env:` built by a
  helper is not inspected statically. `settingSources` including `"user"` or `"local"` is not refused.
  Whether `permissionMode: "dontAsk"` overrides a project's `defaultMode` is unverified against the SDK.
- `risesAgainst` skips a group the base lacks (`if (!known) continue`), so a new rule id can be
  seeded with any count; PINNED and CODEOWNERS are the only guard.
- A computed `require`, `createRequire` or `import.meta.require` of the SDK inside `src/adapters` is
  not matched (F9-sdk-query-single-importer sees static imports, `import()` and `require()` only).
- Dashboard D2 checks direct imports only, and the raw-runner rule does not see a dynamic `import()`
  of `claims.ts`.

Out of scope (deliberate obfuscation, not an accidental path): prototype pollution
(`Object.prototype.extraArgs = …`), a `Function` constructor reached through a value, module or
command names built by string concatenation outside the dashboard, a GraphQL mutation held in a
variable, `gh "${args[@]}"` with the verb in an array, and bash bypass flags spelled with quotes
inside a word.
