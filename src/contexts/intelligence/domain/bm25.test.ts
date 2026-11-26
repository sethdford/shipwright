import { describe, expect, test } from "bun:test";
import { buildBm25, searchBm25, tokenize } from "./bm25";

describe("tokenize", () => {
  test("splits camelCase, snake_case and paths, lower-cases and stems lightly", () => {
    expect(tokenize("evaluateBudget evaluate_budgets src/HTTPServer.ts")).toEqual([
      "evaluate",
      "budget",
      "evaluate",
      "budget",
      "http",
      "server",
    ]);
  });
});

describe("searchBm25", () => {
  test("ranks the document that shares the rarer terms first and drops non-matches", () => {
    const idx = buildBm25([
      { item: "budget", tokens: tokenize("evaluateBudget daily cap spend") },
      { item: "intake", tokens: tokenize("evaluateIntake issue labels") },
      { item: "other", tokens: tokenize("tmux session") },
    ]);
    const hits = searchBm25(idx, "budget cap", 5);
    expect(hits.map((h) => h.item)).toEqual(["budget"]);
    expect(
      searchBm25(idx, "evaluate", 5)
        .map((h) => h.item)
        .sort(),
    ).toEqual(["budget", "intake"]);
  });
});
