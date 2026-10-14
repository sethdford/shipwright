# Wave 1a-arch — Architecture Fitness Everywhere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the architecture fitness functions in `bun run arch` from `src/` to everything that runs, and make them hard to weaken. The plan enforces F9 (no GitHub token, no permission bypass) statically and at run time, and closes F5 evasion holes. It ratchets the bash debt in `scripts/`, hooks, completions and `install.sh` (F9, F10, F11) and the dashboard's subprocess sprawl (F12), and gives the dashboard its own layering rules. The rules guard themselves: each needs a test, a fix-naming message and an owner; allowlists and ratcheted sets are pinned; in-place suppression is banned; baselines cannot rise against the merge base; and CODEOWNERS covers it all. The import graph is generated as documentation.

**Architecture:** ast-grep rules stay one YAML file per rule in `tools/arch/rules` with a rule test in `tools/arch/rule-tests`. Bash uses ast-grep's built-in `Bash` grammar, with four shared util rules in `tools/arch/utils`. `tools/arch/ast-scan.ts` replaces the bare `ast-grep scan`: it runs every rule over `git ls-files`, so ignore files cannot hide a tracked file, and it fails on any ast-grep error. Rules with `severity: error` must have no findings. A rule that existing code violates is a **ratchet** (`severity: off` plus `metadata.ratchet`), counted per rule × file against `tools/arch/findings-baseline.json`; the pure logic lives in `findings-ratchet.ts`. `baseline-history.ts` compares that baseline and the F7 size baseline with the PR's merge base (`--against`, run in CI). The meta-test `tools/arch/meta.test.ts` (with the loader `rule-catalog.ts`) and `tools/arch/depcruise-rules.test.ts`, which runs fixtures for every dependency-cruiser rule, keep the rules honest. The dashboard gets a second dependency-cruiser config. `bun run docs:gen` also writes `docs/reference/dependency-graph.md`. ADR-0008 records the approach.

**Tech Stack:** Bun 1.2.19, TypeScript (strict), `@ast-grep/cli` 0.50.0 (TypeScript and Bash grammars), dependency-cruiser 18.6.0 (CLI and `cruise` API), Biome 2, `yaml`, actionlint.

**Spec:** `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md` §3.3 · the Wave 1a plan `docs/superpowers/plans/2026-10-14-wave-1a-safety.md` (Tasks 3, 14–18) · `AGENTS.md`.

**Sequencing:** Run this plan **after Wave 1a Task 17 and before Wave 1a Task 18**, on `wave1/safety`, so that it ships in the Wave 1 PR and Task 18's verifier and reviewer cover it. It relies on these Wave 1a pieces:
- Task 14: `tools/arch/workflow-fail-closed.ts` in the `arch` script.
- Task 15: `dashboard/tsconfig.server.json`, and the `dashboard-no-shell-from-data` rule with its test. That rule is the spec's interim "no template-literal or concatenated command strings" rule; this plan reuses it rather than duplicating it.
- Task 16: `fleet_curl` in `scripts/lib/safety-gates.sh`.
- Task 17: ADR-0007 and its edits to `AGENTS.md` and `docs/architecture.md`. The doc edits below replace whole sections, so they apply on top of Task 17's wording.

**Not in this plan:** fixing the ratcheted findings (they shrink as commands are ported); turning on "require review from code owners" for `main` (a repository setting the maintainer changes); data-flow analysis.

---

## Decisions this plan takes (recorded in ADR-0008, Task 7)

