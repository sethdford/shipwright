import { describe, expect, test } from "bun:test";
import { buildSemantic, searchSemantic } from "./lsa";
import { symmetricEigen } from "./lsa-math";

const doc = (path: string, text: string) => ({ path, tokens: text.split(" ") });

// "spend" never appears with "ledger", but both co-occur with "budget" and "cap": LSA bridges them.
const DOCS = [
  doc("budget.ts", "budget cap spend daily budget cap"),
  doc("cost.ts", "budget cap ledger cost budget"),
  doc("ledger.ts", "ledger cost cap entry ledger"),
  doc("alerts.ts", "spend daily alert budget cap"),
  doc("tmux.ts", "pane window session tmux pane"),
  doc("layout.ts", "pane window layout split"),
  doc("session.ts", "session tmux attach window"),
  doc("auth.ts", "token login user session auth"),
  doc("user.ts", "user login profile token"),
];

describe("semantic index (LSA)", () => {
  const index = buildSemantic(DOCS, 3);

  test("finds documents that share no word with the query through co-occurring terms", () => {
    const hits = searchSemantic(index, "spend", 9).map((h) => h.path);
    expect(hits.slice(0, 4)).toContain("cost.ts");
    expect(hits.indexOf("cost.ts")).toBeLessThan(hits.indexOf("tmux.ts"));
  });

  test("ranks the topic's files above unrelated ones", () => {
    const hits = searchSemantic(index, "window pane", 3).map((h) => h.path);
    expect(hits).toEqual(expect.arrayContaining(["tmux.ts", "layout.ts"]));
    expect(hits).not.toContain("budget.ts");
  });

  test("unknown words and tiny corpora give nothing", () => {
    expect(searchSemantic(index, "zebra", 5)).toEqual([]);
    expect(buildSemantic([doc("a.ts", "x y")]).dims).toBe(0);
  });

  test("deterministic: the same input gives the same vectors", () => {
    const again = buildSemantic(DOCS, 3);
    expect([...(again.vectors[0] ?? [])]).toEqual([...(index.vectors[0] ?? [])]);
  });
});

test("symmetricEigen: A v = λ v", () => {
  const a = [
    [2, 1, 0],
    [1, 2, 0],
    [0, 0, 5],
  ];
  const { values, vectors } = symmetricEigen(a.map((r) => Float64Array.from(r)));
  expect(values.map((x) => Math.round(x * 1e6) / 1e6).sort()).toEqual([1, 3, 5]);
  for (let c = 0; c < 3; c += 1)
    for (let i = 0; i < 3; i += 1) {
      const row = a[i] ?? [];
      const av = row.reduce((s, x, j) => s + x * ((vectors[j] ?? [])[c] ?? 0), 0);
      expect(av).toBeCloseTo((values[c] ?? 0) * ((vectors[i] ?? [])[c] ?? 0), 6);
    }
});
