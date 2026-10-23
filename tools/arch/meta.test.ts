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
import { RUNTIME_STATE_PATTERNS, runtimeStateViolations, trackedInIndex } from "./runtime-state";

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
 * The rule set, which rules are ratcheted, and every allowlist (`files` and `ignores`). A change here
 * widens or narrows what `bun run arch` enforces, so it is reviewed by the CODEOWNERS of tools/arch
 * (ADR-0008). `files` is pinned too: narrowing a rule's coverage must fail this test.
 */
const BASH_FILES = [
  "scripts/**/*.sh",
  "scripts/sw",
  ".claude/hooks/**/*.sh",
  "claude-code/hooks/**/*.sh",
  "completions/**/*.bash",
  "install.sh",
];
const PINNED: Record<string, { ratchet: boolean; files: string[]; ignores: string[] }> = {
  "F5-io-only-in-adapters": {
    ratchet: false,
    files: ["src/**/*.ts"],
    ignores: ["src/adapters/**", "src/testing/**", "src/main.ts", "src/cli.ts", "src/**/*.test.ts"],
  },
  "F6-agent-sdk-only-in-adapter": {
    ratchet: false,
    files: ["src/**/*.ts"],
    ignores: ["src/adapters/agent/**"],
  },
  "F8-tests-no-real-home": {
    ratchet: false,
    files: ["src/**/*.test.ts", "tools/**/*.test.ts"],
    ignores: ["src/testing/test-env.test.ts"],
  },
  "F9-agent-options-explicit": {
    ratchet: false,
    files: [
      "src/adapters/agent/**/*.ts",
      "src/adapters/agent/**/*.mts",
      "src/adapters/agent/**/*.cts",
    ],
    ignores: ["**/*.test.ts"],
  },
  "F9-sdk-query-single-importer": {
    ratchet: false,
    files: [
      "src/**/*.ts",
      "src/**/*.mts",
      "src/**/*.cts",
      "dashboard/**/*.ts",
      "dashboard/**/*.mts",
      "dashboard/**/*.cts",
      "tools/**/*.ts",
      "tools/**/*.mts",
      "tools/**/*.cts",
    ],
    ignores: ["src/adapters/agent/agent-sdk-runner.ts"],
  },
  "F9-sdk-query-single-importer-tsx": {
    ratchet: false,
    files: ["src/**/*.tsx", "dashboard/**/*.tsx", "tools/**/*.tsx"],
    ignores: ["src/adapters/agent/agent-sdk-runner.ts"],
  },
  "F9-no-agent-privilege-tsx": {
    ratchet: false,
    files: ["src/**/*.tsx", "dashboard/**/*.tsx"],
    ignores: ["**/*.test.tsx", "src/adapters/github/**", "src/adapters/agent/privilege-guard.ts"],
  },
  "F9-agent-options-explicit-tsx": {
    ratchet: false,
    files: ["src/adapters/agent/**/*.tsx"],
    ignores: ["**/*.test.tsx"],
  },
  "F9-no-agent-privilege": {
    ratchet: false,
    files: [
      "src/**/*.ts",
      "src/**/*.mts",
      "src/**/*.cts",
      "dashboard/**/*.ts",
      "dashboard/**/*.mts",
      "dashboard/**/*.cts",
    ],
    ignores: ["**/*.test.ts", "src/adapters/github/**", "src/adapters/agent/privilege-guard.ts"],
  },
  "F10-github-writes-only-in-writer": {
    ratchet: false,
    files: ["src/**/*.ts", "src/**/*.tsx", "src/**/*.mts", "src/**/*.cts"],
    ignores: [
      "src/adapters/github/gh-github-writer.ts",
      "src/adapters/github/gh-github-writer.test.ts",
    ],
  },
  "F10-github-writes-only-in-writer-tsx": {
    ratchet: false,
    files: ["src/**/*.tsx"],
    ignores: [
      "src/adapters/github/gh-github-writer.ts",
      "src/adapters/github/gh-github-writer.test.ts",
    ],
  },
  "F9-bash-claude-token-scrub": { ratchet: false, files: BASH_FILES, ignores: [] },
  "F9-bash-no-permission-bypass": { ratchet: true, files: BASH_FILES, ignores: [] },
  "F10-bash-github-writes": { ratchet: true, files: BASH_FILES, ignores: [] },
  "F10-bash-curl-github-writes": { ratchet: true, files: BASH_FILES, ignores: [] },
  "F11-bash-no-eval-expansion": { ratchet: true, files: BASH_FILES, ignores: [] },
  "F11-bash-no-gha-expression": { ratchet: true, files: BASH_FILES, ignores: [] },
  "F11-bash-no-grep-q-in-pipe": { ratchet: false, files: BASH_FILES, ignores: [] },
  "F11-bash-no-bsd-date": { ratchet: false, files: BASH_FILES, ignores: ["scripts/lib/compat.sh"] },
  "F11-bash-no-pipe-to-shell": { ratchet: true, files: BASH_FILES, ignores: [] },
  "F11-bash-no-shell-c-expansion": { ratchet: true, files: BASH_FILES, ignores: [] },
  "dashboard-subprocess-only-in-services": {
    ratchet: true,
    files: ["dashboard/**/*.ts"],
    ignores: [
      "dashboard/**/*.test.ts",
      "dashboard/src/**",
      "dashboard/services/claims.ts",
      "dashboard/services/subprocess-guards.ts",
    ],
  },
  "dashboard-no-raw-command-runner": {
    ratchet: false,
    files: ["dashboard/**/*.ts", "dashboard/**/*.mts", "dashboard/**/*.cts"],
    ignores: ["dashboard/services/claims.ts"],
  },
  "dashboard-no-raw-command-runner-tsx": {
    ratchet: false,
    files: ["dashboard/**/*.tsx"],
    ignores: ["dashboard/services/claims.ts"],
  },
  "dashboard-no-shell-from-data": {
    ratchet: false,
    files: ["dashboard/**/*.ts"],
    ignores: ["dashboard/**/*.test.ts", "dashboard/src/**"],
  },
};

