import { describe, expect, test } from "bun:test";
import { modelOf } from "../../../testing/repo-model-fixture";
import { buildGraph, enclosingSymbol, findDefs, type RepoGraph } from "./graph";
import { entityIndex, localize } from "./localize";
import { rankFiles, topRanked } from "./rank";
import { renderBrief, renderMap } from "./render";
import { sourcesFor, testsFor } from "./tests-map";

const REPO = {
  "src/budget.ts": [
    "/** Blocks dispatch when the daily cap is spent. */",
    "export function evaluateBudget(spent: number, cap: number): boolean {",
    "  return spent < cap;",
    "}",
  ].join("\n"),
  "src/daemon.ts": [
    'import { evaluateBudget } from "./budget";',
    "export function dispatchIssue(n: number) {",
    "  if (!evaluateBudget(n, 3)) return;",
    "}",
  ].join("\n"),
  "src/tmux.ts": "export function openPane(name: string) {\n  return name;\n}\n",
  "src/budget.test.ts":
    'import { evaluateBudget } from "./budget";\ntest("x", () => evaluateBudget(1, 2));\n',
  "src/daemon.test.ts": 'import { dispatchIssue } from "./daemon";\n',
};

const graph: RepoGraph = buildGraph(modelOf(REPO));

describe("buildGraph", () => {
  test("definitions, imports and importers", () => {
    expect(findDefs(graph, "evaluateBudget").map((d) => d.path)).toEqual(["src/budget.ts"]);
    expect(graph.imports.get("src/daemon.ts")).toEqual(["src/budget.ts"]);
    expect(graph.importers.get("src/budget.ts")).toEqual(["src/budget.test.ts", "src/daemon.ts"]);
    expect(graph.referrers.get("evaluateBudget")).toContain("src/daemon.ts");
  });

  test("the enclosing definition of a line", () => {
    const daemon = graph.byPath.get("src/daemon.ts");
    expect(daemon && enclosingSymbol(daemon, 3)?.name).toBe("dispatchIssue");
  });
});

describe("rankFiles", () => {
  test("plain PageRank favors the file others depend on; seeds pull rank toward themselves", () => {
    expect(topRanked(rankFiles(graph), 1)[0]?.[0]).toBe("src/budget.ts");
    const seeded = rankFiles(graph, new Map([["src/tmux.ts", 1]]));
    expect(topRanked(seeded, 1)[0]?.[0]).toBe("src/tmux.ts");
    const total = [...rankFiles(graph).values()].reduce((a, b) => a + b, 0);
    expect(total).toBeCloseTo(1, 6);
  });
});

describe("localize", () => {
  test("prose finds the file and the definition, with the reason", () => {
    const located = localize(graph, entityIndex(graph), "Dispatch ignores the daily budget cap");
    expect(located[0]?.path).toBe("src/budget.ts");
    expect(located[0]?.symbols.map((s) => s.name)).toContain("evaluateBudget");
    expect(located[0]?.why.join(" ")).toContain("budget");
    expect(located.map((l) => l.path)).not.toContain("src/tmux.ts");
  });

  test("a name mentioned outright is the strongest signal", () => {
    const located = localize(graph, entityIndex(graph), "openPane crashes");
    expect(located[0]?.path).toBe("src/tmux.ts");
    expect(located[0]?.why).toContain("named in the task");
  });

  test("nothing matches: nothing is returned", () => {
    expect(localize(graph, entityIndex(graph), "zzz qqq")).toEqual([]);
  });
});

describe("tests map", () => {
  test("tests for a source file, and sources for a test", () => {
    expect(testsFor(graph, "src/budget.ts")).toEqual([
      { path: "src/budget.test.ts", via: "imports" },
    ]);
    expect(testsFor(graph, "src/tmux.ts")).toEqual([]);
    expect(sourcesFor(graph, "src/daemon.test.ts")).toEqual(["src/daemon.ts"]);
  });
});

describe("render", () => {
  test("the map lists ranked files with public definitions and counts what did not fit", () => {
    const text = renderMap(graph, topRanked(rankFiles(graph), 10), 120);
    expect(text.split("\n")[0]).toBe("src/budget.ts");
    expect(text).toContain("evaluateBudget");
    expect(text).toMatch(/… \d+ more files ranked lower/);
  });

  test("the brief names files, tests and owners, and the tools only when attached", () => {
    const located = localize(graph, entityIndex(graph), "daily budget cap");
    const input = {
      located,
      tests: new Map([
        ["src/budget.ts", [{ path: "src/budget.test.ts", via: "imports" as const }]],
      ]),
      owners: new Map([["src/budget.ts", ["@core"]]]),
      toolsAvailable: false,
      stats: { files: 5, symbols: 4 },
    };
    const brief = renderBrief(input);
    expect(brief).toContain("## Repository model");
    expect(brief).toContain("tests: src/budget.test.ts");
    expect(brief).toContain("owners: @core");
    expect(brief).not.toContain("repomodel");
    expect(renderBrief({ ...input, toolsAvailable: true })).toContain("`repomodel` tools");
    expect(renderBrief({ ...input, located: [] })).toBe("");
  });
});
