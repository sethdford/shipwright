import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { baselineAt, risesAgainst } from "./baseline-history";
import { checkFindings } from "./findings-ratchet";

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

test("a rule key the base has but HEAD lacks is a rename or removal, which launders debt", () => {
  // Renaming a rule and re-seeding its findings under the new id must not pass --against.
  expect(risesAgainst({ R1: { "a.sh": 2 }, R2: {} }, { R1: { "a.sh": 2 } })).toEqual([
    "R2 is missing from the baseline: a rule was renamed or removed. Keep its key (an empty object when it reached zero)",
  ]);
  // A key that reached zero is still present, so it is not a removal.
  expect(risesAgainst({ R1: { "a.sh": 2 } }, { R1: {} })).toEqual([]);
});

test("a promotion (a rule at zero becomes severity: error) may drop its key", () => {
  const base = { X: {}, Y: { "a.sh": 1 } };
  const head = { Y: { "a.sh": 1 } };
  expect(risesAgainst(base, head, new Set(["X"]))).toEqual([]);
  // Without the promotion, the same drop is a rename or removal.
  expect(risesAgainst(base, head)).toHaveLength(1);
});

test("a dropped key still fails when the rule was renamed, removed or is still ratcheted", () => {
  // Renamed: the old id is gone at HEAD, so it is not in the promoted set.
  expect(risesAgainst({ X: {}, Y: {} }, { Y: {} }, new Set(["Y2"]))).toHaveLength(1);
  // Removed entirely.
  expect(risesAgainst({ X: {} }, {}, new Set())).toHaveLength(1);
  // Still ratcheted (severity off) at HEAD: only severity: error ids are in the promoted set.
  expect(risesAgainst({ X: {} }, {}, new Set(["Z"]))).toHaveLength(1);
});

test("a promotion PR passes --against end to end (git history, then the ratchet's own check)", () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "promotion-")));
  git(dir, "init", "-q", "-b", "main");
  git(dir, "config", "user.email", "t@example.com");
  git(dir, "config", "user.name", "t");
  git(dir, "config", "commit.gpgsign", "false");
  git(dir, "config", "core.hooksPath", "/dev/null");
  writeFileSync(join(dir, "b.json"), JSON.stringify({ X: {}, Y: { "a.sh": 1 } }));
  git(dir, "add", "b.json");
  git(dir, "commit", "-qm", "base: X at zero, Y ratcheted");
  git(dir, "checkout", "-qb", "promote");
  // The promotion: X is now severity: error, so the baseline drops its key (checkFindings demands it).
  writeFileSync(join(dir, "b.json"), JSON.stringify({ Y: { "a.sh": 1 } }));
  git(dir, "commit", "-qam", "promote X");
  const base = baselineAt("main", "b.json", dir) ?? {};
  const head = JSON.parse(readFileSync(join(dir, "b.json"), "utf8"));
  expect(checkFindings({ Y: { "a.sh": 1 } }, head)).toEqual([]);
  expect(risesAgainst(base, head, new Set(["X"]))).toEqual([]);
});
