import { describe, expect, test } from "bun:test";
import { casesOf, scoreCase, summarize, titleOf } from "./history-eval";

const commit = (sha: string, subject: string, body: string, files: string[]) => ({
  sha: sha.padEnd(40, "0"),
  parent: "p".padEnd(40, "0"),
  subject,
  body,
  files,
});

describe("cases from history", () => {
  test("titles of merge and squash commits; other commits have none", () => {
    expect(titleOf("Merge pull request #7 from x/y", "\nfix(budget): stop at the cap\n")).toBe(
      "fix(budget): stop at the cap",
    );
    expect(titleOf("fix: a thing (#12)", "")).toBe("fix: a thing (#12)");
    expect(titleOf("docs: auto-sync documentation sections", "")).toBe("");
  });

  test("code PRs only; tests and docs leave the answer; chores and huge changes are skipped", () => {
    const cases = casesOf([
      commit("a1", "Merge pull request #1 from x", "fix(budget): stop at the cap", [
        "src/budget.ts",
        "src/budget.test.ts",
        "docs/x.md",
      ]),
      commit("b2", "chore: bump deps (#2)", "", ["src/a.ts"]),
      commit("c3", "fix: docs only (#3)", "", ["README.md"]),
      commit(
        "d4",
        "refactor: everything (#4)",
        "",
        Array.from({ length: 41 }, (_, i) => `src/f${i}.ts`),
      ),
    ]);
    expect(cases).toEqual([
      {
        id: "a10000000000",
        parent: "p".padEnd(40, "0"),
        task: "fix(budget): stop at the cap",
        gold: ["src/budget.ts"],
      },
    ]);
  });
});

describe("scoring", () => {
  const c = { id: "x", parent: "p", task: "t", gold: ["src/a.ts", "src/new.ts", "src/b.ts"] };
  const exists = (p: string) => p !== "src/new.ts";

  test("rank of the first findable gold file and recall in the top 10", () => {
    const r = scoreCase(c, exists, ["src/z.ts", "src/b.ts", "src/a.ts"]);
    expect(r.findable).toEqual(["src/a.ts", "src/b.ts"]);
    expect(r.firstHit).toBe(2);
    expect(r.recall10).toBe(1);
    expect(scoreCase(c, exists, ["src/z.ts"]).firstHit).toBeNull();
  });

  test("summary counts only cases with something findable", () => {
    const hit = scoreCase(c, exists, ["src/a.ts"]);
    const miss = scoreCase(c, exists, []);
    const none = scoreCase({ ...c, gold: ["src/new.ts"] }, exists, []);
    const s = summarize([hit, miss, none]);
    expect(s).toEqual({ cases: 2, acc1: 0.5, acc5: 0.5, acc10: 0.5, recall10: 0.25 });
  });
});