| Topic | Decision |
|---|---|
| Numbering | F9 is enforced. F3 gains "src and dashboard never import each other". F10 gains a bash ratchet. New: **F11 bash safety** and **F12 dashboard boundaries**. The dashboard's dependency-cruiser rules are D1–D4 inside F12. Dashboard ast-grep rules keep the `dashboard-` prefix (from Wave 1a's `dashboard-no-shell-from-data`), and their messages start `Dashboard:`. |
| Ratchet over warnings | Every new rule that existing code violates is a ratchet, never a warning. A warning trains agents to ignore output; a ratchet blocks new debt and lets the baseline shrink. |
| One scanner, one ratchet | `ast-scan.ts` scans once with every rule. Its contract matches the size ratchet: a new file or a higher count fails, a lower count fails until tightened, and a stale entry fails. Every ratcheted rule keeps a key in the baseline. An empty key fails the meta-test until the rule is promoted to `severity: error`; a missing key means "seed it". `--write-baseline` refuses to raise a count or add a file to a known rule; it seeds only a rule it has never seen. |
| Anti-laundering | CI runs `ast-scan.ts --against origin/$GITHUB_BASE_REF` and `size-ratchet.ts --against …`: no entry may appear and no count may rise against the merge base (a newly ratcheted rule's first seed is allowed). The meta-test pins the rule set, the ratcheted set and every rule's `ignores`, and fails on any `ast-grep-ignore` in `src/`, `dashboard/`, `scripts/` or `tools/`. `.github/CODEOWNERS` assigns `tools/arch/**`, `sgconfig.yml`, `.dependency-cruiser*.cjs` and `package.json` to @sethdford. |
| Determinism | Scans pass `git ls-files --cached --others --exclude-standard` (minus deleted files) with every `--no-ignore` flag, never a directory walk. Any `error` line on ast-grep's stderr fails the scan, even when it also reported matches; only its "N error(s) found in code" summary is expected. |
| F9 (TypeScript) | Unanchored and case-insensitive. Any string fragment (including template pieces), identifier or key containing `dangerously`, `bypass_?permissions` or `skip-permissions`, and any `+` concatenation spelling one, is flagged. So is `\b(GH\|GITHUB)(_ENTERPRISE)?_TOKEN\b`. Scope: `src/**` and `dashboard/**` except tests, `src/adapters/github/**` and `src/adapters/agent/privilege-guard.ts`. In `adapters/agent`, every `query()` call passes an object literal with `env:` (never `process.env`, `Bun.env` or a spread of them), and `permissionMode` is a string literal. At run time, `assertAgentOptions()` throws on `bypassPermissions`, `allowDangerouslySkipPermissions` or a token in the env. |
| F9 (bash) | Bypass flags are ratcheted. Every `claude` invocation, direct or behind a wrapper such as `timeout`, `nohup`, `env` or `$TIMEOUT_CMD`, must unset `GH_TOKEN` and `GITHUB_TOKEN` in the same command (`env -u …`) or go through a helper such as `sw_claude`. `command -v claude` and log lines are not invocations. |
| F10 (bash) | Inventory at `2aaa43fda`: 99 GitHub writes in 37 scripts, too broad for an allowlist, so the rule is a ratchet. It covers `gh` write subcommands (now including `repo create/delete/edit/fork/rename/archive` and `gist`), `gh api` with a write method, a body without an explicit `GET`, or a GraphQL `mutation` written literally, and `git push`. A mutation held in a variable is missed (documented). `scripts/lib/safety-gates.sh` is baselined. |
| F11 | `eval`, `command eval` and `builtin eval`; `source`/`.` of `/dev/stdin` fed by a here-string, or of a process substitution, built from data; `sh -c`/`"$SHELL" -c`; `python`, `node`, `perl`, `ruby`, `bun` or `deno` given `-c`/`-e`/`--eval` with an expansion; a here-string fed to a shell; `ssh host "cmd $x"` (a quoted command with whitespace and an expansion); downloads run as code (piped into `sh`/`env bash`/`sudo bash`/`source /dev/stdin`, or `bash <(curl…)`/`. <(curl…)`/`sh -c "$(curl…)"`); `${{` (fix: a checked-in `.yml` template). |
| Bash scope | `scripts/**/*.sh`, `scripts/sw`, `.claude/hooks/**/*.sh`, `claude-code/hooks/**/*.sh`, `completions/**/*.bash`, `install.sh`. `completions/_shipwright` (zsh) and `completions/shipwright.fish` are not bash and are excluded. The meta-test keeps every Bash rule on this one list. |
| F5 evasion | Also flagged: `Bun`, `process`, `globalThis` and `global` used as values; `eval` and `Function` used at all; `globalThis`/`global`/`window`/`self` `.process`/`.Bun`/`.fetch`/…, including `?.`; `import.meta.env`; `import()`/`require()` with a computed specifier; `new Worker`/`WebSocket`/`EventSource`/`XMLHttpRequest`; `os`/`node:os`. Declarations of locals or parameters named `process` are not flagged. A local passed as a value is, and the message says to rename it. |
| Meta | Every ast-grep rule needs: one rule test with valid and invalid cases; a message starting with its family (`F11:`, `Dashboard:`) and naming a fix; `severity: error` or the ratchet marker; `metadata.owner` and a `metadata.docs` anchor that exists in `docs/architecture.md`; and `files` that match at least one tracked file, unless `metadata.preemptive` says why not (`F10-…-tsx`: `src` has no `.tsx` yet). Every dependency-cruiser rule fires on a fixture, and its comment starts with its family and names a fix. `bun run arch` must contain every checker. |
| Dashboard | D1 now also covers `dashboard/` → `src/` (and F3 covers `src/` → `dashboard/`). Resolution goes through `dashboard/tsconfig.server.json`. The subprocess allowlist is `services/claims.ts` and `services/subprocess-guards.ts`. `server.ts` is ratcheted with 12 findings (at `efa1e4704`). The rule also catches `const { spawn } = Bun` and `Bun["spawn"]`. |
| Dropped as infeasible | **A workflow F9 check:** the workflows contain none of the names, and ast-grep's YAML support adds little over a text search. **Taint tracking:** data reaching a shell through a file or a function argument, or a GraphQL mutation in a variable, cannot be caught syntactically. **A "named helper" exemption for `claude`:** no `sw_claude` helper exists yet, so the rule asks for one rather than whitelisting a name. A helper that runs `env -u … claude` passes by construction. |

## Conventions for every task

- Run commands from the worktree root, `/Users/sethford/Documents/shipwright-wave1`.
- Other implementers commit in this worktree. **Commit only the paths a task names**, with `git commit -m "…" -- <paths>`; never `git add -A .` or `git commit -a`.
- Run `bun run format` before `bun run check`, and stage new files before `bun run check`: the parity sandbox (`tools/port/sandbox.ts`) copies only files in the git index.
- `ast-grep test` silently skips a rule test whose rule does not exist, so a red step for a new rule is a probe scan, not the rule test. Task 3 closes that gap.
- Ratcheted rules are `severity: off`; `ast-grep test` runs them only with `--include-off`, which Task 3 adds to `bun run arch`.
- Never revert a probe with `git checkout -- <file>` if the same file has uncommitted task edits: you lose them. Remove the probe line instead, or commit first.

## Dry run

Every task was dry-run on 2026-10-14 in a scratch clone of `wave1/safety` at `2aaa43fda` (Wave 1a Task 15's commit, which has `tsconfig.server.json`), with node_modules symlinked. Task 15's `dashboard-no-shell-from-data` rule and rule test were copied in from its plan, because they had not been committed yet. Each red step failed as stated, each green step passed, and `bun run check` passed after every task. The expected output below is from that run. Ratchet totals are recomputed at execution time against the then-current `HEAD` (Task 4 Step 9, Task 5 Step 6), so they may differ slightly.

| Measured on the dry run | Before | After |
|---|---|---|
| `bun run arch` | 0.74–0.76 s | 1.37–1.39 s |
| full ast-grep scan (`ast-scan.ts`) | — | 0.27 s |
| `bun test ./src ./tools` | 5.0–5.2 s | 5.6–5.8 s |
| `bun run check` | 8.7–8.8 s | 9.9–10.3 s (about +1.3 s) |

---

## File map

| Path | Responsibility |
|---|---|
| `tools/arch/rules/f9-no-agent-privilege.yml`, `f9-agent-options-explicit.yml` + tests | F9 for TypeScript |
| `src/adapters/agent/privilege-guard.ts` + test, `agent-sdk-runner.ts` (+ test) | F9 runtime guard; `agentEnv()` and runner regression tests |
| `tools/arch/rules/f5-io-only-in-adapters.yml` + test | F5 evasion |
| `tools/arch/rule-catalog.ts` | Loads rule and rule-test YAML; `isRatcheted`; `trackedFiles()` (git's file list) |
| `tools/arch/meta.test.ts` | Pins rules, ratchets and allowlists; tests, messages, owners, docs anchors, globs, baselines, no suppression, `arch` steps |
| `tools/arch/depcruise-rules.test.ts` | Each dependency-cruiser rule fires on a fixture; comment format |
| `.dependency-cruiser.cjs` | Comment prefixes; F3 `src` → `dashboard` |
| `.github/CODEOWNERS` | Maintainer review for the fitness functions |
| existing rules `f5`, `f6`, `f8`, `f10`, `f10-…-tsx`, `dashboard-no-shell-from-data` | `metadata` (owner, docs, preemptive); F6/F8 message prefixes |
| `sgconfig.yml`, `tools/arch/utils/bash-{expansion,shell,text,download}.yml` | Bash utils; `scripts/sw` parsed as Bash |
| `tools/arch/rules/f11-bash-no-{eval-expansion,shell-c-expansion,pipe-to-shell,gha-expression}.yml` + tests | F11 (ratcheted) |
| `tools/arch/rules/f9-bash-{no-permission-bypass,claude-token-scrub}.yml`, `f10-bash-github-writes.yml` + tests | F9 and F10 for bash (ratcheted) |
| `tools/arch/findings-ratchet.ts` + test | Pure ratchet logic |
| `tools/arch/baseline-history.ts` + test | Merge-base comparison (`--against`) |
| `tools/arch/ast-scan.ts`, `tools/arch/findings-baseline.json` | The scanner CLI and its baseline |
| `tools/arch/size-ratchet.ts` | `--against` |
| `.github/workflows/ts-check.yml` | `fetch-depth: 0`; the `--against` step |
| `.dependency-cruiser.dashboard.cjs` | F12 D1–D4 |
| `tools/arch/rules/dashboard-subprocess-only-in-services.yml` + test | F12 subprocess allowlist (ratcheted) |
| `tools/docs/gen-dependency-graph.ts` + test, `docs/reference/dependency-graph.md` | Generated import graph |
| `package.json` | `arch`, `docs:gen`, `docs:check` |
| `AGENTS.md`, `docs/architecture.md`, spec §3.3, `docs/adr/0008-fitness-functions-everywhere.md` | Guidance and the decision record |

---

### Task 0: Verify the prerequisites and a green base

**Files:** none

- [ ] **Step 1: Confirm the branch, the Wave 1a pieces this plan builds on, and the tool versions**

```bash
git status -sb | head -1
test -f tools/arch/workflow-fail-closed.ts && test -f dashboard/tsconfig.server.json \
  && test -f tools/arch/rules/dashboard-no-shell-from-data.yml \
  && test -f tools/arch/rule-tests/dashboard-no-shell-from-data-test.yml \
  && grep -q fleet_curl scripts/lib/safety-gates.sh \
  && test -f docs/adr/0007-safety-controls.md && echo "1a Tasks 14-17 present"
grep -o 'workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts' package.json
./node_modules/.bin/ast-grep --version; ./node_modules/.bin/depcruise --version; actionlint --version | head -1
```

Expected: `## wave1/safety`, `1a Tasks 14-17 present`, the grep prints the fragment, `ast-grep 0.50.0`, `18.6.0`, an actionlint version. If anything is missing, stop: finish Wave 1a Tasks 14–17 first. Wave 1a Task 18 runs after this plan.

- [ ] **Step 2: Run the definition of done and time it**

```bash
time bun run check
```

Expected: passes, ending with `✓ parity hello` and `1/1 parity suites passed`. Note the time; Task 8 compares against it.

---

### Task 1: F9 enforced — static rules, a runtime guard, regression tests

**Files:**
- Create: `tools/arch/rules/f9-no-agent-privilege.yml`, `tools/arch/rules/f9-agent-options-explicit.yml` and their tests; `src/adapters/agent/privilege-guard.ts`, `src/adapters/agent/privilege-guard.test.ts`
- Modify: `src/adapters/agent/agent-sdk-runner.ts`, `src/adapters/agent/agent-sdk-runner.test.ts`

- [ ] **Step 1: Write both rule tests**

`tools/arch/rule-tests/f9-no-agent-privilege-test.yml`:

```yaml
id: F9-no-agent-privilege
valid:
  - 'const options = { permissionMode: "dontAsk", allowedTools: ["Read"] };'
  - 'const env = agentEnv(source);'
  - 'const token = env.SHIPWRIGHT_FLEET_TOKEN;'
  - 'const ok = mode === "default";'
  - 'const label = "permissions";'
invalid:
  - 'const options = { permissionMode: "bypassPermissions" };'
  - 'const options = { allowDangerouslySkipPermissions: true };'
  - 'const argv = ["claude", "-p", prompt, "--dangerously-skip-permissions"];'
  - 'const argv = ["claude", "--dangerously-skip-permissions=true"];'
  - 'const flag = `--dangerously-skip-permissions`;'
  - 'const flag = `--dangerously-${rest}`;'
  - 'const flag = "--" + "dangerously" + "-skip";'
  - 'const mode = "bypass" + "Permissions";'
  - 'const mode = prefix + "bypass" + "Permissions";'
  - 'const flag = "--skip-permissions";'
  - 'const mode: PermissionMode = "bypassPermissions";'
  - 'env.GH_TOKEN = token;'
  - 'const env = { GITHUB_TOKEN: source.GITHUB_TOKEN };'
  - 'const t = source["GH_ENTERPRISE_TOKEN"];'
  - 'const keys = ["PATH", "GITHUB_TOKEN"];'
  - 'const { GH_TOKEN } = source;'
  - 'const line = `export GITHUB_ENTERPRISE_TOKEN=${t}`;'
```

`tools/arch/rule-tests/f9-agent-options-explicit-test.yml`:

```yaml
id: F9-agent-options-explicit
valid:
  - 'this.queryFn({ prompt, options: { ...options, env: { ...this.env }, abortController: c } });'
  - 'query({ prompt, options: { env: agentEnv(source), permissionMode: "dontAsk" } });'
  - 'const o = { permissionMode: "dontAsk", allowedTools: [] };'
  - 'const rows = db.query("SELECT 1");'
invalid:
  - 'this.queryFn({ prompt, options: { ...options, abortController: c } });'
  - 'query({ prompt, options });'
  - 'query({ prompt, options: { env: process.env } });'
  - 'const o = { env: { ...process.env, X: "1" } };'
  - 'const o = { env: Bun.env };'
  - 'const o = { permissionMode: mode };'
  - 'const o = { permissionMode };'
  - 'const o = { permissionMode: fast ? "dontAsk" : other };'
```

- [ ] **Step 2: Probe: a split bypass spelling and a variable permission mode are not caught yet**

```bash
printf 'export const mode = "bypass" + "Permissions";\nexport const o = (m: string) => ({ permissionMode: m });\n' > src/adapters/agent/zz-probe.ts
./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "exit=$?"
```

Expected: `exit=0`.

- [ ] **Step 3: Write the rules**

`tools/arch/rules/f9-no-agent-privilege.yml`:

```yaml
# F9: agents get no GitHub token and no permission bypass (spec §3.3).
# Flags any string, template piece, identifier or key that contains a bypass spelling or a GitHub
# token name, and string concatenations that spell one in pieces ("bypass" + "Permissions").
# Unanchored on purpose: "--dangerously-skip-permissions=true" and `--dangerously-${x}` count.
# Allowlist (pinned in tools/arch/meta.test.ts): tests, src/adapters/github/** (gh authenticates
# there; it never builds an agent's env) and src/adapters/agent/privilege-guard.ts (the runtime
# check that names what it refuses). Bash callers: F9-bash-* (ratcheted).
id: F9-no-agent-privilege
language: TypeScript
severity: error
message: "F9: agents never get a GitHub token or a permission bypass. Use permissionMode \"dontAsk\" with a per-stage allowedTools list, build the agent env with agentEnv() (src/adapters/agent/agent-sdk-runner.ts), and route GitHub writes through GithubWriter."
metadata: { owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
files:
  - "src/**/*.ts"
  - "dashboard/**/*.ts"
ignores:
  - "**/*.test.ts"
  - "src/adapters/github/**"
  - "src/adapters/agent/privilege-guard.ts"
rule:
  any:
    - all:
        - any:
            - kind: string_fragment
            - kind: identifier
            - kind: property_identifier
            - kind: shorthand_property_identifier
            - kind: shorthand_property_identifier_pattern
        - regex: '(?i)dangerously|bypass_?permissions|skip[-_]?permissions|\b(GH|GITHUB)(_ENTERPRISE)?_TOKEN\b'
    # A spelling split across `+` pieces. Only the innermost matching expression is reported.
    - all:
        - kind: binary_expression
        - regex: '(?i)bypass\W*permissions|skip\W*permissions|dangerously'
        - not:
            has:
              kind: binary_expression
              regex: '(?i)bypass\W*permissions|skip\W*permissions|dangerously'
```

`tools/arch/rules/f9-agent-options-explicit.yml`:

```yaml
# F9 in the agent adapter: every SDK call states its environment and permission mode explicitly, so
# a refactor cannot drop the env allowlist or thread a bypass mode through a variable. The runtime
# twin is assertAgentOptions() in src/adapters/agent/privilege-guard.ts.
id: F9-agent-options-explicit
language: TypeScript
severity: error
message: "F9: pass query() an options object literal with env: built by agentEnv() (never process.env or Bun.env), and give permissionMode as a string literal such as \"dontAsk\"."
metadata: { owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
files:
  - "src/adapters/agent/**/*.ts"
ignores:
  - "**/*.test.ts"
rule:
  any:
    # query(...) / this.queryFn(...) without `options: { …, env: … }`
    - kind: call_expression
      all:
        - has: { field: function, regex: '(^|\.)(query|queryFn)$' }
        - has:
            field: arguments
            has:
              kind: object
              not:
                has:
                  kind: pair
                  all:
                    - has: { field: key, regex: '^options$' }
                    - has:
                        field: value
                        kind: object
                        has:
                          kind: pair
                          has: { field: key, regex: '^env$' }
    # env taken from the parent process
    - kind: pair
      all:
        - has: { field: key, regex: '^env$' }
        - has: { field: value, regex: '\b(process\.env|process\[|Bun\.env)' }
    # permissionMode from anything but a string literal
    - kind: pair
      all:
        - has: { field: key, regex: '^permissionMode$' }
        - not: { has: { field: value, kind: string } }
    - kind: shorthand_property_identifier
      regex: '^permissionMode$'
```

- [ ] **Step 4: Rule tests pass; the probe fails; the real tree is clean**

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep -E 'F9|result'
./node_modules/.bin/ast-grep scan 2>&1 | grep '^error'
rm src/adapters/agent/zz-probe.ts
./node_modules/.bin/ast-grep scan 2>&1 | grep -c '^error'
```

Expected: `PASS F9-agent-options-explicit  ............`, `PASS F9-no-agent-privilege  ......................`, `test result: ok. 8 passed; 0 failed;`; the probe reports `error[F9-no-agent-privilege]` and `error[F9-agent-options-explicit]`; then `0`.

- [ ] **Step 5: Write the runtime guard's test and the runner regression tests**

`src/adapters/agent/privilege-guard.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { assertAgentOptions } from "./privilege-guard";

describe("assertAgentOptions (F9 runtime guard)", () => {
  test("accepts dontAsk with an allowlisted env", () => {
    expect(() =>
      assertAgentOptions({ permissionMode: "dontAsk", env: { PATH: "/bin", HOME: "/h" } }),
    ).not.toThrow();
  });

  test("refuses a permission bypass", () => {
    expect(() => assertAgentOptions({ permissionMode: "bypassPermissions" })).toThrow(/F9/);
    expect(() => assertAgentOptions({ allowDangerouslySkipPermissions: true })).toThrow(/F9/);
  });

  test("refuses any GitHub token in the agent env", () => {
    for (const key of [
      "GH_TOKEN",
      "GITHUB_TOKEN",
      "GH_ENTERPRISE_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
    ]) {
      expect(() => assertAgentOptions({ env: { PATH: "/bin", [key]: "t" } })).toThrow(key);
    }
  });
});
```

In `src/adapters/agent/agent-sdk-runner.test.ts`, inside `describe("agentEnv", …)`, insert before `test("includes ANTHROPIC_API_KEY only when present", () => {`:

```ts
  test("F9: never forwards a GitHub token, whatever else is set", () => {
    const tokens = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
    const env = agentEnv({
      PATH: "/bin",
      ANTHROPIC_API_KEY: "k",
      ...Object.fromEntries(tokens.map((t) => [t, "secret"])),
    });
    for (const t of tokens) expect(t in env).toBe(false);
    expect(Object.values(env)).not.toContain("secret");
  });

  test("F9: a runner given a GitHub token refuses to start the agent", async () => {
    const { fn, state } = fakeQuery([result({ subtype: "success", result: "x" })]);
    const runner = new AgentSdkRunner({ PATH: "/bin", GH_TOKEN: "t" }, fn);
    await expect(
      runner.runTask({
        prompt: "p",
        cwd: "/w",
        model: "m",
        effort: "low",
        allowedTools: [],
        maxTurns: 1,
        maxBudgetUsd: 1,
        timeoutMs: 1000,
      }),
    ).rejects.toThrow(/F9/);
    expect(state.iterated).toBe(false);
  });

```

```bash
bun test src/adapters/agent 2>&1 | grep -E 'error:|\(fail\)|^\s*[0-9]+ (pass|fail)'
```

Expected: `Cannot find module './privilege-guard'` and `(fail) agentEnv > F9: a runner given a GitHub token refuses to start the agent`; `56 pass`, `2 fail` on the dry run.

- [ ] **Step 6: Write the guard and call it before every SDK call**

`src/adapters/agent/privilege-guard.ts`:

```ts
/**
 * F9 runtime guard: the last check before the SDK starts an agent. The static rules
 * (F9-no-agent-privilege, F9-agent-options-explicit) keep these spellings out of the rest of src/;
 * this file is on their allowlist because it has to name what it refuses.
 */
const GITHUB_TOKENS = [
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "GH_ENTERPRISE_TOKEN",
  "GITHUB_ENTERPRISE_TOKEN",
];

export interface GuardedOptions {
  readonly permissionMode?: string;
  readonly allowDangerouslySkipPermissions?: boolean;
  readonly env?: Readonly<Record<string, string | undefined>>;
}

/** Throws (a bug, not an expected failure) when options would give an agent a bypass or a token. */
export function assertAgentOptions(options: GuardedOptions): void {
  if (options.permissionMode === "bypassPermissions" || options.allowDangerouslySkipPermissions) {
    throw new Error("F9: refusing to start an agent with permission checks bypassed");
  }
  const leaked = GITHUB_TOKENS.filter((key) => options.env?.[key] !== undefined);
  if (leaked.length > 0) {
    throw new Error(
      `F9: refusing to pass ${leaked.join(", ")} to an agent; build env with agentEnv()`,
    );
  }
}
```

In `src/adapters/agent/agent-sdk-runner.ts`, add the import after `import { type Collected, failure, ZERO_USAGE } from "./agent-failure";`:

```ts
import { assertAgentOptions } from "./privilege-guard";
```

and make the first line of `execute(…)` the guard:

```ts
  ): Promise<Result<{ result: Success; usage: AgentUsage }, AgentFailure>> {
    assertAgentOptions({ ...options, env: this.env });
    const startedAt = Date.now();
```

```bash
bun test src/adapters/agent 2>&1 | grep -E '\(fail\)|^\s*[0-9]+ (pass|fail)'
bun run typecheck
```

Expected: `60 pass`, `0 fail`; typecheck clean.

- [ ] **Step 7: Prove the tests bite**

```bash
cp src/adapters/agent/agent-sdk-runner.ts "$TMPDIR/runner.ts.bak"
sed -i '' '/^    assertAgentOptions({ ...options, env: this.env });$/d' src/adapters/agent/agent-sdk-runner.ts
bun test src/adapters/agent/agent-sdk-runner.test.ts -t "refuses to start" 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
cp "$TMPDIR/runner.ts.bak" src/adapters/agent/agent-sdk-runner.ts
sed -i '' 's/^  const env: Record<string, string> = {};/  const env = { ...source } as Record<string, string>;/' src/adapters/agent/agent-sdk-runner.ts
bun test src/adapters/agent/agent-sdk-runner.test.ts -t "F9: never" 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
cp "$TMPDIR/runner.ts.bak" src/adapters/agent/agent-sdk-runner.ts
grep -c 'assertAgentOptions' src/adapters/agent/agent-sdk-runner.ts
bun test src/adapters/agent 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: without the guard call, `0 pass` / `1 fail`; with a leaky `agentEnv`, `0 pass` / `1 fail`; after restoring from the backup, `2` (import and call) and `60 pass` / `0 fail`. (Restore from the backup, not `git checkout`, which would discard Step 6.)

- [ ] **Step 8: Run the definition of done**

```bash
bun run format && git add tools/arch/rules/f9-no-agent-privilege.yml tools/arch/rules/f9-agent-options-explicit.yml \
  tools/arch/rule-tests/f9-no-agent-privilege-test.yml tools/arch/rule-tests/f9-agent-options-explicit-test.yml \
  src/adapters/agent/privilege-guard.ts src/adapters/agent/privilege-guard.test.ts \
  src/adapters/agent/agent-sdk-runner.ts src/adapters/agent/agent-sdk-runner.test.ts && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(arch): enforce F9 — static rules, runtime guard, token regression tests" -- \
  tools/arch/rules/f9-no-agent-privilege.yml tools/arch/rules/f9-agent-options-explicit.yml \
  tools/arch/rule-tests/f9-no-agent-privilege-test.yml tools/arch/rule-tests/f9-agent-options-explicit-test.yml \
  src/adapters/agent/privilege-guard.ts src/adapters/agent/privilege-guard.test.ts \
  src/adapters/agent/agent-sdk-runner.ts src/adapters/agent/agent-sdk-runner.test.ts
```

---

### Task 2: F5 evasion hardening

**Files:**
- Modify: `tools/arch/rules/f5-io-only-in-adapters.yml`, `tools/arch/rule-tests/f5-io-only-in-adapters-test.yml`

- [ ] **Step 1: Replace the rule test**

`tools/arch/rule-tests/f5-io-only-in-adapters-test.yml` (the existing cases, plus a valid block after `notBun.spawn` and the evasion cases at the end):

```yaml
id: F5-io-only-in-adapters
valid:
  - 'import type { Subprocess } from "bun";'
  - 'import type { Stats } from "node:fs";'
  - 'export type { Stats } from "node:fs";'
  - 'let p: Bun.Subprocess;'
  - 'type Spawn = typeof Bun.spawn;'
  - 'import { join } from "node:path";'
  - 'const x = myProcess.env;'
  - 'const b = notBun.spawn(["ls"]);'
  # Type positions, harmless members, and locals that happen to be named `process`
  - 'type B = typeof Bun;'
  - 'type G = typeof globalThis;'
  - 'const clone = globalThis.structuredClone;'
  - 'const argv = process.argv;'
  - 'import type { UserInfo } from "node:os";'
  - 'const process = makeProcess();'
  - 'function stop(process: Proc) { return process.pid; }'
  - 'const run = (process?: Proc) => process?.pid;'
  - 'const m = await import("./module");'
  - 'type F = Function;'
invalid:
  # Bun runtime APIs, any member
  - 'Bun.spawn(["ls"]);'
  - 'Bun.spawnSync(["ls"]);'
  - 'await Bun.$`ls`;'
  - 'Bun.file("x");'
  - 'await Bun.write("x", "y");'
  - 'Bun.serve({ fetch() {} });'
  - 'Bun.connect({});'
  - 'Bun.listen({});'
  - 'const e = Bun.env;'
  - 'const s = Bun.stdin;'
  - 'const run = Bun.spawn;'
  - 'globalThis.Bun.spawn(["ls"]);'
  - 'const { spawn } = Bun;'
  - 'let { $ } = Bun;'
  - 'var { file } = Bun;'
  # "bun" module value imports
  - 'import { spawn } from "bun";'
  - 'import { $ } from "bun";'
  - 'import * as bun from "bun";'
  - 'export { spawn } from "bun";'
  - 'const bun = require("bun");'
  - 'const bun = await import("bun");'
  # process
  - 'const e = process.env;'
  - 'const e = process["env"];'
  - "const e = process['env'];"
  - 'const { env } = process;'
  - 'const p = globalThis.process;'
  - 'import process from "process";'
  - 'import { env } from "node:process";'
  - 'import { env } from "process";'
  - 'const p = require("node:process");'
  - 'const p = await import("process");'
  # fetch, filesystem, network, child processes
  - 'await fetch("https://x");'
  - 'await globalThis.fetch("https://x");'
  - 'import { readFileSync } from "node:fs";'
  - 'import { readFile } from "fs/promises";'
  - 'import { Database } from "bun:sqlite";'
  - 'import { spawn } from "child_process";'
  - 'const fs = require("fs");'
  - 'const fs = await import("node:fs");'
  - 'import fs = require("fs");'
  - 'export * from "node:fs";'
  # Evasion: aliasing a global, computed or optional access, the os module
  - 'const b = Bun;'
  - 'const run = (Bun as any).spawn;'
  - 'use(Bun);'
  - 'const p = process;'
  - 'const g = globalThis;'
  - 'const { process: p } = globalThis;'
  - 'const e = globalThis["process"];'
  - "const b = globalThis['Bun'];"
  - 'const x = globalThis[name];'
  - 'const p = globalThis?.process;'
  - 'const p = global.process;'
  - 'const f = window.fetch;'
  - 'const e = import.meta.env;'
  - 'import { homedir } from "node:os";'
  - 'import { userInfo } from "os";'
  - 'import * as os from "node:os";'
  - 'const os = require("os");'
  - 'const os = await import("node:os");'
  # Dynamic code and module loading the rule cannot see through
  - 'const m = await import(name);'
  - 'const m = require(`./${name}`);'
  - 'const r = eval(src);'
  - 'const r = (0, eval)(src);'
  - 'const f = Function("return process")();'
  - 'const f = new Function("x", body);'
  # Network and threads
  - 'const w = new Worker("./w.ts");'
  - 'const ws = new WebSocket(url);'
```

- [ ] **Step 2: Run it to see it fail**

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep -E '^(PASS|FAIL) F5'
```

Expected: `FAIL F5-io-only-in-adapters  .............Pass × 59, Missing × 26..............`

- [ ] **Step 3: Replace the rule**

`tools/arch/rules/f5-io-only-in-adapters.yml` (new: the first four `any` branches, `os` in the three module regexes, and the `F5:` message prefix with the rename hint):

```yaml
id: F5-io-only-in-adapters
language: TypeScript
severity: error
message: "F5: I/O belongs in src/adapters. Define a port in the context and inject an adapter from main.ts. (A local variable named process, Bun or global trips this too: rename it, e.g. proc.)"
files:
  - "src/**/*.ts"
ignores:
  - "src/adapters/**"
  - "src/testing/**"
  - "src/main.ts"
  - "src/cli.ts"
  - "src/**/*.test.ts"
# Module specifiers that grant I/O. Keep the three copies of this regex below in sync.
#   bun | bun:sqlite | (node:)?fs | fs/promises | child_process | net | http | https | dns | tls
#   | dgram | http2 | worker_threads | process | os (homedir, userInfo, hostname read the machine)
rule:
  any:
    # A bare global used as a value (aliasing, call arguments, computed access such as
    # globalThis["process"], (0, eval)) would bypass the member checks below. Members
    # (process.argv, globalThis.structuredClone), type positions (typeof Bun) and declarations of
    # locals with these names are not values of the global.
    - all:
        - kind: identifier
          regex: '^(Bun|process|globalThis|global|eval|Function)$'
        - not: { inside: { kind: member_expression, field: object } }
        - not: { inside: { kind: nested_type_identifier } }
        - not: { inside: { kind: type_query, stopBy: end } }
        - not: { inside: { kind: variable_declarator, field: name } }
        - not: { inside: { any: [{ kind: required_parameter }, { kind: optional_parameter }], field: pattern } }
    # I/O reached through a global object, including optional chaining (globalThis?.process)
    - kind: member_expression
      all:
        - has: { field: object, regex: '^(globalThis|global|window|self)$' }
        - has: { field: property, regex: '^(process|Bun|fetch|require|eval|Function|Worker|WebSocket)$' }
    - pattern: import.meta.env
    # Module loading the rule cannot read: a computed specifier
    - all:
        - any:
            - pattern: import($S)
            - pattern: require($S)
        - not: { has: { field: arguments, has: { nthChild: 1, kind: string } } }
    - kind: new_expression
      has: { field: constructor, regex: '^(Worker|SharedWorker|WebSocket|EventSource|XMLHttpRequest)$' }
    # Every runtime member of the Bun global (Bun.spawn, Bun.$, Bun.file, Bun.env, ...).
    # Type positions (`Bun.Subprocess`, `typeof Bun.spawn`) are not member expressions at runtime.
    - all:
        - kind: member_expression
        - has:
            field: object
            any:
              - regex: '^Bun$'
                kind: identifier
              - pattern: globalThis.Bun
        - not:
            inside:
              kind: type_query
              stopBy: end
    - pattern: const { $$$ } = Bun
    - pattern: let { $$$ } = Bun
    - pattern: var { $$$ } = Bun
    - pattern: fetch($$$)
    - pattern: globalThis.fetch($$$)
    - pattern: globalThis.process
    - pattern: process.env
    - pattern: process["env"]
    - pattern: process['env']
    - pattern: const { $$$ } = process
    - pattern: let { $$$ } = process
    - pattern: var { $$$ } = process
    - all:
        - any:
            - pattern: import($S)
            - pattern: require($S)
        - has:
            field: arguments
            kind: arguments
            has:
              kind: string
              regex: '^["''](bun|bun:sqlite|(node:)?(fs|fs/promises|child_process|net|http|https|dns|tls|dgram|http2|worker_threads|process|os))["'']$'
    - all:
        - any:
            - kind: import_statement
            - kind: export_statement
        - has:
            field: source
            kind: string
            regex: '^["''](bun|bun:sqlite|(node:)?(fs|fs/promises|child_process|net|http|https|dns|tls|dgram|http2|worker_threads|process|os))["'']$'
        - not:
            regex: '^(import|export)\s+type\s'
    - kind: import_require_clause
      has:
        field: source
        kind: string
        regex: '^["''](bun|bun:sqlite|(node:)?(fs|fs/promises|child_process|net|http|https|dns|tls|dgram|http2|worker_threads|process|os))["'']$'
```

- [ ] **Step 4: Rule test passes; nothing legitimate fires; evasions fail in a domain file**

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep -E 'F5|result'
./node_modules/.bin/ast-grep scan 2>&1 | grep -c '^error'
for probe in 'const b = Bun; export const f = () => b.spawn(["ls"]);' 'export const e = globalThis?.process;' \
             'export const h = (0, eval)("1");' 'export const m = (n: string) => import(n);'; do
  echo "$probe" > src/contexts/platform/domain/zz-probe.ts
  ./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "exit=$?"
done
rm src/contexts/platform/domain/zz-probe.ts
```

Expected: `PASS F5-io-only-in-adapters  ....................Pass × 85.....................`, `test result: ok. 8 passed; 0 failed;`; `0`; `exit=1` four times.

- [ ] **Step 5: Run the definition of done**

```bash
bun run format && git add tools/arch/rules/f5-io-only-in-adapters.yml tools/arch/rule-tests/f5-io-only-in-adapters-test.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(arch): F5 catches aliased globals, optional and computed access, eval, workers and node:os" -- \
  tools/arch/rules/f5-io-only-in-adapters.yml tools/arch/rule-tests/f5-io-only-in-adapters-test.yml
```

---

### Task 3: Rules that guard themselves — meta-test, dependency-cruiser fixtures, CODEOWNERS

**Files:**
- Create: `tools/arch/rule-catalog.ts`, `tools/arch/meta.test.ts`, `tools/arch/depcruise-rules.test.ts`, `.github/CODEOWNERS`
- Modify: `.dependency-cruiser.cjs`, `package.json`, and the rules `f5-io-only-in-adapters.yml`, `f6-agent-sdk-only-in-adapter.yml`, `f8-tests-no-real-home.yml`, `f10-github-writes-only-in-writer.yml`, `f10-github-writes-only-in-writer-tsx.yml`, `dashboard-no-shell-from-data.yml`

- [ ] **Step 1: Write the meta-test**

`tools/arch/meta.test.ts` (`PINNED` and `ARCH_STEPS` grow in Tasks 4 and 5):

```ts
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import {
  isRatcheted,
  loadRules,
  loadRuleTests,
  ROOT,
  type RuleDoc,
  trackedFiles,
} from "./rule-catalog";

const rules = await loadRules();
const tests = await loadRuleTests();
const tracked = await trackedFiles();
const architecture = await Bun.file(join(ROOT, "docs/architecture.md")).text();
const baselineFile = Bun.file(join(ROOT, "tools/arch/findings-baseline.json"));
const baseline: Record<string, Record<string, number>> = (await baselineFile.exists())
  ? await baselineFile.json()
  : {};
const archScript: string = (await Bun.file(join(ROOT, "package.json")).json()).scripts.arch;

/**
 * The rule set, which rules are ratcheted, and every allowlist (`ignores`). A change here widens or
 * narrows what `bun run arch` enforces, so it is reviewed by the CODEOWNERS of tools/arch (ADR-0008).
 */
const PINNED: Record<string, { ratchet: boolean; ignores: string[] }> = {
  "F5-io-only-in-adapters": {
    ratchet: false,
    ignores: ["src/adapters/**", "src/testing/**", "src/main.ts", "src/cli.ts", "src/**/*.test.ts"],
  },
  "F6-agent-sdk-only-in-adapter": { ratchet: false, ignores: ["src/adapters/agent/**"] },
  "F8-tests-no-real-home": { ratchet: false, ignores: ["src/testing/test-env.test.ts"] },
  "F9-agent-options-explicit": { ratchet: false, ignores: ["**/*.test.ts"] },
  "F9-no-agent-privilege": {
    ratchet: false,
    ignores: ["**/*.test.ts", "src/adapters/github/**", "src/adapters/agent/privilege-guard.ts"],
  },
  "F10-github-writes-only-in-writer": {
    ratchet: false,
    ignores: [
      "src/adapters/github/gh-github-writer.ts",
      "src/adapters/github/gh-github-writer.test.ts",
    ],
  },
  "F10-github-writes-only-in-writer-tsx": {
    ratchet: false,
    ignores: [
      "src/adapters/github/gh-github-writer.ts",
      "src/adapters/github/gh-github-writer.test.ts",
    ],
  },
  "dashboard-no-shell-from-data": {
    ratchet: false,
    ignores: ["dashboard/**/*.test.ts", "dashboard/src/**"],
  },
};

/** Every checker `bun run arch` must run. */
const ARCH_STEPS = [
  "depcruise src --config .dependency-cruiser.cjs",
  "ast-grep scan",
  "ast-grep test --skip-snapshot-tests --include-off",
  "bun tools/arch/size-ratchet.ts",
  "bun tools/arch/workflow-injection.ts",
  "bun tools/arch/workflow-fail-closed.ts",
];

// A fix names an action. Extend the list when a new rule needs another verb.
const FIX_VERB =
  /\b(use|move|add|pass|call|run|define|inject|split|fix|keep|port|download|replace|remove|build|rename|route|wrap|give)\b/i;
/** "F10-github-writes-…" → "f10"; "dashboard-no-shell-…" → "dashboard". */
const family = (r: RuleDoc) => r.id.split("-")[0]?.toLowerCase() ?? "";
/** GitHub's heading anchors: lower case, punctuation dropped, spaces to hyphens. */
const anchors = new Set(
  [...architecture.matchAll(/^#+\s+(.+)$/gm)].map((m) =>
    (m[1] ?? "")
      .toLowerCase()
      .replace(/[^\w\s-]/g, "")
      .trim()
      .replace(/\s+/g, "-"),
  ),
);
const matchesTracked = (globs: readonly string[]) =>
  tracked.some((f) => globs.some((g) => new Bun.Glob(g).match(f)));

test("the rule set and the ratcheted rules are exactly the pinned ones", () => {
  expect(rules.map((r) => r.id).sort()).toEqual(Object.keys(PINNED).sort());
  expect(
    rules
      .filter(isRatcheted)
      .map((r) => r.id)
      .sort(),
  ).toEqual(
    Object.entries(PINNED)
      .filter(([, p]) => p.ratchet)
      .map(([id]) => id)
      .sort(),
  );
});

describe("every fitness rule", () => {
  for (const rule of rules) {
    describe(rule.id, () => {
      test("allowlist (ignores) matches the pinned snapshot", () => {
        expect([...(rule.ignores ?? [])]).toEqual(PINNED[rule.id]?.ignores ?? ["<not pinned>"]);
      });

      test("has exactly one rule test with at least one valid and one invalid case", () => {
        const found = tests.filter((t) => t.id === rule.id);
        expect(found.map((t) => t.file)).toHaveLength(1);
        expect(found[0]?.valid?.length ?? 0).toBeGreaterThan(0);
        expect(found[0]?.invalid?.length ?? 0).toBeGreaterThan(0);
      });

      test("message starts with its rule family and names a fix", () => {
        const message = rule.message ?? "";
        expect(message.toLowerCase().startsWith(`${family(rule)}:`)).toBe(true);
        expect(message).toMatch(FIX_VERB);
      });

      test("is either enforced (error) or ratcheted (off with metadata.ratchet)", () => {
        expect(rule.severity === "error" || isRatcheted(rule)).toBe(true);
      });

      test("names an owner and a docs anchor in docs/architecture.md", () => {
        expect(rule.metadata?.owner ?? "").toMatch(/^@[\w-]+$/);
        const [path, anchor] = (rule.metadata?.docs ?? "").split("#");
        expect(path).toBe("docs/architecture.md");
        expect(anchors.has(anchor ?? "")).toBe(true);
      });

      test("its files globs match at least one tracked file (or it says why not)", () => {
        if (rule.metadata?.preemptive) return;
        expect(matchesTracked(rule.files ?? [])).toBe(true);
      });

      if (isRatcheted(rule)) {
        test("has a non-empty baseline (when it reaches zero, promote it to severity: error)", () => {
          expect(Object.keys(baseline[rule.id] ?? {}).length).toBeGreaterThan(0);
        });
      }
    });
  }
});

test("every rule test belongs to a rule (ast-grep silently skips orphans)", () => {
  const ids = new Set(rules.map((r) => r.id));
  expect(tests.filter((t) => !ids.has(t.id)).map((t) => t.file)).toEqual([]);
});

test("no rule is suppressed in place (no ast-grep ignore comment in src, dashboard, scripts or tools)", async () => {
  const marker = ["ast", "grep", "ignore"].join("-");
  const roots = ["src/", "dashboard/", "scripts/", "tools/"];
  const hits: string[] = [];
  for (const f of tracked.filter((f) => roots.some((r) => f.startsWith(r)))) {
    if ((await Bun.file(join(ROOT, f)).text()).includes(marker)) hits.push(f);
  }
  expect(hits).toEqual([]);
});

test("bun run arch runs every checker", () => {
  for (const step of ARCH_STEPS) expect(archScript).toContain(step);
});
```

- [ ] **Step 2: Write the dependency-cruiser fixture test**

`tools/arch/depcruise-rules.test.ts` (Task 5 adds the dashboard config and its fixtures). Fixtures are written into a fresh temp directory and cruised with the API (`validate: true`, `baseDir` set to the realpath of the temp dir: macOS `/var` is a symlink and unresolved paths break `baseDir`):

```ts
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { cruise, type IForbiddenRuleType } from "dependency-cruiser";

/**
 * Each dependency-cruiser rule must fire on a minimal fixture, so a typo in a path regex cannot
 * silently disable it. The first file of a fixture is the one whose import violates the rule.
 * Adding a rule without a fixture fails "every rule has a fixture".
 */
const FIXTURES: Record<string, Record<string, string>> = {
  "F1-domain-is-pure": {
    "src/contexts/a/domain/pure.ts": 'import "../application/svc";',
    "src/contexts/a/application/svc.ts": "export {};",
  },
  "F1-domain-no-node-core": { "src/contexts/a/domain/core.ts": 'import "node:fs";' },
  "F1-kernel-is-pure": {
    "src/shared/kernel/k.ts": 'import "../../adapters/x/ad";',
    "src/adapters/x/ad.ts": "export {};",
  },
  "F2-application-no-adapters": {
    "src/contexts/a/application/uses-adapter.ts": 'import "../../../adapters/x/ad";',
    "src/adapters/x/ad.ts": "export {};",
  },
  "F3-contexts-via-index": {
    "src/contexts/b/application/reach.ts": 'import "../../a/domain/model";',
    "src/contexts/a/domain/model.ts": "export {};",
  },
  "F3-outsiders-via-index": {
    "src/cli/cmd.ts": 'import "../contexts/a/domain/model";',
    "src/contexts/a/domain/model.ts": "export {};",
  },
  "F3-no-test-fakes-in-production": {
    "src/adapters/x/uses-fake.ts": 'import "../../testing/fake";',
    "src/testing/fake.ts": "export {};",
  },
  "F4-no-cycles": {
    "src/adapters/y/c1.ts": 'import "./c2";',
    "src/adapters/y/c2.ts": 'import "./c1";',
  },
};

/** Config file → the directory it cruises in `bun run arch`. */
const CONFIGS: Record<string, string> = {
  ".dependency-cruiser.cjs": "src",
};
const FIX_VERB =
  /\b(use|move|add|pass|call|run|define|inject|split|fix|keep|port|replace|remove|break|talk|depend)\b/i;

async function violations(rules: IForbiddenRuleType[], dir: string): Promise<[string, string][]> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "depcruise-fixture-")));
  for (const rule of rules) {
    for (const [file, text] of Object.entries(FIXTURES[rule.name ?? ""] ?? {})) {
      mkdirSync(dirname(join(root, file)), { recursive: true });
      writeFileSync(join(root, file), text);
    }
  }
  const result = await cruise([dir], {
    validate: true,
    ruleSet: { forbidden: rules },
    baseDir: root,
    tsPreCompilationDeps: true,
  });
  const output = result.output as unknown as {
    summary: { violations: { rule: { name: string }; from: string }[] };
  };
  return output.summary.violations.map((v) => [v.rule.name, v.from]);
}

for (const [config, dir] of Object.entries(CONFIGS)) {
  const rules: IForbiddenRuleType[] = require(`../../${config}`).forbidden;
  describe(config, () => {
    test("every rule has a fixture", () => {
      expect(rules.map((r) => r.name).filter((n) => !n || !FIXTURES[n])).toEqual([]);
    });

    test("every rule fires on its fixture", async () => {
      const found = await violations(rules, dir);
      for (const rule of rules) {
        const trigger = Object.keys(FIXTURES[rule.name ?? ""] ?? {})[0];
        expect(found).toContainEqual([rule.name ?? "", trigger ?? ""]);
      }
    });

    test("every comment starts with its rule family and names a fix", () => {
      for (const rule of rules) {
        const fam = (rule.name ?? "").split("-")[0];
        expect(rule.comment ?? "").toStartWith(`${fam}:`);
        expect(rule.comment ?? "").toMatch(FIX_VERB);
      }
    });
  });
}
```

- [ ] **Step 3: Run both to see them fail**

```bash
bun test tools/arch/meta.test.ts tools/arch/depcruise-rules.test.ts 2>&1 | grep -E 'error:|\(fail\)|^\s*[0-9]+ (pass|fail)'
```

Expected: `Cannot find module './rule-catalog'`, and `(fail) .dependency-cruiser.cjs > every comment starts with its rule family and names a fix` (the fixtures already fire for all eight rules: `2 pass`).

- [ ] **Step 4: Write the shared loader**

`tools/arch/rule-catalog.ts` (Task 4's scanner reuses `trackedFiles()`):

```ts
import { join, resolve } from "node:path";
import { Glob } from "bun";
import { parse } from "yaml";

export const ROOT = resolve(import.meta.dir, "../..");
const RULES_DIR = "tools/arch/rules";
const RULE_TESTS_DIR = "tools/arch/rule-tests";

/** One ast-grep rule file in tools/arch/rules. */
export interface RuleDoc {
  readonly file: string;
  readonly id: string;
  readonly severity?: string;
  readonly message?: string;
  readonly files?: readonly string[];
  readonly ignores?: readonly string[];
  readonly metadata?: {
    readonly ratchet?: boolean;
    readonly owner?: string;
    readonly docs?: string;
    /** Why the rule's `files` match nothing yet (it guards against a file type appearing). */
    readonly preemptive?: string;
  };
}
/** One ast-grep rule-test file in tools/arch/rule-tests. */
export interface RuleTestDoc {
  readonly file: string;
  readonly id: string;
  readonly valid?: readonly string[];
  readonly invalid?: readonly string[];
}

async function loadDir<T>(dir: string, root: string): Promise<(T & { file: string })[]> {
  const out: (T & { file: string })[] = [];
  for await (const name of new Glob("*.{yml,yaml}").scan(join(root, dir))) {
    const file = `${dir}/${name}`;
    out.push({ ...(parse(await Bun.file(join(root, file)).text()) as T), file });
  }
  return out.sort((a, b) => a.file.localeCompare(b.file));
}

export const loadRules = (root = ROOT) => loadDir<RuleDoc>(RULES_DIR, root);
export const loadRuleTests = (root = ROOT) => loadDir<RuleTestDoc>(RULE_TESTS_DIR, root);

/** Ratcheted rules are off for plain `ast-grep scan`; tools/arch/ast-scan.ts counts them. */
export const isRatcheted = (r: RuleDoc): boolean =>
  r.severity === "off" && r.metadata?.ratchet === true;

/**
 * Files git knows about: tracked plus untracked-but-not-ignored, minus deleted ones. Scans use this
 * list instead of walking directories, so .gitignore/.ignore files cannot hide a tracked file.
 */
export async function trackedFiles(root = ROOT): Promise<string[]> {
  const proc = Bun.spawnSync(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"],
    { cwd: root },
  );
  if (proc.exitCode !== 0) throw new Error(`git ls-files failed: ${proc.stderr.toString()}`);
  const names = proc.stdout.toString().split("\0").filter(Boolean);
  const present = await Promise.all(names.map((f) => Bun.file(join(root, f)).exists()));
  return names.filter((_, i) => present[i]).sort();
}
```

```bash
bun test tools/arch/meta.test.ts 2>&1 | grep -E '\(fail\)|^\s*[0-9]+ (pass|fail)' | sed 's/ \[.*//'
```

Expected: 10 failures. Owner/docs metadata is missing on `F5`, `F6`, `F8`, `F10`, `F10-…-tsx` and `dashboard-no-shell-from-data`. The `F6` and `F8` messages do not start with their family. The `F10-…-tsx` files match no tracked file. `bun run arch runs every checker` fails (no `--include-off`). 42 pass.

- [ ] **Step 5: Give every existing rule an owner and a docs anchor, and fix the two messages**

In each of `tools/arch/rules/f5-io-only-in-adapters.yml`, `f6-agent-sdk-only-in-adapter.yml`, `f8-tests-no-real-home.yml`, `f10-github-writes-only-in-writer.yml` and `dashboard-no-shell-from-data.yml`, add directly after the `message:` line:

```yaml
metadata: { owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
```

In `tools/arch/rules/f10-github-writes-only-in-writer-tsx.yml`, add after its `message:` line:

```yaml
metadata:
  owner: "@sethdford"
  docs: "docs/architecture.md#fitness-rules"
  preemptive: "src has no .tsx files yet; this keeps a rename to .tsx from escaping F10"
```

In `f6-agent-sdk-only-in-adapter.yml` replace `message: "Use the AgentRunner port.` with `message: "F6: Use the AgentRunner port.`; in `f8-tests-no-real-home.yml` replace `message: "Tests must use createTestEnv()` with `message: "F8: Tests must use createTestEnv()`.

In `package.json`'s `arch` script replace `ast-grep test --skip-snapshot-tests &&` with `ast-grep test --skip-snapshot-tests --include-off &&`.

- [ ] **Step 6: Prefix the dependency-cruiser comments**

Replace `.dependency-cruiser.cjs` with (comments only: each starts with its family and names a fix):

```js
/** Architecture fitness rules F1–F4 (spec §3.3). Messages tell agents how to fix. */
module.exports = {
  forbidden: [
    {
      name: "F1-domain-is-pure",
      comment:
        "F1: domain/ may import only its own domain and src/shared/kernel. Move I/O behind a port in application/.",
      severity: "error",
      from: { path: "^src/contexts/([^/]+)/domain/" },
      to: { path: "^src/", pathNot: ["^src/contexts/$1/domain/", "^src/shared/kernel/"] },
    },
    {
      name: "F1-domain-no-node-core",
      comment: "F1: domain/ must not use Node/Bun built-ins. Depend on a port instead.",
      severity: "error",
      from: { path: "^src/contexts/[^/]+/domain/" },
      to: { dependencyTypes: ["core"] },
    },
    {
      name: "F1-kernel-is-pure",
      comment: "F1: src/shared/kernel holds types and pure helpers only. Move anything else into a context or an adapter.",
      severity: "error",
      from: { path: "^src/shared/kernel/" },
      to: { path: "^src/", pathNot: "^src/shared/kernel/" },
    },
    {
      name: "F2-application-no-adapters",
      comment: "F2: application/ depends on ports, never on adapters or cli. Inject the adapter from main.ts.",
      severity: "error",
      from: { path: "^src/contexts/[^/]+/application/" },
      to: { path: "^src/(adapters|cli)/" },
    },
    {
      name: "F3-contexts-via-index",
      comment: "F3: import another context only through src/contexts/<ctx>/index.ts; add what you need to its exports.",
      severity: "error",
      from: { path: "^src/contexts/([^/]+)/" },
      to: { path: "^src/contexts/[^/]+/", pathNot: ["^src/contexts/$1/", "^src/contexts/[^/]+/index\\.ts$"] },
    },
    {
      name: "F3-outsiders-via-index",
      comment:
        "F3: every file outside src/contexts (cli, main.ts, adapters, testing, ...) imports a context only through its index.ts; add what you need to its exports.",
      severity: "error",
      from: { path: "^src/", pathNot: "^src/contexts/" },
      to: { path: "^src/contexts/[^/]+/.+", pathNot: "^src/contexts/[^/]+/index\\.ts$" },
    },
    {
      name: "F3-no-test-fakes-in-production",
      comment: "F3: production code must not import src/testing; inject fakes only from tests.",
      severity: "error",
      from: { path: "^src/", pathNot: "^src/testing/" },
      to: { path: "^src/testing/" },
    },
    {
      name: "F4-no-cycles",
      comment: "F4: break the cycle by moving the shared piece into a port or the kernel.",
      severity: "error",
      from: {},
      to: { circular: true },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    exclude: { path: "\\.test\\.ts$" },
    tsConfig: { fileName: "tsconfig.json" },
    tsPreCompilationDeps: true,
  },
};
```

```bash
bun test tools/arch/meta.test.ts tools/arch/depcruise-rules.test.ts 2>&1 | grep -E '\(fail\)|^\s*[0-9]+ (pass|fail)'
./node_modules/.bin/ast-grep test --skip-snapshot-tests --include-off 2>&1 | grep result
```

Expected: `55 pass`, `0 fail` (52 meta + 3 fixture tests); `test result: ok. 8 passed; 0 failed;`.

- [ ] **Step 7: Prove each meta-check bites**

```bash
# an orphan rule test
sed 's/^id: .*/id: ZZ-orphan/' tools/arch/rule-tests/f6-agent-sdk-only-in-adapter-test.yml > tools/arch/rule-tests/zz-orphan-test.yml
bun test tools/arch/meta.test.ts 2>&1 | grep '(fail)'; rm tools/arch/rule-tests/zz-orphan-test.yml
# a suppression comment
cp scripts/lib/compat.sh "$TMPDIR/compat.bak"; echo 'eval "$1" # ast-grep-ignore' >> scripts/lib/compat.sh
bun test tools/arch/meta.test.ts 2>&1 | grep '(fail)'; cp "$TMPDIR/compat.bak" scripts/lib/compat.sh
# a widened allowlist
cp tools/arch/rules/f6-agent-sdk-only-in-adapter.yml "$TMPDIR/f6.bak"; perl -0pi -e 's/^ignores:\n/ignores:\n  - "src\/cli\/**"\n/m' tools/arch/rules/f6-agent-sdk-only-in-adapter.yml
bun test tools/arch/meta.test.ts 2>&1 | grep '(fail)'; cp "$TMPDIR/f6.bak" tools/arch/rules/f6-agent-sdk-only-in-adapter.yml
# a dependency-cruiser rule whose path regex no longer matches
cp .dependency-cruiser.cjs "$TMPDIR/dc.bak"
sed -i '' 's#from: { path: "^src/contexts/\[^/\]+/application/" },#from: { path: "^src/context/[^/]+/application/" },#' .dependency-cruiser.cjs
bun test tools/arch/depcruise-rules.test.ts 2>&1 | grep '(fail)'; cp "$TMPDIR/dc.bak" .dependency-cruiser.cjs
git status --short scripts tools/arch/rules .dependency-cruiser.cjs
```

Expected, in order:
- `(fail) every rule test belongs to a rule (ast-grep silently skips orphans)`
- `(fail) no rule is suppressed in place (no ast-grep ignore comment in src, dashboard, scripts or tools)`
- `(fail) every fitness rule > F6-agent-sdk-only-in-adapter > allowlist (ignores) matches the pinned snapshot`
- `(fail) .dependency-cruiser.cjs > every rule fires on its fixture`
- then only this task's own edits in `git status` (no `scripts/` change).

- [ ] **Step 8: Put the fitness functions under the maintainer's review**

`.github/CODEOWNERS`:

```text
# Fitness functions and their baselines (ADR-0008). A change to a rule, an allowlist or a baseline
# changes what every agent is allowed to write, so it needs the maintainer's review.
/tools/arch/                      @sethdford
/sgconfig.yml                     @sethdford
/.dependency-cruiser.cjs          @sethdford
/.dependency-cruiser.dashboard.cjs @sethdford
/package.json                     @sethdford
/.github/CODEOWNERS               @sethdford
```

(It takes effect for merges once the maintainer enables "Require review from Code Owners" on `main`; Task 8 lists that as a hand-off item.)

- [ ] **Step 9: Run the definition of done**

```bash
bun run format && git add tools/arch/rule-catalog.ts tools/arch/meta.test.ts tools/arch/depcruise-rules.test.ts .github/CODEOWNERS \
  .dependency-cruiser.cjs package.json tools/arch/rules/f5-io-only-in-adapters.yml tools/arch/rules/f6-agent-sdk-only-in-adapter.yml \
  tools/arch/rules/f8-tests-no-real-home.yml tools/arch/rules/f10-github-writes-only-in-writer.yml \
  tools/arch/rules/f10-github-writes-only-in-writer-tsx.yml tools/arch/rules/dashboard-no-shell-from-data.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 10: Commit**

```bash
git commit -m "test(arch): rules guard themselves — meta-test, depcruise fixtures, CODEOWNERS" -- \
  tools/arch/rule-catalog.ts tools/arch/meta.test.ts tools/arch/depcruise-rules.test.ts .github/CODEOWNERS \
  .dependency-cruiser.cjs package.json tools/arch/rules/f5-io-only-in-adapters.yml tools/arch/rules/f6-agent-sdk-only-in-adapter.yml \
  tools/arch/rules/f8-tests-no-real-home.yml tools/arch/rules/f10-github-writes-only-in-writer.yml \
  tools/arch/rules/f10-github-writes-only-in-writer-tsx.yml tools/arch/rules/dashboard-no-shell-from-data.yml
```

---

### Task 4: Bash fitness (F9, F10, F11), one scanner over git's file list, and anti-laundering

**Files:**
- Create: `tools/arch/findings-ratchet.ts` + test, `tools/arch/baseline-history.ts` + test, `tools/arch/ast-scan.ts`, `tools/arch/findings-baseline.json` (generated), `tools/arch/utils/bash-{expansion,shell,text,download}.yml`; seven rules with tests: `f11-bash-no-eval-expansion`, `f11-bash-no-shell-c-expansion`, `f11-bash-no-pipe-to-shell`, `f11-bash-no-gha-expression`, `f9-bash-no-permission-bypass`, `f9-bash-claude-token-scrub`, `f10-bash-github-writes`
- Modify: `sgconfig.yml`, `package.json`, `tools/arch/meta.test.ts`, `tools/arch/rule-catalog.ts`, `tools/arch/size-ratchet.ts`, `.github/workflows/ts-check.yml`

ast-grep 0.50.0 parses bash with its built-in `Bash` grammar (checked with `ast-grep run -l bash --debug-query=cst`). The rules rely on these grammar facts:
- A command's words are `argument` children, but `has: { field: argument }` sees only the **first** one (a repeated field resolves to its first child), so the rules use plain `has`.
- `$x`, `${x}` and `$(…)` are `simple_expansion`, `expansion` and `command_substitution`, nested inside `string` for `"…"`; `'…'` is an opaque `raw_string`.
- A heredoc body is one `heredoc_body` node; `<<<` is a `herestring_redirect` child of the command; `<(…)` is a `process_substitution`.
- `"$SHELL"` as a command is a `command_name` holding a `string`.
- `${{` does not parse as an expansion: it lands in a `word`, `string_content`, `raw_string`, `heredoc_body` or `ERROR` node.

- [ ] **Step 1: Write the unit tests for the ratchet and the merge-base comparison**

`tools/arch/findings-ratchet.test.ts`:

```ts
import { expect, test } from "bun:test";
import {
  checkFindings,
  countFindings,
  type Finding,
  nextFindingsBaseline,
  parseScan,
  summaryMarkdown,
} from "./findings-ratchet";

const f = (ruleId: string, file: string, line = 1): Finding => ({
  ruleId,
  file,
  line,
  message: `${ruleId} message`,
});
const RATCHETED = ["R1", "R2"];
const current = countFindings([f("R1", "a.sh"), f("R1", "a.sh", 9), f("R2", "b.sh")], RATCHETED);

test("counts findings per rule and file, keeping every ratcheted rule as a key", () => {
  expect(current).toEqual({ R1: { "a.sh": 2 }, R2: { "b.sh": 1 } });
  expect(countFindings([f("R1", "a.sh")], RATCHETED)).toEqual({ R1: { "a.sh": 1 }, R2: {} });
});

test("parses ast-grep --json=stream output (lines are 0-based there)", () => {
  const line = JSON.stringify({
    ruleId: "R1",
    file: "a.sh",
    range: { start: { line: 4, column: 0 } },
    message: "m",
  });
  expect(parseScan(`${line}\n\n`)).toEqual([{ ruleId: "R1", file: "a.sh", line: 5, message: "m" }]);
});

test("matching counts pass; new files and growth fail", () => {
  expect(checkFindings(current, { R1: { "a.sh": 2 }, R2: { "b.sh": 1 } })).toEqual([]);
  expect(checkFindings(current, { R1: { "a.sh": 2 }, R2: {} })).toEqual([
    "R2 b.sh: 1 new finding(s). Fix them: baselined findings may only go down.",
  ]);
  expect(checkFindings(current, { R1: { "a.sh": 1 }, R2: { "b.sh": 1 } })).toEqual([
    "R1 a.sh: 2 findings (baseline 1). Fix the new one: baselined findings may only go down.",
  ]);
});

test("loose and stale entries fail so the baseline tracks reality", () => {
  expect(checkFindings(current, { R1: { "a.sh": 3 }, R2: { "b.sh": 1, "gone.sh": 4 } })).toEqual([
    "tighten baseline R1 a.sh to 2",
    "remove baseline entry R2 gone.sh (no findings left)",
  ]);
});

test("a ratcheted rule without a baseline key, or a key for another rule, fails", () => {
  expect(checkFindings(current, { R1: { "a.sh": 2 } })).toEqual([
    "R2 b.sh: 1 new finding(s). Fix them: baselined findings may only go down.",
    "R2 has no baseline entry. Seed it: bun tools/arch/ast-scan.ts --write-baseline",
  ]);
  expect(checkFindings(current, { R1: { "a.sh": 2 }, R2: { "b.sh": 1 }, R9: {} })).toEqual([
    "remove baseline entry R9 (not a ratcheted rule)",
  ]);
});

test("write mode seeds a rule the baseline does not know yet, and keeps zeroed rules as keys", () => {
  expect(nextFindingsBaseline(current, undefined, RATCHETED)).toEqual({ baseline: current });
  expect(nextFindingsBaseline(current, { R1: { "a.sh": 2 } }, RATCHETED)).toEqual({
    baseline: current,
  });
  const zeroed = countFindings([f("R1", "a.sh")], RATCHETED);
  expect(nextFindingsBaseline(zeroed, { R1: { "a.sh": 2 }, R2: { "b.sh": 1 } }, RATCHETED)).toEqual(
    { baseline: { R1: { "a.sh": 1 }, R2: {} } },
  );
});

test("write mode refuses new files and raised counts, and drops rules no longer ratcheted", () => {
  expect(
    nextFindingsBaseline(current, { R1: { "z.sh": 1 }, R2: { "b.sh": 1 } }, RATCHETED),
  ).toEqual({
    errors: ["refusing to baseline new finding R1 a.sh (2)"],
  });
  expect(
    nextFindingsBaseline(current, { R1: { "a.sh": 1 }, R2: { "b.sh": 1 } }, RATCHETED),
  ).toEqual({
    errors: ["refusing to raise baseline R1 a.sh from 1 to 2"],
  });
  expect(nextFindingsBaseline(current, { ...current, R9: { "x.sh": 1 } }, RATCHETED)).toEqual({
    baseline: current,
  });
});

test("summary lists files and findings per rule", () => {
  expect(summaryMarkdown(current)).toBe(
    "| Ratcheted rule | Files | Findings |\n|---|---|---|\n| R1 | 1 | 2 |\n| R2 | 1 | 1 |\n",
  );
});
```

`tools/arch/baseline-history.test.ts` (a throwaway git repo in a temp dir; signing and hooks are turned off locally so a developer's global git config cannot break it):

```ts
import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { baselineAt, risesAgainst } from "./baseline-history";

test("a new key or a higher count in a group the base knows is a rise", () => {
  const base = { R1: { "a.sh": 2 }, files: { "x.ts": 400 } };
  expect(risesAgainst(base, { R1: { "a.sh": 2 }, files: { "x.ts": 350 } })).toEqual([]);
  expect(risesAgainst(base, { R1: { "a.sh": 3, "b.sh": 1 }, files: { "x.ts": 400 } })).toEqual([
    "R1 a.sh rose from 2 to 3 against the base branch",
    "R1 b.sh is new against the base branch",
  ]);
});

test("a group the base does not have (a newly ratcheted rule) is not a rise", () => {
  expect(risesAgainst({ R1: {} }, { R1: {}, R2: { "a.sh": 5 } })).toEqual([]);
});

const git = (cwd: string, ...args: string[]) => {
  const p = Bun.spawnSync(["git", ...args], { cwd });
  if (p.exitCode !== 0) throw new Error(p.stderr.toString());
  return p.stdout.toString().trim();
};

test("reads the baseline at the merge base; fails closed on an unknown ref", () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "baseline-history-")));
  git(dir, "init", "-q", "-b", "main");
  git(dir, "config", "user.email", "t@example.com");
  git(dir, "config", "user.name", "t");
  git(dir, "config", "commit.gpgsign", "false");
  git(dir, "config", "core.hooksPath", "/dev/null");
  writeFileSync(join(dir, "b.json"), JSON.stringify({ R1: { "a.sh": 2 } }));
  git(dir, "add", "b.json");
  git(dir, "commit", "-qm", "base");
  git(dir, "checkout", "-qb", "feature");
  writeFileSync(join(dir, "b.json"), JSON.stringify({ R1: { "a.sh": 9 } }));
  git(dir, "commit", "-qam", "raise");
  expect(baselineAt("main", "b.json", dir)).toEqual({ R1: { "a.sh": 2 } });
  expect(baselineAt("main", "missing.json", dir)).toBeUndefined();
  expect(() => baselineAt("no-such-ref", "b.json", dir)).toThrow(/merge-base/);
});
```

```bash
bun test tools/arch/findings-ratchet.test.ts tools/arch/baseline-history.test.ts 2>&1 | grep -E 'error:|^\s*[0-9]+ (pass|fail)'
```

Expected: `Cannot find module './baseline-history'`, `Cannot find module './findings-ratchet'`, `2 fail`.

- [ ] **Step 2: Write the pure ratchet and the merge-base comparison**

`tools/arch/findings-ratchet.ts`:

```ts
/** Pure logic of the findings ratchet (ADR-0008). The CLI is tools/arch/ast-scan.ts. */

/** rule id → file → number of findings. Every ratcheted rule is a key, even at zero. */
export type Counts = Record<string, Record<string, number>>;
export interface Finding {
  readonly ruleId: string;
  readonly file: string;
  readonly line: number;
  readonly message: string;
}
type Entry = [rule: string, file: string, count: number];

function sorted(c: Counts, keep: readonly string[] = []): Counts {
  const out: Counts = {};
  for (const rule of [...new Set([...Object.keys(c), ...keep])].sort()) {
    const files = c[rule] ?? {};
    const byFile: Record<string, number> = {};
    for (const file of Object.keys(files).sort()) byFile[file] = files[file] ?? 0;
    out[rule] = byFile;
  }
  return out;
}

const entries = (c: Counts): Entry[] =>
  Object.entries(c).flatMap(([rule, files]) =>
    Object.entries(files).map(([file, n]): Entry => [rule, file, n]),
  );

export function countFindings(findings: readonly Finding[], ratcheted: readonly string[]): Counts {
  const out: Counts = {};
  for (const f of findings) {
    const byFile = out[f.ruleId] ?? {};
    byFile[f.file] = (byFile[f.file] ?? 0) + 1;
    out[f.ruleId] = byFile;
  }
  return sorted(out, ratcheted);
}

/** Parses `ast-grep scan --json=stream` (one match per line; lines are 0-based there). */
export function parseScan(stdout: string): Finding[] {
  return stdout
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => {
      const m = JSON.parse(l) as {
        ruleId: string;
        file: string;
        range: { start: { line: number } };
        message: string;
      };
      return { ruleId: m.ruleId, file: m.file, line: m.range.start.line + 1, message: m.message };
    });
}

/** Entries that are new or above their baseline, with the baseline value (if any). */
export function grown(current: Counts, baseline: Counts): [...Entry, number | undefined][] {
  return entries(sorted(current))
    .map(([rule, file, n]): [...Entry, number | undefined] => [
      rule,
      file,
      n,
      baseline[rule]?.[file],
    ])
    .filter(([, , n, base]) => base === undefined || n > base);
}

/**
 * The baseline is a ratchet: counts may only go down, every entry must match reality, every
 * ratcheted rule (the keys of `current`) has a key, and no other rule does.
 */
export function checkFindings(current: Counts, baseline: Counts): string[] {
  const growth = grown(current, baseline).map(([rule, file, n, base]) =>
    base === undefined
      ? `${rule} ${file}: ${n} new finding(s). Fix them: baselined findings may only go down.`
      : `${rule} ${file}: ${n} findings (baseline ${base}). Fix the new one: baselined findings may only go down.`,
  );
  const loose = entries(sorted(current))
    .filter(([rule, file, n]) => n < (baseline[rule]?.[file] ?? 0))
    .map(([rule, file, n]) => `tighten baseline ${rule} ${file} to ${n}`);
  const stale = entries(sorted(baseline))
    .filter(([rule, file]) => rule in current && !current[rule]?.[file])
    .map(([rule, file]) => `remove baseline entry ${rule} ${file} (no findings left)`);
  const unseeded = Object.keys(current)
    .filter((rule) => !(rule in baseline))
    .map(
      (rule) =>
        `${rule} has no baseline entry. Seed it: bun tools/arch/ast-scan.ts --write-baseline`,
    );
  const foreign = Object.keys(baseline)
    .filter((rule) => !(rule in current))
    .map((rule) => `remove baseline entry ${rule} (not a ratcheted rule)`);
  return [...growth, ...loose, ...stale, ...unseeded, ...foreign];
}

/**
 * Seeds a rule the baseline does not know yet; for known rules it may only tighten or prune. The
 * result has a key for every ratcheted rule (empty when it reached zero, which the meta-test turns
 * into "promote it to severity: error") and none for other rules.
 */
export function nextFindingsBaseline(
  current: Counts,
  existing: Counts | undefined,
  ratcheted: readonly string[],
): { baseline: Counts } | { errors: string[] } {
  const errors: string[] = [];
  for (const [rule, file, n] of entries(sorted(current))) {
    const known = existing?.[rule];
    const base = known?.[file];
    if (known && base === undefined) {
      errors.push(`refusing to baseline new finding ${rule} ${file} (${n})`);
    } else if (base !== undefined && n > base) {
      errors.push(`refusing to raise baseline ${rule} ${file} from ${base} to ${n}`);
    }
  }
  if (errors.length > 0) return { errors };
  const kept: Counts = {};
  for (const rule of ratcheted) kept[rule] = current[rule] ?? {};
  return { baseline: sorted(kept) };
}

/** A Markdown table of per-rule totals, for $GITHUB_STEP_SUMMARY. */
export function summaryMarkdown(current: Counts): string {
  const rows = Object.entries(sorted(current)).map(([rule, files]) => {
    const total = Object.values(files).reduce((a, b) => a + b, 0);
    return `| ${rule} | ${Object.keys(files).length} | ${total} |`;
  });
  return ["| Ratcheted rule | Files | Findings |", "|---|---|---|", ...rows, ""].join("\n");
}
```

`tools/arch/baseline-history.ts`:

```ts
/**
 * Anti-laundering for baselines (ADR-0008): compared with the merge base of a branch, no baseline
 * may gain an entry or a higher count. Used by `ast-scan.ts --against` and `size-ratchet.ts --against`.
 */
type Grouped = Record<string, Record<string, number>>;

function git(root: string, ...args: string[]): { ok: boolean; out: string; err: string } {
  const p = Bun.spawnSync(["git", ...args], { cwd: root });
  return { ok: p.exitCode === 0, out: p.stdout.toString(), err: p.stderr.toString() };
}

/** The baseline at the merge base of HEAD and `ref`; undefined when the file did not exist there. */
export function baselineAt(ref: string, path: string, root: string): Grouped | undefined {
  const base = git(root, "merge-base", "HEAD", ref);
  if (!base.ok) throw new Error(`git merge-base HEAD ${ref} failed: ${base.err.trim()}`);
  const shown = git(root, "show", `${base.out.trim()}:${path}`);
  return shown.ok ? (JSON.parse(shown.out) as Grouped) : undefined;
}

/** Entries that are new or higher than at the base, within groups the base already has. */
export function risesAgainst(base: Grouped, head: Grouped): string[] {
  const out: string[] = [];
  for (const [group, entries] of Object.entries(head)) {
    const known = base[group];
    if (!known) continue;
    for (const [key, n] of Object.entries(entries)) {
      const was = known[key];
      if (was === undefined) out.push(`${group} ${key} is new against the base branch`);
      else if (n > was)
        out.push(`${group} ${key} rose from ${was} to ${n} against the base branch`);
    }
  }
  return out;
}
```

```bash
bun run format > /dev/null; bun test tools/arch/findings-ratchet.test.ts tools/arch/baseline-history.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: `11 pass`, `0 fail`.

- [ ] **Step 3: Register the util rules; parse `scripts/sw` as Bash**

`sgconfig.yml`:

```yaml
ruleDirs:
  - tools/arch/rules
utilDirs:
  - tools/arch/utils
testConfigs:
  - testDir: tools/arch/rule-tests
# scripts/sw (the router) has no extension. Globs match the file name.
languageGlobs:
  bash: ["sw"]
```

(`languageGlobs` matches file names: `"scripts/sw"` matched nothing in the dry run, `"sw"` matched the router.)

`tools/arch/utils/bash-expansion.yml`:

```yaml
# A bash node that is, or contains, a parameter expansion or a command substitution.
id: bash-expansion
language: Bash
rule:
  any:
    - kind: simple_expansion
    - kind: expansion
    - kind: command_substitution
    - has:
        stopBy: end
        any:
          - kind: simple_expansion
          - kind: expansion
          - kind: command_substitution
```

`tools/arch/utils/bash-shell.yml`:

```yaml
# A word naming a shell: sh, bash, zsh, dash or ksh (optionally under /bin or /usr/bin), or "$SHELL".
id: bash-shell
language: Bash
rule:
  regex: '^((/usr)?(/bin/)?(ba|z|da|k)?sh|"?\$\{?SHELL\}?"?)$'
```

`tools/arch/utils/bash-text.yml`:

```yaml
# A bash node holding literal text: words, strings, heredoc bodies (comments are another kind).
# Rules match the innermost one: `matches: bash-text`, a `regex`, and `not: { has: { regex } }`.
id: bash-text
language: Bash
rule:
  any:
    - kind: heredoc_body
    - kind: raw_string
    - kind: ansi_c_string
    - kind: string
    - kind: string_content
    - kind: word
    - kind: concatenation
    - kind: ERROR
```

`tools/arch/utils/bash-download.yml`:

```yaml
# A command that downloads: curl or wget.
id: bash-download
language: Bash
rule:
  kind: command
  has: { field: name, regex: '^(curl|wget)$' }
```

- [ ] **Step 4: Write the seven bash rules and their tests**

Every bash rule carries the same `files` list (the meta-test checks this in Step 6).

`tools/arch/rule-tests/f11-bash-no-eval-expansion-test.yml`:

```yaml
id: F11-bash-no-eval-expansion
valid:
  - "eval 'set -- a b'"
  - 'eval "echo hi"'
  - 'evaluate "$x"'
  - 'echo "eval $x"'
  - 'yq eval -o=json "$file"'
  - 'source "$SCRIPT_DIR/lib/helpers.sh"'
  - 'command -v eval'
invalid:
  - 'eval "$cmd"'
  - 'eval $cmd'
  - 'eval echo "$x"'
  - 'eval "${mutations[$i]} \"$copy\""'
  - 'eval "$(ssh-agent -s)"'
  - 'eval "_v=\"\${${name}}\""'
  - "eval 'v=\"${'\"$key\"':-}\"'"
  - 'if eval "$condition"; then :; fi'
  - 'out=$(eval "$TEST_CMD" 2>&1)'
  - 'command eval "$x"'
  - 'builtin eval "$x"'
  - 'source /dev/stdin <<< "$code"'
  - '. /dev/stdin <<<"$code"'
  - 'source <(echo "$code")'
```

`tools/arch/rules/f11-bash-no-eval-expansion.yml`:

```yaml
# F11 (bash safety): eval re-parses its arguments as shell code, so any expansion in them runs
# whatever the value contains. Also: `command eval`, `builtin eval`, and `source`/`.` reading code
# from a here-string or a process substitution built from a variable. Ratcheted (tools/arch/ast-scan.ts).
# `has` takes no `field: argument` in the bash rules: a repeated field resolves to its first child only.
id: F11-bash-no-eval-expansion
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F11: eval and source re-parse text as code. Call the command directly with quoted \"$args\", use an array (\"${cmd[@]}\"), or printf -v / declare for indirect assignment."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
rule:
  kind: command
  any:
    - all:
        - any:
            - has: { field: name, regex: '^eval$' }
            - all:
                - has: { field: name, regex: '^(command|builtin)$' }
                - has: { kind: word, regex: '^eval$' }
        - has: { matches: bash-expansion }
    - all:
        - has: { field: name, regex: '^(source|\.)$' }
        - any:
            - all:
                - has: { kind: word, regex: '^/dev/(stdin|fd/0)$' }
                - has: { kind: herestring_redirect, matches: bash-expansion }
            - has: { kind: process_substitution, matches: bash-expansion }
```

`tools/arch/rule-tests/f11-bash-no-shell-c-expansion-test.yml`:

```yaml
id: F11-bash-no-shell-c-expansion
valid:
  - "bash -c 'echo hi'"
  - "bash -c 'run \"$1\"' _ \"$value\""
  - 'bash "$script" "$arg"'
  - 'bash -n "$file"'
  - 'echo "bash -c $x"'
  - "sh -c 'exit 0'"
  - "python3 -c 'import sys; print(sys.argv[1])' \"$x\""
  - 'node "$script" "$arg"'
  - 'ssh "$host" uptime'
  - 'ssh -o ConnectTimeout=5 "${user}@${host}" "uptime"'
  - "bash <<< 'echo hi'"
invalid:
  - 'bash -c "$handler_cmd"'
  - 'sh -c "echo $y"'
  - 'bash -c $cmd'
  - 'out=$(bash -c "source \"$SCRIPT_DIR/lib.sh\"; f")'
  - 'timeout "$t" bash -c "$command_str"'
  - 'zsh -lc "$cmd"'
  - '/bin/sh -c "$(cat "$f")"'
  - 'bash -ec "${steps[$i]}"'
  - '"$SHELL" -c "$cmd"'
  - 'python3 -c "import json; print(json.load(open(\"$f\")))"'
  - 'node -e "console.log($x)"'
  - 'perl -e "print $x"'
  - 'bash <<< "$cmd"'
  - 'sh <<<"$(cat "$f")"'
  - 'ssh "$host" "cd $dir && shipwright status"'
```

`tools/arch/rules/f11-bash-no-shell-c-expansion.yml`:

```yaml
# F11 (bash safety): code strings built from data. `bash -c "$cmd"` (also after a wrapper such as
# `timeout 30 bash -c`, and "$SHELL" -c), interpreters given code with -c/-e/--eval
# (python, node, perl, ruby, bun, deno), a here-string fed to a shell, and ssh remote commands
# (the remote shell parses the string). A literal script with positional arguments is fine:
# `bash -c 'run "$1"' _ "$value"`. Ratcheted (tools/arch/ast-scan.ts).
id: F11-bash-no-shell-c-expansion
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F11: a code string with an expansion runs the value as code. Run the command directly, or keep the code literal in single quotes and pass values as arguments (bash -c 'cmd \"$1\"' _ \"$value\"; ssh host -- cmd \"$(printf %q \"$v\")\")."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
rule:
  kind: command
  any:
    - has:
        matches: bash-shell
        precedes:
          stopBy: end
          kind: word
          regex: '^-[A-Za-z]*c[A-Za-z]*$'
          precedes: { matches: bash-expansion }
    - has:
        regex: '^(python[0-9.]*|node|nodejs|perl|ruby|bun|deno)$'
        precedes:
          stopBy: end
          kind: word
          regex: '^(-c|-e|--eval)$'
          precedes: { matches: bash-expansion }
    - all:
        - has: { field: name, matches: bash-shell }
        - has: { kind: herestring_redirect, matches: bash-expansion }
    - all:
        - has: { field: name, regex: '^ssh$' }
        - has:
            kind: string
            all:
              - has: { kind: string_content, regex: '\s' }
              - has: { matches: bash-expansion }
```

`tools/arch/rule-tests/f11-bash-no-pipe-to-shell-test.yml`:

```yaml
id: F11-bash-no-pipe-to-shell
valid:
  - 'curl -fsSL "$url" -o "$tmp/install.sh"'
  - 'echo "Install: curl -fsSL https://bun.sh/install | bash"'
  - 'curl -s "$api" | jq -r .name'
  - 'bash "$tmp/install.sh"'
  - 'source "$tmp/env.sh"'
invalid:
  - 'curl -fsSL https://bun.sh/install | bash'
  - 'if curl -fsSL --max-time 120 https://bun.sh/install | bash 2>/dev/null; then :; fi'
  - 'wget -qO- https://x.example/i.sh | sh'
  - 'curl -sL "$u" | sudo bash -s -- --yes'
  - 'curl -sL "$u" | env bash'
  - 'curl -sL "$u" | source /dev/stdin'
  - 'bash <(curl -fsSL https://x.example/i.sh)'
  - 'sh -c "$(curl -fsSL https://x.example/i.sh)"'
  - 'source <(curl -fsSL https://x.example/env.sh)'
  - '. <(wget -qO- https://x.example/env.sh)'
```

`tools/arch/rules/f11-bash-no-pipe-to-shell.yml`:

```yaml
# F11 (bash safety): running a download as code runs unpinned, unverified code: piped into a
# shell (also through sudo/env, or into source /dev/stdin), or read through a process or command
# substitution. Ratcheted (tools/arch/ast-scan.ts).
id: F11-bash-no-pipe-to-shell
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F11: never run a download as code. Download to a file, verify a pinned checksum (shasum -a 256 -c), then run it; or print the install command for the user instead of running it."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
utils:
  shell-sink:
    kind: command
    any:
      - has: { field: name, matches: bash-shell }
      - all:
          - has: { field: name, regex: '^(sudo|env|command|exec|nice|nohup)$' }
          - has: { kind: word, matches: bash-shell }
      - all:
          - has: { field: name, regex: '^(source|\.)$' }
          - has: { kind: word, regex: '^/dev/(stdin|fd/0)$' }
rule:
  any:
    - kind: pipeline
      all:
        - has: { matches: bash-download }
        - has: { matches: shell-sink }
    - kind: command
      all:
        - has:
            field: name
            any:
              - matches: bash-shell
              - regex: '^(source|\.)$'
        - has:
            stopBy: end
            any:
              - kind: process_substitution
              - kind: command_substitution
            has: { stopBy: end, matches: bash-download }
```

`tools/arch/rule-tests/f11-bash-no-gha-expression-test.yml`:

```yaml
id: F11-bash-no-gha-expression
valid:
  - 'echo "${HOME}"'
  - 'echo "${x:-{}}"'
  - '# never write ${{ github.event.issue.title }} in a run step'
  - 'echo "$TITLE"'
invalid:
  - 'echo "${{ github.event.issue.title }}"'
  - "echo '${{ secrets.TOKEN }}'"
  - |
    cat > "$wf" <<EOF
          - run: echo \${{ matrix.os }}
    EOF
  - |
    cat > "$wf" <<'EOF'
        key: ${{ runner.os }}-node
    EOF
  - 'printf "%s\n" "runs-on: \${{ matrix.os }}"'
```

`tools/arch/rules/f11-bash-no-gha-expression.yml`:

```yaml
# F11 (bash safety): a GitHub Actions expression is substituted into the text before any shell
# parses it, so a script, or a workflow it generates, must never contain one (#8533). Comments are
# ignored. Ratcheted (tools/arch/ast-scan.ts).
id: F11-bash-no-gha-expression
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F11: no ${{ }} expression in scripts. Move the generated workflow into a checked-in .yml template (scanned by tools/arch/workflow-injection.ts), copy it instead of echoing it, and pass values through the step's env: block as \"$VAR\"."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
rule:
  matches: bash-text
  regex: '\$\{\{'
  not: { has: { regex: '\$\{\{' } }
```

`tools/arch/rule-tests/f9-bash-no-permission-bypass-test.yml`:

```yaml
id: F9-bash-no-permission-bypass
valid:
  - 'claude -p "$prompt" --allowedTools "Read,Edit" --permission-mode dontAsk'
  - '# never pass --dangerously-skip-permissions'
invalid:
  - 'claude -p "$prompt" --dangerously-skip-permissions'
  - 'flags+=(--dangerously-skip-permissions)'
  - 'CLAUDE_FLAGS="--model $m --dangerously-skip-permissions"'
  - 'claude --permission-mode bypassPermissions -p "$p"'
```

`tools/arch/rules/f9-bash-no-permission-bypass.yml`:

```yaml
# F9 for bash: agents never run with permission checks disabled. Ratcheted until each caller is
# ported to the AgentRunner port (permissionMode "dontAsk" and a per-stage tool allowlist).
id: F9-bash-no-permission-bypass
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F9: agents never skip permission checks. Pass an explicit --allowedTools list (and --permission-mode dontAsk) instead of --dangerously-skip-permissions or bypassPermissions."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
rule:
  matches: bash-text
  regex: '(?i)dangerously-skip-permissions|bypassPermissions|allowDangerouslySkipPermissions'
  not: { has: { regex: '(?i)dangerously-skip-permissions|bypassPermissions|allowDangerouslySkipPermissions' } }
```

`tools/arch/rule-tests/f9-bash-claude-token-scrub-test.yml`:

```yaml
id: F9-bash-claude-token-scrub
valid:
  - 'env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN claude -p "$prompt"'
  - 'timeout 300 env -u GH_TOKEN -u GITHUB_TOKEN claude -p "$prompt"'
  - 'env --unset=GH_TOKEN --unset=GITHUB_TOKEN claude -p "$prompt"'
  - 'sw_claude -p "$prompt"'
  - 'command -v claude >/dev/null'
  - 'which claude'
  - 'info "claude is ready"'
invalid:
  - 'claude -p "$prompt" --model "$m"'
  - 'out=$(claude --print "$p" 2>&1)'
  - 'timeout "$t" claude -p "$p"'
  - '$TIMEOUT_CMD "$CLAUDE_TIMEOUT" claude -p "$p"'
  - 'env -u GH_TOKEN claude -p "$p"'
  - 'nohup claude -p "$p" > "$log" 2>&1 &'
```

`tools/arch/rules/f9-bash-claude-token-scrub.yml`:

```yaml
# F9 for bash: a claude process inherits the caller's environment, including GH_TOKEN. Every
# invocation (direct, or behind timeout/nohup/exec/env/$TIMEOUT_CMD …) must unset the GitHub tokens
# in the same command. `command -v claude` and log lines are not invocations. Ratcheted.
id: F9-bash-claude-token-scrub
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F9: claude must not inherit GitHub tokens. Run it as env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN claude …, or call a helper such as sw_claude() that does exactly that."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
rule:
  kind: command
  all:
    - any:
        - has: { field: name, regex: '^claude$' }
        - all:
            - has: { kind: word, regex: '^claude$' }
            - not:
                has:
                  field: name
                  regex: '^(command|type|which|hash|echo|printf|info|warn|error|success|log|debug|emit_event)$'
    - not:
        all:
          - has: { kind: word, regex: '^(--unset=)?GH_TOKEN$' }
          - has: { kind: word, regex: '^(--unset=)?GITHUB_TOKEN$' }
```

`tools/arch/rule-tests/f10-bash-github-writes-test.yml`:

```yaml
id: F10-bash-github-writes
valid:
  - 'gh issue view "$n" --json title'
  - 'gh pr list --state open --json number'
  - 'gh api "repos/$repo/issues/$n/comments" --paginate'
  - 'gh api "repos/$repo/pulls" -X GET'
  - 'gh api -X GET "repos/$repo/issues" -f state=open -f per_page=100'
  - 'gh api "search/issues" --method GET -F q="repo:$r"'
  - "gh api graphql -f query='query { viewer { login } }'"
  - 'gh run list --workflow ci.yml'
  - 'gh repo view "$r" --json name'
  - 'gh gist view "$id"'
  - 'echo "gh issue create"'
  - 'git commit -m "gh pr merge"'
  - 'git stash push -m "wip"'
  - 'git fetch origin'
invalid:
  - 'gh issue create --title "$t" --body "$b"'
  - 'gh issue comment "$n" --body "$msg"'
  - 'gh pr merge "$pr" --squash'
  - 'gh pr create --fill'
  - 'gh label create "$l" --color ff0000'
  - 'gh workflow run ci.yml'
  - 'gh run rerun "$id"'
  - 'gh repo create "$name" --private'
  - 'gh repo delete "$r" --yes'
  - 'gh repo edit "$r" --visibility public'
  - 'gh repo fork "$r"'
  - 'gh repo rename "$new"'
  - 'gh repo archive "$r" --yes'
  - 'gh gist create "$f"'
  - 'gh api "repos/$repo/issues/$n/labels" -X POST -f "labels[]=x"'
  - 'gh api --method PATCH "repos/$repo/issues/comments/$id" -f body="$b"'
  - 'gh api "repos/$repo/issues" -f title="$t"'
  - "gh api graphql -f query='mutation { addStar(input: {}) { clientMutationId } }'"
  - 'url=$(gh pr create --title "$t" --body-file "$f")'
  - 'timeout 30 gh issue close "$n"'
  - 'gh issue edit "$n" --add-label "$l" 2>/dev/null || true'
  - 'git push origin "$branch"'
  - 'git -C "$wt" push --force-with-lease origin HEAD'
```

`tools/arch/rules/f10-bash-github-writes.yml`:

```yaml
# F10 for bash: GitHub writes move into GithubWriter as each command is ported. Ratcheted: a script
# may lose GitHub writes but never gain one. Matches `gh` write subcommands (also behind wrappers
# such as `timeout 30 gh …`), `gh api` calls that set a write method, send a body (not with an
# explicit GET, where -f/-F are query parameters) or contain a literal GraphQL `mutation`, and
# `git push`. A GraphQL mutation held in a variable is missed. The gh verb lists mirror
# f10-github-writes-only-in-writer.yml.
id: F10-bash-github-writes
language: Bash
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "F10: no new GitHub writes from bash (gh write commands, gh api writes, git push). Port the caller and add an idempotent GithubWriter method (src/adapters/github/gh-github-writer.ts), or call an existing writer."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
  - ".claude/hooks/**/*.sh"
  - "claude-code/hooks/**/*.sh"
  - "completions/**/*.bash"
  - "install.sh"
rule:
  kind: command
  any:
    - all:
        - has: { field: name, regex: '^git$' }
        - has: { kind: word, regex: '^push$' }
        - not: { has: { kind: word, regex: '^stash$' } }
    - all:
        - has: { regex: '^gh$' }
        - any:
            - all:
                - has: { regex: '^["'']?(issue|pr)["'']?$' }
                - has: { regex: '^["'']?(create|edit|comment|close|reopen|merge|review|lock|unlock|pin|unpin|develop|delete|transfer|ready|update-branch|revert)["'']?$' }
            - all:
                - has: { regex: '^["'']?(label|release)["'']?$' }
                - has: { regex: '^["'']?(create|edit|delete|clone|upload|delete-asset)["'']?$' }
            - all:
                - has: { regex: '^["'']?repo["'']?$' }
                - has: { regex: '^["'']?(create|delete|edit|fork|rename|archive|unarchive|sync)["'']?$' }
            - all:
                - has: { regex: '^["'']?gist["'']?$' }
                - has: { regex: '^["'']?(create|edit|delete|rename)["'']?$' }
            - all:
                - has: { regex: '^["'']?workflow["'']?$' }
                - has: { regex: '^["'']?(run|enable|disable)["'']?$' }
            - all:
                - has: { regex: '^["'']?run["'']?$' }
                - has: { regex: '^["'']?(rerun|cancel|delete)["'']?$' }
            - all:
                - has: { regex: '^["'']?(secret|variable)["'']?$' }
                - has: { regex: '^["'']?(set|delete|remove)["'']?$' }
            - all:
                - has: { regex: '^["'']?api["'']?$' }
                - any:
                    - has:
                        regex: '^["'']?(-X|--method)["'']?$'
                        precedes: { regex: '^["'']?(?i:POST|PATCH|PUT|DELETE)["'']?$' }
                    - has: { regex: '^["'']?(-X=?|--method=)(?i:POST|PATCH|PUT|DELETE)["'']?$' }
                    - all:
                        - has: { regex: '^["'']?(-[fF]|--field|--raw-field|--input)(=.*)?' }
                        - not: { has: { regex: '^["'']?graphql["'']?$' } }
                        - not: { has: { regex: '^["'']?(-X=?|--method=?)(?i:GET)["'']?$' } }
                        - not:
                            has:
                              regex: '^["'']?(-X|--method)["'']?$'
                              precedes: { regex: '^["'']?(?i:GET)["'']?$' }
                    - all:
                        - has: { regex: '^["'']?graphql["'']?$' }
                        - has: { regex: '\bmutation\b' }
```

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests --include-off 2>&1 | grep -E 'bash|result'
bun test tools/arch/meta.test.ts 2>&1 | grep -c '(fail)'
```

Expected: a `PASS` line for each of the seven bash rules and `test result: ok. 15 passed; 0 failed;`. The meta-test now fails: the new rules are not pinned, and none has a baseline yet.

- [ ] **Step 5: Write the scanner**

`tools/arch/ast-scan.ts`:

```ts
/**
 * Runs every ast-grep rule over the files git knows (not a directory walk, so .gitignore/.ignore
 * cannot hide a tracked file). Rules with severity error must have no findings; ratcheted rules
 * (severity off + metadata.ratchet) are compared with tools/arch/findings-baseline.json (ADR-0008).
 *
 *   bun tools/arch/ast-scan.ts                    check (part of `bun run arch`)
 *   bun tools/arch/ast-scan.ts --write-baseline   tighten/prune the baseline, or seed a new rule
 *   bun tools/arch/ast-scan.ts --against <ref>    also fail if the baseline rose vs the merge base (CI)
 */
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { baselineAt, risesAgainst } from "./baseline-history";
import {
  type Counts,
  checkFindings,
  countFindings,
  type Finding,
  grown,
  nextFindingsBaseline,
  parseScan,
  summaryMarkdown,
} from "./findings-ratchet";
import { isRatcheted, loadRules, ROOT, trackedFiles } from "./rule-catalog";

const BASELINE_REL = "tools/arch/findings-baseline.json";
const SCANNED = /\.(ts|tsx|mts|cts|sh|bash)$|(^|\/)sw$/;
const NO_IGNORE = ["hidden", "dot", "exclude", "global", "parent", "vcs"].flatMap((k) => [
  "--no-ignore",
  k,
]);

async function scan(ratcheted: readonly string[]): Promise<Finding[]> {
  const files = (await trackedFiles()).filter((f) => SCANNED.test(f));
  const proc = Bun.spawn(
    [
      join(ROOT, "node_modules/.bin/ast-grep"),
      "scan",
      ...ratcheted.map((id) => `--error=${id}`),
      "--json=stream",
      "--color=never",
      ...NO_IGNORE,
      ...files,
    ],
    { cwd: ROOT, stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  // Any ast-grep error (a bad rule, an unreadable path) fails the scan, even if it found matches.
  // The only expected ones are the summary it prints when error-severity matches exist.
  const expected =
    /^(Error: \d+ error\(s\) found in code\.|Help: Scan succeeded and found error level diagnostics.*)$/;
  const errors = stderr.split("\n").filter((l) => /\berror\b/i.test(l) && !expected.test(l));
  if (errors.length > 0) throw new Error(`ast-grep scan reported errors:\n${stderr}`);
  return parseScan(stdout);
}

function print(findings: readonly Finding[], messages: Map<string, string>): void {
  for (const rule of new Set(findings.map((f) => f.ruleId))) {
    console.error(`\n${rule}: ${messages.get(rule)}`);
    for (const f of findings.filter((x) => x.ruleId === rule))
      console.error(`  ${f.file}:${f.line}`);
  }
}

function check(
  findings: readonly Finding[],
  current: Counts,
  baseline: Counts,
  messages: Map<string, string>,
): number {
  const strict = findings.filter((f) => !(f.ruleId in current));
  print(strict, messages);
  const problems = checkFindings(current, baseline);
  for (const p of problems) console.error(`RATCHET ${p}`);
  const growth = new Set(grown(current, baseline).map(([rule, file]) => `${rule}\0${file}`));
  print(
    findings.filter((f) => growth.has(`${f.ruleId}\0${f.file}`)),
    messages,
  );
  if (problems.length > 0) {
    console.error(
      `\nBaseline: ${BASELINE_REL}. After fixing, run: bun tools/arch/ast-scan.ts --write-baseline`,
    );
  }
  return strict.length + problems.length > 0 ? 1 : 0;
}

if (import.meta.main) {
  const rules = await loadRules();
  const ratcheted = rules.filter(isRatcheted).map((r) => r.id);
  const messages = new Map(rules.map((r) => [r.id, r.message ?? ""]));
  const findings = await scan(ratcheted);
  const current = countFindings(
    findings.filter((f) => ratcheted.includes(f.ruleId)),
    ratcheted,
  );
  const file = Bun.file(join(ROOT, BASELINE_REL));
  const existing = (await file.exists()) ? ((await file.json()) as Counts) : undefined;
  const at = Bun.argv.indexOf("--against");
  if (at > 0) {
    const ref = Bun.argv[at + 1] ?? "origin/main";
    const rises = risesAgainst(baselineAt(ref, BASELINE_REL, ROOT) ?? {}, existing ?? {});
    for (const r of rises)
      console.error(`RATCHET ${r}. Baselines may not grow; fix the code instead.`);
    if (rises.length > 0) process.exit(1);
  }
  if (Bun.argv.includes("--write-baseline")) {
    const next = nextFindingsBaseline(current, existing, ratcheted);
    if ("errors" in next) {
      for (const e of next.errors) console.error(`RATCHET ${e}`);
      process.exit(1);
    }
    await Bun.write(file, `${JSON.stringify(next.baseline, null, 2)}\n`);
  } else {
    const summary = process.env.GITHUB_STEP_SUMMARY;
    if (summary && at < 0) {
      appendFileSync(summary, `### Ratcheted fitness findings\n\n${summaryMarkdown(current)}\n`);
    }
    process.exit(check(findings, current, existing ?? {}, messages));
  }
}
```

In `tools/arch/rule-catalog.ts`, add `readonly language?: string;` to `RuleDoc`, directly after `readonly id: string;`.

```bash
bun run format > /dev/null
bun tools/arch/ast-scan.ts 2>&1 | grep '^RATCHET' | grep -c 'no baseline entry'; bun tools/arch/ast-scan.ts > /dev/null 2>&1; echo "exit=$?"
printf 'id: ZZ-bad\nlanguage: Bash\nseverity: error\nmessage: "x"\nrule: { regex: "(" }\n' > tools/arch/rules/zz-bad.yml
bun tools/arch/ast-scan.ts 2>&1 | grep -m1 'ast-grep scan reported errors'; rm tools/arch/rules/zz-bad.yml
```

Expected: `7` (each ratcheted rule asks to be seeded), `exit=1`; the malformed rule makes the scan fail with `error: ast-grep scan reported errors:` instead of passing silently.

- [ ] **Step 6: Pin the new rules and the scanner in the meta-test**

In `tools/arch/meta.test.ts`, insert into `PINNED` before the `"dashboard-no-shell-from-data"` entry:

```ts
  "F9-bash-claude-token-scrub": { ratchet: true, ignores: [] },
  "F9-bash-no-permission-bypass": { ratchet: true, ignores: [] },
  "F10-bash-github-writes": { ratchet: true, ignores: [] },
  "F11-bash-no-eval-expansion": { ratchet: true, ignores: [] },
  "F11-bash-no-gha-expression": { ratchet: true, ignores: [] },
  "F11-bash-no-pipe-to-shell": { ratchet: true, ignores: [] },
  "F11-bash-no-shell-c-expansion": { ratchet: true, ignores: [] },
```

In `ARCH_STEPS`, replace `"ast-grep scan",` with `"bun tools/arch/ast-scan.ts",`. Insert before `test("every rule test belongs to a rule …`:

```ts
test("every Bash rule covers the same files (scripts, hooks, completions, install.sh)", () => {
  const bash = rules.filter((r) => r.language === "Bash");
  expect(bash.length).toBeGreaterThan(0);
  for (const r of bash) expect(r.files).toEqual(bash[0]?.files ?? []);
});

```

In `package.json`'s `arch` script, replace `ast-grep scan && ` with `bun tools/arch/ast-scan.ts && `. The line becomes:

```json
    "arch": "depcruise src --config .dependency-cruiser.cjs && bun tools/arch/ast-scan.ts && ast-grep test --skip-snapshot-tests --include-off && bun tools/arch/size-ratchet.ts && bun tools/arch/workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts",
```

- [ ] **Step 7: Anti-laundering for the size baseline, and the CI step**

In `tools/arch/size-ratchet.ts`, add `import { baselineAt, risesAgainst } from "./baseline-history";` after `import ts from "typescript";`. In the `import.meta.main` block, insert directly before `if (Bun.argv.includes("--write-baseline")) {`:

```ts
  const at = Bun.argv.indexOf("--against");
  if (at > 0) {
    // Anti-laundering (ADR-0008): the baseline may not gain or raise an entry vs the merge base.
    const ref = Bun.argv[at + 1] ?? "origin/main";
    const base = baselineAt(ref, "tools/arch/arch-baseline.json", ROOT) ?? {};
    const rises = risesAgainst(base, { ...(existing ?? { files: {}, functions: {} }) });
    for (const r of rises)
      console.error(`F7 ${r}. Baselines may not grow; split the code instead.`);
    if (rises.length > 0) process.exit(1);
  }
```

In `.github/workflows/ts-check.yml`, give the checkout full history:

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # the baseline check below needs the merge base
```

and directly after the step that runs `run: bun run arch` (rename it `Fitness rules (F1–F12, workflow rules)` if it still says F1–F8), add:

```yaml
      - name: Fitness baselines never grow against the base branch
        if: github.event_name == 'pull_request'
        run: |
          bun tools/arch/ast-scan.ts --against "origin/$GITHUB_BASE_REF"
          bun tools/arch/size-ratchet.ts --against "origin/$GITHUB_BASE_REF"
```

(`$GITHUB_BASE_REF` is a runner variable, not a `${{ }}` expression, so the workflow rules stay satisfied.)

```bash
actionlint .github/workflows/ts-check.yml && bun tools/arch/workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts && echo workflows-ok
```

Expected: `workflows-ok`.

- [ ] **Step 8: Seed the baseline against the current HEAD**

```bash
bun tools/arch/ast-scan.ts --write-baseline && bun tools/arch/ast-scan.ts; echo "exit=$?"
jq -r 'to_entries[] | "\(.key): \(.value | length) files, \([.value[]] | add // 0) findings"' tools/arch/findings-baseline.json
bun test tools/arch 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: `exit=0`, then (dry run at `2aaa43fda`; commits after it that touch scripts can shift the counts, and whatever the seed records at execution time is the baseline):

```text
F10-bash-github-writes: 37 files, 99 findings
F11-bash-no-eval-expansion: 11 files, 16 findings
F11-bash-no-gha-expression: 1 files, 12 findings
F11-bash-no-pipe-to-shell: 1 files, 1 findings
F11-bash-no-shell-c-expansion: 29 files, 100 findings
F9-bash-claude-token-scrub: 27 files, 44 findings
F9-bash-no-permission-bypass: 7 files, 16 findings
```

and `0 fail` for `tools/arch` (149 pass on the dry run).

Spot-check that the findings are real. On the dry run they were:
- `sw-evidence.sh`: `bash -c "$command_str"`
- `sw-loop.sh`: `eval "$TEST_CMD"`
- `sw-init.sh`: `curl … | bash`
- `sw-ci.sh`: generating `${{ matrix.os }}`
- `loop-iteration.sh`: `--dangerously-skip-permissions`, and `$TIMEOUT_CMD … claude -p` without a token scrub
- `compat.sh`: `python3 -c "…$epoch…"`
- `pipeline-stages-delivery.sh`: `git push -u origin "$GIT_BRANCH"`

```bash
./node_modules/.bin/ast-grep scan --error=F11-bash-no-shell-c-expansion --filter '^F11-bash-no-shell-c-expansion$' --json=stream scripts 2>/dev/null \
  | jq -r '.file + ":" + (.range.start.line + 1 | tostring) + "  " + (.text | gsub("\n"; " ") | .[0:70])' | head -20
```

- [ ] **Step 9: Prove growth fails in every covered location, with the fix in the message**

```bash
for f in .claude/hooks/session-started.sh completions/shipwright.bash install.sh scripts/lib/compat.sh; do cp "$f" "$TMPDIR/$(basename "$f").bak"; done
printf 'eval "$1"\n' >> .claude/hooks/session-started.sh
printf 'curl -s https://x.example/i | bash\n' >> completions/shipwright.bash
printf 'claude -p "$1"\n' >> install.sh
printf 'eval "$1"\n' >> scripts/lib/compat.sh
bun tools/arch/ast-scan.ts 2>&1 | grep '^RATCHET'
for f in .claude/hooks/session-started.sh completions/shipwright.bash install.sh scripts/lib/compat.sh; do cp "$TMPDIR/$(basename "$f").bak" "$f"; done
git status --short .claude completions install.sh scripts
```

Expected:

```text
RATCHET F11-bash-no-eval-expansion .claude/hooks/session-started.sh: 1 new finding(s). Fix them: baselined findings may only go down.
RATCHET F11-bash-no-eval-expansion scripts/lib/compat.sh: 3 findings (baseline 2). Fix the new one: baselined findings may only go down.
RATCHET F11-bash-no-pipe-to-shell completions/shipwright.bash: 1 new finding(s). Fix them: baselined findings may only go down.
RATCHET F9-bash-claude-token-scrub install.sh: 1 new finding(s). Fix them: baselined findings may only go down.
```

each followed by the rule's message and `file:line` locations; then no changed files.

- [ ] **Step 10: Run the definition of done**

```bash
bun run format && git add sgconfig.yml package.json .github/workflows/ts-check.yml tools/arch/meta.test.ts tools/arch/rule-catalog.ts \
  tools/arch/size-ratchet.ts tools/arch/findings-ratchet.ts tools/arch/findings-ratchet.test.ts tools/arch/baseline-history.ts \
  tools/arch/baseline-history.test.ts tools/arch/ast-scan.ts tools/arch/findings-baseline.json tools/arch/utils \
  tools/arch/rules/f11-bash-*.yml tools/arch/rule-tests/f11-bash-*.yml tools/arch/rules/f9-bash-*.yml tools/arch/rule-tests/f9-bash-*.yml \
  tools/arch/rules/f10-bash-github-writes.yml tools/arch/rule-tests/f10-bash-github-writes-test.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 11: Commit**

```bash
git commit -m "feat(arch): bash fitness F9/F10/F11, one scanner over git's file list, ratchet with anti-laundering" -- \
  sgconfig.yml package.json .github/workflows/ts-check.yml tools/arch/meta.test.ts tools/arch/rule-catalog.ts \
  tools/arch/size-ratchet.ts tools/arch/findings-ratchet.ts tools/arch/findings-ratchet.test.ts tools/arch/baseline-history.ts \
  tools/arch/baseline-history.test.ts tools/arch/ast-scan.ts tools/arch/findings-baseline.json tools/arch/utils \
  tools/arch/rules/f11-bash-*.yml tools/arch/rule-tests/f11-bash-*.yml tools/arch/rules/f9-bash-*.yml tools/arch/rule-tests/f9-bash-*.yml \
  tools/arch/rules/f10-bash-github-writes.yml tools/arch/rule-tests/f10-bash-github-writes-test.yml
```

- [ ] **Step 12: Prove the baselines cannot be laundered, and that an empty one must be promoted**

Now that the baselines are committed, raise them in the working tree and compare against `HEAD` (CI compares against the PR's merge base the same way):

```bash
cp tools/arch/findings-baseline.json "$TMPDIR/fb.bak"; cp tools/arch/arch-baseline.json "$TMPDIR/ab.bak"
jq '."F11-bash-no-eval-expansion"."scripts/lib/compat.sh" += 1' "$TMPDIR/fb.bak" > tools/arch/findings-baseline.json
jq '.files["src/main.ts"] = 999' "$TMPDIR/ab.bak" > tools/arch/arch-baseline.json
bun tools/arch/ast-scan.ts --against HEAD; echo "scan exit=$?"
bun tools/arch/size-ratchet.ts --against HEAD; echo "size exit=$?"
bun tools/arch/ast-scan.ts --against no-such-ref 2>&1 | grep -m1 -o 'git merge-base HEAD no-such-ref failed'
jq '."F11-bash-no-pipe-to-shell" = {}' "$TMPDIR/fb.bak" > tools/arch/findings-baseline.json
bun test tools/arch/meta.test.ts 2>&1 | grep '(fail)'
cp "$TMPDIR/fb.bak" tools/arch/findings-baseline.json; cp "$TMPDIR/ab.bak" tools/arch/arch-baseline.json
git status --short tools/arch
```

Expected:
- `RATCHET F11-bash-no-eval-expansion scripts/lib/compat.sh rose from 2 to 3 against the base branch. Baselines may not grow; fix the code instead.` and `scan exit=1`
- `F7 files src/main.ts is new against the base branch. Baselines may not grow; split the code instead.` and `size exit=1`
- `git merge-base HEAD no-such-ref failed` (fails closed)
- `(fail) every fitness rule > F11-bash-no-pipe-to-shell > has a non-empty baseline (when it reaches zero, promote it to severity: error)`
- then no changed files.

---

### Task 5: F12 dashboard boundaries

**Files:**
- Create: `.dependency-cruiser.dashboard.cjs`, `tools/arch/rules/dashboard-subprocess-only-in-services.yml` + test
- Modify: `.dependency-cruiser.cjs`, `tools/arch/depcruise-rules.test.ts`, `tools/arch/meta.test.ts`, `tools/arch/findings-baseline.json`, `package.json`

Inventory at `2aaa43fda`: `dashboard/` has a browser bundle (`src/`) and a Bun server: `server.ts` (5.9k lines) → `routes/auth.ts` → `middleware/{auth,constants}.ts`; `services/{claims,subprocess-guards,request-guard,auth-flow,db,config}.ts`; `types/`. Today's imports already follow the layering, so D1–D4 are strict. Processes are spawned by `services/claims.ts` (`execFileSync` with argv) and by `server.ts` (the `child_process` import and 11 `execSync`/`execFileSync` calls at `efa1e4704`; 13 at the dry-run base `2aaa43fda`), so the subprocess allowlist is a ratchet. Wave 1a Task 15's `dashboard-no-shell-from-data` already forbids non-constant or concatenated shell strings and `shell: true`; this task does not repeat it.

- [ ] **Step 1: Add fixtures for the new rules (red)**

In `tools/arch/depcruise-rules.test.ts`, add to `FIXTURES` before `"F4-no-cycles": {`:

```ts
  "F3-src-not-dashboard": {
    "src/adapters/x/uses-dashboard.ts": 'import "../../../dashboard/services/svc";',
    "dashboard/services/svc.ts": "export {};",
  },
```

and before the closing `};` of `FIXTURES`:

```ts
  "D1-browser-server-split": {
    "dashboard/src/view.ts": 'import "../middleware/constants";',
    "dashboard/middleware/constants.ts": "export {};",
  },
  "D1-server-browser-split": {
    "dashboard/services/uses-view.ts": 'import "../src/widget";',
    "dashboard/src/widget.ts": "export {};",
  },
  "D1-dashboard-not-src": {
    "dashboard/services/uses-src.ts": 'import "../../src/shared/kernel/result";',
    "src/shared/kernel/result.ts": "export {};",
  },
  "D2-services-are-the-bottom-layer": {
    "dashboard/services/up.ts": 'import "../middleware/constants";',
    "dashboard/middleware/constants.ts": "export {};",
  },
  "D2-middleware-not-routes": {
    "dashboard/middleware/m.ts": 'import "../routes/r";',
    "dashboard/routes/r.ts": "export {};",
  },
  "D3-routes-not-server": {
    "dashboard/routes/a.ts": 'import "./b";',
    "dashboard/routes/b.ts": "export {};",
  },
  "D4-no-cycles": {
    "dashboard/types/t1.ts": 'import "./t2";',
    "dashboard/types/t2.ts": 'import "./t1";',
  },
```

and add the second config to `CONFIGS`:

```ts
  ".dependency-cruiser.dashboard.cjs": "dashboard",
```

```bash
bun test tools/arch/depcruise-rules.test.ts 2>&1 | grep -E 'error:|\(fail\)|^\s*[0-9]+ (pass|fail)' | head -3
```

Expected: the test file fails to load (`Cannot find module '../../.dependency-cruiser.dashboard.cjs'`).

- [ ] **Step 2: Write the dashboard config and the `src` → `dashboard` rule**

`.dependency-cruiser.dashboard.cjs`:

```js
/**
 * F12 dashboard boundaries (D1–D4, spec §3.3, ADR-0008). The dashboard is a separate TypeScript
 * project until it is ported (Wave 3): server.ts (routing) → routes/ → middleware/ and services/ →
 * types/; the browser bundle in dashboard/src talks to the server only over HTTP, and neither side
 * imports src/. Each comment names the fix. Fixtures: tools/arch/depcruise-rules.test.ts.
 */
const SERVER = "^dashboard/(server\\.ts|routes|services|middleware|types)(/|$)";
module.exports = {
  forbidden: [
    {
      name: "D1-browser-server-split",
      comment:
        "D1: dashboard/src is the browser bundle and the server side is Bun. Neither imports the other: talk over HTTP, and keep browser wire types in dashboard/src/types/api.ts.",
      severity: "error",
      from: { path: "^dashboard/src/" },
      to: { path: SERVER },
    },
    {
      name: "D1-server-browser-split",
      comment:
        "D1: the server must not import the browser bundle (dashboard/src). Move shared logic into dashboard/services.",
      severity: "error",
      from: { path: SERVER },
      to: { path: "^dashboard/src/" },
    },
    {
      name: "D1-dashboard-not-src",
      comment:
        "D1: the dashboard does not import src/ until it is ported (Wave 3). Call the shipwright CLI from a service, or port the route into src/.",
      severity: "error",
      from: { path: "^dashboard/" },
      to: { path: "^src/" },
    },
    {
      name: "D2-services-are-the-bottom-layer",
      comment:
        "D2: services/ and types/ never import routes/, middleware/ or server.ts. Pass what the service needs as parameters.",
      severity: "error",
      from: { path: "^dashboard/(services|types)/" },
      to: { path: "^dashboard/(routes|middleware|server\\.ts)" },
    },
    {
      name: "D2-middleware-not-routes",
      comment:
        "D2: middleware/ never imports routes/ or server.ts. Move the shared piece into middleware/ or services/.",
      severity: "error",
      from: { path: "^dashboard/middleware/" },
      to: { path: "^dashboard/(routes|server\\.ts)" },
    },
    {
      name: "D3-routes-not-server",
      comment:
        "D3: routes/ never imports server.ts or another route. Move the shared piece into services/ or middleware/.",
      severity: "error",
      from: { path: "^dashboard/routes/([^/]+)\\.ts$" },
      to: { path: "^dashboard/(server\\.ts|routes/)", pathNot: "^dashboard/routes/$1\\.ts$" },
    },
    {
      name: "D4-no-cycles",
      comment: "D4: break the cycle by moving the shared piece down into services/ or types/.",
      severity: "error",
      from: { path: "^dashboard/" },
      to: { circular: true },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    exclude: { path: ["\\.test\\.ts$", "^dashboard/(public|coverage|node_modules)/"] },
    tsPreCompilationDeps: true,
    // The server tsconfig (Wave 1a Task 15) resolves "./x.js" imports to the .ts sources.
    tsConfig: { fileName: "dashboard/tsconfig.server.json" },
  },
};
```

In `.dependency-cruiser.cjs`, insert before the `F4-no-cycles` rule:

```js
    {
      name: "F3-src-not-dashboard",
      comment:
        "F3: src/ never imports dashboard/ (a separate project until Wave 3). Port the piece you need into a context.",
      severity: "error",
      from: { path: "^src/" },
      to: { path: "^dashboard/" },
    },
```

```bash
./node_modules/.bin/depcruise src --config .dependency-cruiser.cjs > /dev/null && ./node_modules/.bin/depcruise dashboard --config .dependency-cruiser.dashboard.cjs 2>&1 | grep -E 'violations'
bun test tools/arch/depcruise-rules.test.ts 2>&1 | grep -E '\(fail\)|^\s*[0-9]+ (pass|fail)'
```

Expected: `✔ no dependency violations found (58 modules, 185 dependencies cruised)` (counts vary with later dashboard changes); `6 pass`, `0 fail`. Every rule in both configs fired on its fixture.

- [ ] **Step 3: Write the subprocess allowlist rule test**

`tools/arch/rule-tests/dashboard-subprocess-only-in-services-test.yml`:

```yaml
id: dashboard-subprocess-only-in-services
valid:
  - 'db.exec("PRAGMA journal_mode=WAL;");'
  - 'const r = regex.exec(line);'
  - 'import { join } from "path";'
  - 'import type { ExecFileSyncOptions } from "child_process";'
  - 'const out = await runGh(["issue", "view", String(n)]);'
  - 'particles.spawn(x, y);'
  - 'const v = Bun.version;'
invalid:
  - 'import { execSync } from "child_process";'
  - 'import { spawn } from "node:child_process";'
  - 'const cp = require("child_process");'
  - 'const cp = await import("node:child_process");'
  - 'execSync("nproc");'
  - 'execFileSync("gh", ["issue", "view", String(n)]);'
  - 'const p = spawn("ssh", argv);'
  - 'Bun.spawn(["git", "status"]);'
  - 'await Bun.$`git log`;'
  - 'const { spawn } = Bun;'
  - 'const { spawnSync: run } = Bun;'
  - 'Bun["spawn"](["git", "status"]);'
  - "const run = Bun['spawnSync'];"
```

- [ ] **Step 4: Write the rule**

`tools/arch/rules/dashboard-subprocess-only-in-services.yml`:

```yaml
# Dashboard (F12): only allowlisted services spawn processes, so validation and argv building live
# in one place (#8534). Ratcheted (tools/arch/ast-scan.ts): server.ts still spawns directly and may
# only lose call sites until Wave 3 ports it. To add a subprocess call, put it in a service that
# validates its inputs and add that file to `ignores` here and in tools/arch/meta.test.ts (PINNED),
# a change CODEOWNERS review.
id: dashboard-subprocess-only-in-services
language: TypeScript
severity: off
metadata: { ratchet: true, owner: "@sethdford", docs: "docs/architecture.md#fitness-rules" }
message: "Dashboard: spawn processes only from an allowlisted service (dashboard/services/claims.ts). Move the call into a service that validates its input and passes an argv array, and call that service."
files:
  - "dashboard/**/*.ts"
ignores:
  - "dashboard/**/*.test.ts"
  - "dashboard/src/**"
  - "dashboard/services/claims.ts"
  - "dashboard/services/subprocess-guards.ts"
rule:
  any:
    - all:
        - any:
            - kind: import_statement
            - kind: export_statement
        - has: { field: source, regex: '^["''](node:)?child_process["'']$' }
        - not: { regex: '^(import|export)\s+type\s' }
    - all:
        - any:
            - pattern: require($S)
            - pattern: import($S)
        - has:
            field: arguments
            has: { kind: string, regex: '^["''](node:)?child_process["'']$' }
    - kind: call_expression
      has:
        field: function
        kind: identifier
        regex: '^(exec|execSync|execFile|execFileSync|spawn|spawnSync|fork)$'
    # Bun.spawn, Bun.$, Bun["spawn"], and destructuring them out of Bun
    - kind: member_expression
      all:
        - has: { field: object, regex: '^Bun$' }
        - has: { field: property, regex: '^(spawn|spawnSync|\$)$' }
    - kind: subscript_expression
      all:
        - has: { field: object, regex: '^Bun$' }
        - has: { field: index, regex: '^["''](spawn|spawnSync|\$)["'']$' }
    - kind: variable_declarator
      all:
        - has: { field: value, regex: '^Bun$' }
        - has: { field: name, kind: object_pattern, regex: '\b(spawn|spawnSync|\$)\b' }
```

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests --include-off 2>&1 | grep -E 'subprocess|result'
bun tools/arch/ast-scan.ts 2>&1 | grep '^RATCHET'
```

Expected: `PASS dashboard-subprocess-only-in-services  ....................` and `test result: ok. 16 passed; 0 failed;`. The scan then fails with:
- `RATCHET dashboard-subprocess-only-in-services dashboard/server.ts: 12 new finding(s). …` (12 at `efa1e4704`; 14 at the dry-run base)
- `RATCHET dashboard-subprocess-only-in-services has no baseline entry. Seed it: …`

- [ ] **Step 5: Pin it, and wire D1–D4 into `bun run arch`**

In `tools/arch/meta.test.ts`, insert into `PINNED` before `"dashboard-no-shell-from-data"`:

```ts
  "dashboard-subprocess-only-in-services": {
    ratchet: true,
    ignores: [
      "dashboard/**/*.test.ts",
      "dashboard/src/**",
      "dashboard/services/claims.ts",
      "dashboard/services/subprocess-guards.ts",
    ],
  },
```

and add `"depcruise dashboard --config .dependency-cruiser.dashboard.cjs",` to `ARCH_STEPS` after the `depcruise src` entry. In `package.json`, insert `depcruise dashboard --config .dependency-cruiser.dashboard.cjs && ` after `depcruise src --config .dependency-cruiser.cjs && `:

```json
    "arch": "depcruise src --config .dependency-cruiser.cjs && depcruise dashboard --config .dependency-cruiser.dashboard.cjs && bun tools/arch/ast-scan.ts && ast-grep test --skip-snapshot-tests --include-off && bun tools/arch/size-ratchet.ts && bun tools/arch/workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts",
```

- [ ] **Step 6: Seed the new rule's baseline; every other entry stays as it was**

```bash
bun tools/arch/ast-scan.ts --write-baseline && bun tools/arch/ast-scan.ts; echo "exit=$?"
git diff --stat tools/arch/findings-baseline.json
jq '."dashboard-subprocess-only-in-services"' tools/arch/findings-baseline.json
```

Expected: `exit=0`; the diff adds only the new block (`3 insertions(+)`); `{ "dashboard/server.ts": 12 }` at `efa1e4704`.

- [ ] **Step 7: Run the definition of done**

```bash
bun run format && git add .dependency-cruiser.cjs .dependency-cruiser.dashboard.cjs package.json tools/arch/depcruise-rules.test.ts \
  tools/arch/meta.test.ts tools/arch/findings-baseline.json tools/arch/rules/dashboard-subprocess-only-in-services.yml \
  tools/arch/rule-tests/dashboard-subprocess-only-in-services-test.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(arch): F12 dashboard layering, src/dashboard boundary, subprocess allowlist" -- \
  .dependency-cruiser.cjs .dependency-cruiser.dashboard.cjs package.json tools/arch/depcruise-rules.test.ts \
  tools/arch/meta.test.ts tools/arch/findings-baseline.json tools/arch/rules/dashboard-subprocess-only-in-services.yml \
  tools/arch/rule-tests/dashboard-subprocess-only-in-services-test.yml
```

---

### Task 6: Generated dependency graph

**Files:**
- Create: `tools/docs/gen-dependency-graph.ts`, `tools/docs/gen-dependency-graph.test.ts`, `docs/reference/dependency-graph.md` (generated)
- Modify: `package.json`

- [ ] **Step 1: Write the test**

`tools/docs/gen-dependency-graph.test.ts`:

```ts
import { expect, test } from "bun:test";
import { groupOf, layerEdges, renderGraph } from "./gen-dependency-graph";

test("collapses files into contexts, layers, adapters and entry points", () => {
  expect(groupOf("src/contexts/orchestration/domain/breaker.ts")).toBe("orchestration/domain");
  expect(groupOf("src/contexts/orchestration/application/gates.ts")).toBe(
    "orchestration/application",
  );
  expect(groupOf("src/contexts/orchestration/index.ts")).toBe("orchestration");
  expect(groupOf("src/adapters/github/gh-json.ts")).toBe("adapters/github");
  expect(groupOf("src/adapters/paths.ts")).toBe("adapters");
  expect(groupOf("src/shared/kernel/ports.ts")).toBe("kernel");
  expect(groupOf("src/cli/commands/gates.ts")).toBe("cli");
  expect(groupOf("src/cli.ts")).toBe("cli");
  expect(groupOf("src/main.ts")).toBe("main");
  expect(groupOf("node_modules/zod/index.cjs")).toBeUndefined();
});

test("edges are unique, sorted and never self-loops", () => {
  const modules = [
    {
      source: "src/cli/commands/a.ts",
      dependencies: [{ resolved: "src/contexts/x/index.ts" }, { resolved: "src/cli/shared.ts" }],
    },
    { source: "src/cli/commands/b.ts", dependencies: [{ resolved: "src/contexts/x/index.ts" }] },
    { source: "src/contexts/x/index.ts", dependencies: [{ resolved: "zod" }] },
  ];
  expect(layerEdges(modules)).toEqual([["cli", "x"]]);
});

test("renders a deterministic mermaid flowchart with a subgraph per context", () => {
  const md = renderGraph([
    ["x/application", "x/domain"],
    ["cli", "x"],
    ["x", "x/application"],
  ]);
  expect(md).toContain("<!-- Generated by tools/docs/gen-dependency-graph.ts. Do not edit. -->");
  expect(md).toContain(
    '  subgraph ctx_x["x"]\n    x["x"]\n    x_application["x/application"]\n    x_domain["x/domain"]\n  end',
  );
  expect(md).toContain('  cli["cli"]');
  expect(md.indexOf("cli --> x")).toBeLessThan(md.indexOf("x --> x_application"));
  expect(renderGraph([["cli", "x"]])).toBe(renderGraph([["cli", "x"]]));
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
bun test tools/docs/gen-dependency-graph.test.ts 2>&1 | grep -E 'error:|^\s*[0-9]+ (pass|fail)'
```

Expected: `error: Cannot find module './gen-dependency-graph'`, `1 fail`.

- [ ] **Step 3: Write the generator**

`tools/docs/gen-dependency-graph.ts` (dependency-cruiser's `cruise` API, in-process, about 1 s):

````ts
import { join, resolve } from "node:path";
import { cruise } from "dependency-cruiser";

const ROOT = resolve(import.meta.dir, "../..");
const TARGET_REL = "docs/reference/dependency-graph.md";

type Edge = readonly [from: string, to: string];
interface CruisedModule {
  readonly source: string;
  readonly dependencies: readonly { readonly resolved: string }[];
}

/** The node a source file belongs to: a context layer, an adapter, the kernel or an entry point. */
export function groupOf(path: string): string | undefined {
  const parts = path.split("/");
  if (parts[0] !== "src" || parts.length < 2) return undefined;
  const [, top, a, b] = parts;
  if (top === "contexts" && a) return b === "domain" || b === "application" ? `${a}/${b}` : a;
  if (top === "adapters") return parts.length > 3 && a ? `adapters/${a}` : "adapters";
  if (top === "shared" && a === "kernel") return "kernel";
  if (top === "cli" || top === "cli.ts") return "cli";
  return top?.replace(/\.ts$/, "");
}

/** Unique group → group edges between different groups, sorted. */
export function layerEdges(modules: readonly CruisedModule[]): Edge[] {
  const seen = new Map<string, Edge>();
  for (const m of modules) {
    const from = groupOf(m.source);
    for (const d of m.dependencies) {
      const to = groupOf(d.resolved);
      if (from && to && from !== to) seen.set(`${from}\0${to}`, [from, to]);
    }
  }
  return [...seen.values()].sort((x, y) => x[0].localeCompare(y[0]) || x[1].localeCompare(y[1]));
}

const id = (group: string) => group.replace(/[^A-Za-z0-9]/g, "_");
const node = (group: string) => `${id(group)}["${group}"]`;

export function renderGraph(edges: readonly Edge[]): string {
  const groups = [...new Set(edges.flat())].sort();
  // "x" and "x/domain" share the subgraph "x"; so do "adapters" and "adapters/github".
  const clusterOf = (g: string): string | undefined => {
    const head = g.split("/")[0] ?? g;
    return groups.some((x) => x.startsWith(`${head}/`)) ? head : undefined;
  };
  const clusters = [...new Set(groups.map(clusterOf).filter((c) => c !== undefined))].sort();
  const lines = ["flowchart LR"];
  for (const c of clusters) {
    lines.push(`  subgraph ctx_${id(c)}["${c}"]`);
    for (const g of groups.filter((x) => clusterOf(x) === c)) lines.push(`    ${node(g)}`);
    lines.push("  end");
  }
  for (const g of groups.filter((x) => clusterOf(x) === undefined)) lines.push(`  ${node(g)}`);
  for (const [from, to] of edges) lines.push(`  ${id(from)} --> ${id(to)}`);
  return [
    "# Dependency graph",
    "",
    "<!-- Generated by tools/docs/gen-dependency-graph.ts. Do not edit. -->",
    "",
    "Imports between the layers of `src/` (tests and `src/testing` excluded), collapsed to contexts,",
    "their `domain`/`application` layers, adapters, the kernel and the entry points. Rules: [architecture](../architecture.md#fitness-rules).",
    "",
    "```mermaid",
    ...lines,
    "```",
    "",
  ].join("\n");
}

async function render(): Promise<string> {
  const result = await cruise(
    ["src"],
    {
      includeOnly: "^src/",
      exclude: { path: ["\\.test\\.ts$", "^src/testing/"] },
      tsPreCompilationDeps: true,
      baseDir: ROOT,
    },
    undefined,
    { tsConfig: { fileName: join(ROOT, "tsconfig.json") } },
  );
  const output = result.output as unknown as { modules: CruisedModule[] };
  return renderGraph(layerEdges(output.modules));
}

if (import.meta.main) {
  const md = await render();
  const file = Bun.file(join(ROOT, TARGET_REL));
  if (Bun.argv.includes("--check")) {
    if (!(await file.exists()) || (await file.text()) !== md) {
      console.error(`${TARGET_REL} is stale. Run: bun run docs:gen`);
      process.exit(1);
    }
  } else {
    await Bun.write(file, md);
  }
}
````

```bash
bun run format > /dev/null; bun test tools/docs/gen-dependency-graph.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: `3 pass`, `0 fail`.

- [ ] **Step 4: Chain it into `docs:gen` and `docs:check`**

In `package.json`, replace the two scripts with:

```json
    "docs:gen": "bun tools/docs/gen-cli-reference.ts && bun tools/docs/gen-dependency-graph.ts",
    "docs:check": "bun tools/docs/gen-cli-reference.ts --check && bun tools/docs/gen-dependency-graph.ts --check",
```

- [ ] **Step 5: Missing fails; generate; deterministic; stale fails**

```bash
bun run docs:check > /dev/null 2>&1; echo "missing exit=$?"
bun run docs:gen > /dev/null && cp docs/reference/dependency-graph.md "$TMPDIR/graph1.md"
bun run docs:gen > /dev/null && cmp docs/reference/dependency-graph.md "$TMPDIR/graph1.md" && echo deterministic
echo "  x --> y" >> docs/reference/dependency-graph.md
bun tools/docs/gen-dependency-graph.ts --check; echo "stale exit=$?"
bun run docs:gen > /dev/null && bun run docs:check > /dev/null; echo "check exit=$?"
head -20 docs/reference/dependency-graph.md
```

Expected:
- `missing exit=1`, `deterministic`
- `docs/reference/dependency-graph.md is stale. Run: bun run docs:gen` and `stale exit=1`
- `check exit=0`

The file starts with `# Dependency graph`, the generated-file comment, and a `mermaid` block with `flowchart LR`. It has subgraphs `adapters`, `orchestration` and `platform`, and plain nodes `cli`, `integrations`, `kernel`, `main` and `shutdown`. On the dry run it had 37 edges, among them `cli --> orchestration`, `main --> adapters_github` and `orchestration_application --> orchestration_domain`.

- [ ] **Step 6: Run the definition of done**

```bash
bun run format && git add package.json tools/docs/gen-dependency-graph.ts tools/docs/gen-dependency-graph.test.ts docs/reference/dependency-graph.md && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 7: Commit**

```bash
git commit -m "docs(arch): generate the src dependency graph; docs:check fails when stale" -- \
  package.json tools/docs/gen-dependency-graph.ts tools/docs/gen-dependency-graph.test.ts docs/reference/dependency-graph.md
```

From now on, a change that adds an import between layers also needs `bun run docs:gen`; `docs:check` says so.

---

### Task 7: Documentation, spec §3.3 and ADR-0008

**Files:**
- Create: `docs/adr/0008-fitness-functions-everywhere.md`
- Modify: `AGENTS.md`, `docs/architecture.md`, `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md`

Each edit replaces a whole section, so it applies on top of Wave 1a Task 17's wording. Every rule's `metadata.docs` points at `docs/architecture.md#fitness-rules`; keep that heading (the meta-test checks the anchor).

- [ ] **Step 1: Write `docs/adr/0008-fitness-functions-everywhere.md` (write-adr format, under 60 lines)**

```markdown
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
```

- [ ] **Step 2: Replace the fitness section of `AGENTS.md`**

Replace everything from the line `## Fitness rules (spec §3.3)` up to, not including, `## Deployment modes and state` with:

```markdown
## Fitness rules (spec §3.3, ADR-0008)

`bun run arch` enforces: F1 pure domain · F2 application never imports adapters or cli · F3 contexts
only via `index.ts`; `src/` and `dashboard/` never import each other · F4 no cycles · F5 I/O (also
aliased globals, `node:os`, computed imports, `eval`) only in `src/adapters`, `src/main.ts`,
`src/cli.ts`, `src/testing` · F6 Agent SDK only in `adapters/agent` · F7 files ≤ 300 lines,
functions ≤ 40 · F8 tests use `createTestEnv()` · F9 no GitHub token or permission bypass for
agents · F10 `gh` writes only in `src/adapters/github/gh-github-writer.ts` · F11 bash: no
`eval`/`sh -c`/`python -c` with expansions, no `curl | sh`, no `${{` · F12 dashboard layers;
subprocesses only in allowlisted services. Legacy bash and `dashboard/server.ts` debt is ratcheted
in `tools/arch/findings-baseline.json`: never add a finding; after removing some, run
`bun tools/arch/ast-scan.ts --write-baseline`. Never suppress a rule in place (`ast-grep-ignore` fails
the meta-test); rules, allowlists and baselines are CODEOWNERS-reviewed. Enforced later: F10 in full
(a `FenceToken` on run-scoped writes from Wave 1b; every integration by the end of Wave 2).
```

Then replace the last paragraph, `` `docs/architecture.md`, `docs/adr/`, generated `docs/reference/cli.md` (`bun run docs:gen`).``, with:

```markdown
`docs/architecture.md`, `docs/adr/`, generated `docs/reference/cli.md` and
`docs/reference/dependency-graph.md` (`bun run docs:gen`).
```

Keep the `## Safety` bullets; the F9 bullet stays true.

- [ ] **Step 3: Replace the fitness subsection of `docs/architecture.md`; link the ADR and the graph**

Replace everything from `### Fitness rules` up to, not including, `## Claude access` with:

```markdown
### Fitness rules

Enforced by `bun run arch` (part of `bun run check`). Every failure names the rule and the fix.
Why there are so many, and how ratchets work: [ADR-0008](adr/0008-fitness-functions-everywhere.md).
The current import graph is generated: [`docs/reference/dependency-graph.md`](reference/dependency-graph.md).

| # | Rule | Tool |
|---|---|---|
| F1 | Domain (and the kernel) is pure: no I/O, no Node or Bun built-ins | dependency-cruiser |
| F2 | Application never imports `adapters/` or `cli/` | dependency-cruiser |
| F3 | Contexts meet only at `index.ts`; production code never imports `src/testing/`; `src/` never imports `dashboard/` | dependency-cruiser |
| F4 | No import cycles | dependency-cruiser |
| F5 | I/O only in `src/adapters`, `src/main.ts`, `src/cli.ts` and `src/testing`: `Bun` members, `fetch`, `process.env`, `node:fs`, `node:os`, `node:process`, network modules; also `Bun`/`process`/`globalThis` used as values, `globalThis?.x`/`global.x`, `import.meta.env`, computed `import()`/`require()`, `eval`/`Function`, `new Worker`/`WebSocket` | ast-grep |
| F6 | The Agent SDK is imported only by `adapters/agent/` | ast-grep |
| F7 | Files ≤ 300 lines, functions ≤ 40; the baseline may only shrink | size ratchet |
| F8 | Tests use `createTestEnv()` paths, never the real home or environment | ast-grep |
| F9 | No permission-bypass spelling (substring, template or `+` pieces) and no GitHub token name in `src/` or `dashboard/` (tests, `adapters/github` and `adapters/agent/privilege-guard.ts` excepted); SDK calls pass a literal `env:` and a literal `permissionMode`; `assertAgentOptions()` refuses both at run time; `agentEnv()` drops the tokens. Bash: bypass flags and `claude` without `env -u GH_TOKEN -u GITHUB_TOKEN`, ratcheted | ast-grep, unit tests, findings ratchet |
| F10 | `gh` write subcommands only in `src/adapters/github/gh-github-writer.ts`. Bash (`gh` writes, `gh api` writes, `git push`): ratcheted | ast-grep, findings ratchet |
| F11 | Bash: no `eval`/`command eval`/`source /dev/stdin <<<` with an expansion; no `sh -c`, `"$SHELL" -c`, `python -c`, `node -e`, here-string into a shell or `ssh host "cmd $x"` built from data; no download run as code; no `${{` | ast-grep (Bash), findings ratchet |
| F12 | Dashboard: browser bundle and server never import each other and neither imports `src/` (D1); `services/` is the bottom layer (D2); routes never import `server.ts` or each other (D3); no cycles (D4); processes are spawned only by allowlisted services, and shell strings are constant | dependency-cruiser, ast-grep, findings ratchet |

Bash rules cover `scripts/**/*.sh`, `scripts/sw`, `.claude/hooks`, `claude-code/hooks`,
`completions/*.bash` and `install.sh`.

**Ratchets.** Existing violations of F9–F12 are counted per rule and file in
[`findings-baseline.json`](../tools/arch/findings-baseline.json) by
[`ast-scan.ts`](../tools/arch/ast-scan.ts), which runs every ast-grep rule over the files git knows
(never a directory walk). Counts may only go down: a new file or a higher count fails, and so does a
count that dropped without tightening the baseline. A rule that reaches zero keeps an empty entry,
which fails the meta-test until the rule is promoted to `severity: error`. In CI,
`--against origin/<base>` also fails when this baseline or `arch-baseline.json` gained an entry or a
count against the merge base, so a baseline cannot be raised in the same PR that adds the debt.

**Meta-checks** ([`meta.test.ts`](../tools/arch/meta.test.ts),
[`depcruise-rules.test.ts`](../tools/arch/depcruise-rules.test.ts)): every ast-grep rule has a rule
test with valid and invalid cases, a message that starts with its family and names a fix, an owner,
a docs anchor here, and `files` that match a tracked file; the rule set, the ratcheted set and every
allowlist (`ignores`) are pinned; no `ast-grep-ignore` comment exists; every dependency-cruiser rule
fires on a fixture; `bun run arch` runs every checker. [`CODEOWNERS`](../.github/CODEOWNERS) puts
`tools/arch/`, `sgconfig.yml`, the dependency-cruiser configs and `package.json` under the
maintainer's review.

Workflows: no `${{ }}` expression of any kind inside a `run:` script or an `actions/github-script`
`script:` body; values go through `env:`. This check is strict, with no baseline.

Config: [`.dependency-cruiser.cjs`](../.dependency-cruiser.cjs),
[`.dependency-cruiser.dashboard.cjs`](../.dependency-cruiser.dashboard.cjs),
[`sgconfig.yml`](../sgconfig.yml) with [`tools/arch/rules/`](../tools/arch/rules) and
[`tools/arch/utils/`](../tools/arch/utils), [`tools/arch/size-ratchet.ts`](../tools/arch/size-ratchet.ts)
with [`arch-baseline.json`](../tools/arch/arch-baseline.json),
[`tools/arch/workflow-injection.ts`](../tools/arch/workflow-injection.ts).
```

In the `## Decisions` list, add after the `0007` line:

```markdown
- [0008 Fitness functions everywhere, with ratchets for legacy code](adr/0008-fitness-functions-everywhere.md)
```

Replace the last line, ``Generated reference: [`docs/reference/cli.md`](reference/cli.md) (`bun run docs:gen`).``, with:

```markdown
Generated reference: [`docs/reference/cli.md`](reference/cli.md) and
[`docs/reference/dependency-graph.md`](reference/dependency-graph.md) (`bun run docs:gen`).
```

- [ ] **Step 4: Update spec §3.3**

In `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md`, replace the two table rows that start `| F9 |` and `| F10 |` with:

```markdown
| F9 | Agents get no GitHub token and no permission bypass (see below). *Enforced from Wave 1a-arch; bash callers ratcheted.* |
| F10 | GitHub side effects go only through a fenced, idempotent adapter (see below). *`gh` writes confined to the writer from Wave 1a; bash writes (`gh`, `gh api`, `git push`) ratcheted; every integration by the end of Wave 2.* |
| F11 | Bash safety: no `eval`, `sh -c`, interpreter `-c`/`-e`, here-string or `ssh` command string built from an expansion; no download run as code; no `${{` in scripts, hooks, completions or `install.sh`. *Ratcheted from Wave 1a-arch.* |
| F12 | Dashboard boundaries: browser bundle and server are separate and neither imports `src/`; `services/` is the bottom layer; routes are independent; no cycles; only allowlisted services spawn processes. *From Wave 1a-arch; `server.ts` ratcheted until the Wave 3 port.* |

Every rule has a rule test with valid and invalid cases, a message that names the fix, an owner and
a docs anchor, and every dependency-cruiser rule fires on a fixture (`tools/arch/meta.test.ts`,
`tools/arch/depcruise-rules.test.ts`). Existing violations of F9–F12 are counted per rule and file in
`tools/arch/findings-baseline.json` and may only go down, including against the PR's merge base
(ADR-0008). Rules are never suppressed in place.
```

In the **F9** block below the table, replace:

```markdown
- *How:*
  - an ast-grep rule over `src/**` and `.github/workflows/**`, which bans those names and the token
    names under `adapters/agent/**`;
  - the `agentEnv` unit test, which asserts that tokens are dropped.
- *Status:* the Wave 0 runner already uses an allowlist and `permissionMode: "dontAsk"`.
```

with:

```markdown
- *How:*
  - `F9-no-agent-privilege` (ast-grep) flags any string, template piece, identifier or key that
    contains a bypass spelling or a GitHub token name (`GH_TOKEN`, `GITHUB_TOKEN`,
    `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`), and `+` concatenations that spell one, in
    `src/**` and `dashboard/**` except tests, `src/adapters/github/**` and the runtime guard;
  - `F9-agent-options-explicit` requires every SDK call to pass a literal `env:` (never
    `process.env`) and a string-literal `permissionMode`;
  - `assertAgentOptions()` refuses a bypass or a token at run time, and the `agentEnv` unit test
    asserts that every token is dropped;
  - bash: `F9-bash-no-permission-bypass` and `F9-bash-claude-token-scrub`, ratcheted.
- *Status:* enforced from Wave 1a-arch. Workflow files carry none of the names today; a workflow
  check joins when one is needed.
```

At the end of §3.3, replace `request data. That rule lands with the dashboard hardening item (Wave 1).` with:

```markdown
request data. That rule lands with the dashboard hardening item (Wave 1a); F12 adds the dashboard's
layering and the subprocess allowlist (Wave 1a-arch).
```

- [ ] **Step 5: Check sizes, anchors and links**

```bash
wc -l AGENTS.md docs/adr/0008-fitness-functions-everywhere.md
grep -c 'F9-agent-options-explicit' docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md
bun test tools/arch/meta.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
for f in tools/arch/findings-baseline.json tools/arch/ast-scan.ts .dependency-cruiser.dashboard.cjs tools/arch/utils .github/CODEOWNERS \
  docs/reference/dependency-graph.md docs/adr/0008-fitness-functions-everywhere.md; do test -e "$f" || echo "missing $f"; done
```

Expected:
- `AGENTS.md` about 80 lines (78 on the dry run, which lacked Task 17's two-line Safety bullet).
- `46 docs/adr/0008-fitness-functions-everywhere.md`.
- `1`.
- The meta-test still passes (the `fitness-rules` anchor exists): `0 fail`.
- No `missing` lines.

- [ ] **Step 6: Run the definition of done**

```bash
bun run format && git add AGENTS.md docs/architecture.md docs/adr/0008-fitness-functions-everywhere.md \
  docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 7: Commit**

```bash
git commit -m "docs: ADR-0008 fitness functions everywhere; F9 enforced, F11 and F12 added" -- \
  AGENTS.md docs/architecture.md docs/adr/0008-fitness-functions-everywhere.md \
  docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md
```

---

### Task 8: Independent verification and hand-off (then Wave 1a Task 18)

**Files:** none

- [ ] **Step 1: Time the check against Task 0**

```bash
for i in 1 2 3; do /usr/bin/time -p bun run arch > /dev/null 2> "$TMPDIR/arch-time.txt"; grep real "$TMPDIR/arch-time.txt"; done
/usr/bin/time -p bun tools/arch/ast-scan.ts 2>&1 | grep real
time bun run check
```

Expected:
- `bun run arch` about 1.4 s (1.37–1.39 s on the dry run, from 0.75 s).
- The full ast-grep scan about 0.3 s.
- `bun run check` about 1.3 s above Task 0's time (9.9–10.3 s against 8.7–8.8 s on the dry run).

If the scan takes more than 1 s, investigate before handing off.

- [ ] **Step 2: Dispatch the `verifier` subagent**

Prompt: "Verify Wave 1a-arch on branch `wave1/safety` against `docs/superpowers/plans/2026-10-14-wave-1a-arch-fitness.md`. Run `bun run check`. Try to break each rule, and revert every probe from a backup copy (never `git checkout` a file you did not change):
- Add each of these to a script with no findings and confirm `bun run arch` fails and prints the rule's fix: `eval "$x"`, `command eval "$x"`, `bash -c "$y"`, `"$SHELL" -c "$y"`, `python3 -c "print($x)"`, `ssh h "cd $d && x"`, `curl … | env bash`, `source <(curl …)`, `${{ github.event.issue.title }}`, `--dangerously-skip-permissions`, `claude -p x`, `gh issue comment`, `gh repo delete`, `git push`.
- Write `"bypass" + "Permissions"`, `` `--dangerously-${x}` `` and `GH_TOKEN` in `src/adapters/agent`.
- Alias `const b = Bun`, read `globalThis?.process` and call `(0, eval)` in a domain file.
- Import `routes/` from `dashboard/services`, and `src/` from `dashboard/`.
- Destructure `spawn` from `Bun` in `dashboard/services/db.ts`.
- Add an `ast-grep-ignore` comment; add a path to a rule's `ignores`; delete a rule test; raise a baseline and run `--against HEAD`; edit `docs/reference/dependency-graph.md`.

Each must fail." Expected: `PASS` with evidence. On `FAIL`, fix and re-run, up to three cycles; then report what remains.

- [ ] **Step 3: Hand off to Wave 1a Task 18**

Report:
- the commits;
- the per-rule baseline totals from Task 4 Step 8 and Task 5 Step 6;
- the timing.

Ask the maintainer to enable "Require review from Code Owners" for `main` (Settings → Branches), so `.github/CODEOWNERS` gates the fitness functions. Do not push; Wave 1a Task 18 verifies, reviews and pushes the whole branch, including this plan's commits.