/** Every checker `bun run arch` must run. */
const ARCH_STEPS = [
  "depcruise src --config .dependency-cruiser.cjs",
  "depcruise dashboard --config .dependency-cruiser.dashboard.cjs",
  "bun tools/arch/ast-scan.ts",
  "ast-grep test --skip-snapshot-tests --include-off",
  "bun tools/arch/size-ratchet.ts",
  "bun tools/arch/workflow-injection.ts",
  "bun tools/arch/workflow-fail-closed.ts",
  "bun tools/arch/test-isolation.ts",
  "bun tools/arch/runtime-state.ts",
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
      test("coverage (files) and allowlist (ignores) match the pinned snapshot", () => {
        expect([...(rule.files ?? [])]).toEqual(PINNED[rule.id]?.files ?? ["<not pinned>"]);
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

test("every Bash rule covers the same files (scripts, hooks, completions, install.sh)", () => {
  const bash = rules.filter((r) => r.language === "Bash");
  expect(bash.length).toBeGreaterThan(0);
  for (const r of bash) expect(r.files).toEqual(bash[0]?.files ?? []);
});

test("every rule test belongs to a rule (ast-grep silently skips orphans)", () => {
  const ids = new Set(rules.map((r) => r.id));
  expect(tests.filter((t) => !ids.has(t.id)).map((t) => t.file)).toEqual([]);
});

/**
 * Every tracked file any rule covers. The ignore ban scans this set, so a rule's reach and the
 * suppression check cannot drift apart (a Bash rule covering install.sh must ban ignores there too).
 * docs/ is outside every rule and is not scanned, so this file's own prose does not trip the ban.
 */
const ruleCovered = (): string[] =>
  tracked.filter((f) => rules.some((r) => (r.files ?? []).some((g) => new Bun.Glob(g).match(f))));

test("no rule is suppressed in place (no ast-grep ignore comment in any file a rule covers)", async () => {
  const marker = ["ast", "grep", "ignore"].join("-");
  const hits: string[] = [];
  // Rule and rule-test files are not scanned by any rule, but ast-grep reads both: a marker in one
  // of them would switch off a check, so they are in the ban too (ADR-0008 "Known evasions").
  const ruleFiles = [
    ...tracked.filter((f) => /^tools\/arch\/(rules|rule-tests|utils)\/.*\.ya?ml$/.test(f)),
  ];
  for (const f of [...ruleCovered(), ...ruleFiles]) {
    if ((await Bun.file(join(ROOT, f)).text()).includes(marker)) hits.push(f);
  }
  expect(hits).toEqual([]);
});

test("the ignore ban reaches every file the Bash rules cover, including install.sh and completions", () => {
  const covered = new Set(ruleCovered());
  expect(covered.has("install.sh")).toBe(true);
  expect(covered.has("claude-code/hooks/notify-idle.sh")).toBe(true);
  expect(covered.has("scripts/sw")).toBe(true);
});

test("the SDK runner asserts the exact options object it passes to query (F9, ADR-0008)", async () => {
  const src = await Bun.file(join(ROOT, "src/adapters/agent/agent-sdk-runner.ts")).text();
  const assertAt = src.indexOf("assertAgentOptions(sdkOptions)");
  const queryAt = src.indexOf("this.queryFn({ prompt, options: sdkOptions })");
  expect(assertAt).toBeGreaterThan(-1);
  expect(queryAt).toBeGreaterThan(assertAt);
});

test("the SDK runner has exactly one query call, and it is the asserted one (F9, ADR-0008)", async () => {
  const raw = await Bun.file(join(ROOT, "src/adapters/agent/agent-sdk-runner.ts")).text();
  const src = raw
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");
  // Every reference to the SDK function, not just call-shaped ones: `.call(…)`, `const q = this.queryFn`
  // and `q(…)` are references too. The expected references are the import, the constructor default
  // (`= query`), the field and its single call; any other use fails.
  expect(src.match(/\bquery\b/g)?.length ?? 0).toBe(2);
  expect(src.match(/\bqueryFn\b/g)?.length ?? 0).toBe(2);
  expect(src.match(/this\.queryFn\(/g)?.length ?? 0).toBe(1);
  expect(src.match(/assertAgentOptions\(/g)?.length ?? 0).toBe(1);
});

test("allowlisted dashboard services export no raw command runner (F12, ADR-0008)", async () => {
  for (const file of ["dashboard/services/claims.ts", "dashboard/services/subprocess-guards.ts"]) {
    const src = await Bun.file(join(ROOT, file)).text();
    expect({ file, raw: /\bexport\b[^;\n]*\bdefaultRunner\b/.test(src) }).toEqual({
      file,
      raw: false,
    });
  }
});

/** The SDK-boundary rules: each has a TypeScript rule (.ts, .mts, .cts) and a Tsx copy (.tsx). */
const F9_SDK_RULES = [
  "F9-sdk-query-single-importer",
  "F9-no-agent-privilege",
  "F9-agent-options-explicit",
];

test("F9 covers .ts, .mts and .cts, and .tsx through a Tsx-language copy (ADR-0008)", () => {
  const byId = new Map(rules.map((r) => [r.id, r]));
  const covers = (r: RuleDoc | undefined, path: string) =>
    (r?.files ?? []).some((g) => new Bun.Glob(g).match(path));
  for (const id of F9_SDK_RULES) {
    for (const ext of ["ts", "mts", "cts"]) {
      expect({ id, ext, covered: covers(byId.get(id), `src/adapters/agent/b.${ext}`) }).toEqual({
        id,
        ext,
        covered: true,
      });
    }
    const copy = byId.get(`${id}-tsx`);
    expect(copy?.language).toBe("Tsx");
    expect(covers(copy, "src/adapters/agent/b.tsx")).toBe(true);
  }
});

/**
 * The validated operations claims.ts exports (its runtime exports). A new export, an aliased runner or
 * a re-export shows up here, so a route cannot reach the raw runner through claims.ts (ADR-0008).
 */
const CLAIMS_EXPORTS = [
  "MACHINE_NAME_RE",
  "REPO_RE",
  "ghIssueEditLabelArgv",
  "ghIssueLabelsArgv",
  "ghLabelCreateArgv",
  "ghListClaimedIssuesArgv",
  "handleClaim",
  "handleClaimRelease",
  "isValidMachineName",
  "isValidRepo",
  "parseIssueNumber",
  "releaseStaleClaims",
];

test("claims.ts exports exactly its validated operations (no raw runner, no alias)", async () => {
  const claims = await import(join(ROOT, "dashboard/services/claims.ts"));
  expect(Object.keys(claims).sort()).toEqual(CLAIMS_EXPORTS);
});

/**
 * `bun run arch` is exactly the checkers, in order, joined by `&&`: a substring match let a step
 * followed by `|| true` or `; echo` pass. Any other shell operator fails the test.
 */
test("bun run arch runs every checker as a hard && step, with no operator that can swallow a failure", () => {
  expect(archScript.split(" && ")).toEqual(ARCH_STEPS);
  expect(archScript).not.toMatch(/\|\||;|\||(?<!&)&(?!&)|\$\(|`|\n/);
});

/** Runtime state under .claude/ (loop logs, caches, evidence) is never tracked (#8665). */
test("the runtime-state list is pinned and only matches runtime paths", () => {
  expect(RUNTIME_STATE_PATTERNS.map((p) => p.source)).toEqual([
    "^\\.claude\\/loop-logs\\/",
    "^\\.claude\\/test-holdout\\/",
    "^\\.claude\\/evidence\\/[^/]+\\.json$",
    "^\\.claude\\/(pipeline-artifacts|worktrees)\\/",
    "^\\.claude\\/(loop-state\\.md|pipeline-state\\.md|platform-hygiene\\.json|intelligence-cache\\.json)$",
    "^\\.claude\\/(recovery-state\\.json|daemon-config\\.json|code-review\\.json|hygiene-report\\.json|pr-draft\\.md)$",
  ]);
  expect(
    runtimeStateViolations([
      ".claude/loop-logs/iteration-1.log",
      ".claude/evidence/manifest.json",
      ".claude/intelligence-cache.json",
      ".claude/test-holdout/manifest.json",
    ]),
  ).toHaveLength(4);
  expect(
    runtimeStateViolations([
      ".claude/settings.json",
      ".claude/DEFINITION-OF-DONE.md",
      ".claude/agents/porter.md",
      ".claude/hooks/guard.sh",
      ".claude/rules/bash.md",
      ".claude/quality-profile.json",
      "scripts/sw-loop.sh",
    ]),
  ).toEqual([]);
});

test("no runtime state under .claude/ is tracked in the git index (#8665)", () => {
  expect(runtimeStateViolations(trackedInIndex())).toEqual([]);
});
