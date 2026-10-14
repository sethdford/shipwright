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
  "F9-bash-claude-token-scrub": { ratchet: true, ignores: [] },
  "F9-bash-no-permission-bypass": { ratchet: true, ignores: [] },
  "F10-bash-github-writes": { ratchet: true, ignores: [] },
  "F11-bash-no-eval-expansion": { ratchet: true, ignores: [] },
  "F11-bash-no-gha-expression": { ratchet: true, ignores: [] },
  "F11-bash-no-pipe-to-shell": { ratchet: true, ignores: [] },
  "F11-bash-no-shell-c-expansion": { ratchet: true, ignores: [] },
  "dashboard-subprocess-only-in-services": {
    ratchet: true,
    ignores: [
      "dashboard/**/*.test.ts",
      "dashboard/src/**",
      "dashboard/services/claims.ts",
      "dashboard/services/subprocess-guards.ts",
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
  "depcruise dashboard --config .dependency-cruiser.dashboard.cjs",
  "bun tools/arch/ast-scan.ts",
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

test("every Bash rule covers the same files (scripts, hooks, completions, install.sh)", () => {
  const bash = rules.filter((r) => r.language === "Bash");
  expect(bash.length).toBeGreaterThan(0);
  for (const r of bash) expect(r.files).toEqual(bash[0]?.files ?? []);
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
