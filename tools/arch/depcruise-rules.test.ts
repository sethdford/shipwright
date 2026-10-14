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
