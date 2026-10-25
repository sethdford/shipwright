import { expect, test } from "bun:test";
import { evaluate, gzipSize, loadBudget } from "./budget";

const budget = { js: { maxGzipBytes: 100 }, css: { maxGzipBytes: 50 } };

test("passes when JS and CSS are within budget", () => {
  expect(
    evaluate([{ name: "main.js", gzipBytes: 100 }], [{ name: "a.css", gzipBytes: 50 }], budget),
  ).toEqual([]);
});

test("reports each measure that exceeds its budget", () => {
  const violations = evaluate(
    [{ name: "main.js", gzipBytes: 101 }],
    [{ name: "a.css", gzipBytes: 51 }],
    budget,
  );
  expect(violations).toHaveLength(2);
  expect(violations[0]).toContain("JS gzip 101 B exceeds budget 100 B");
  expect(violations[1]).toContain("CSS gzip 51 B exceeds budget 50 B");
});

test("sums every file of a kind before comparing", () => {
  const js = [
    { name: "a.js", gzipBytes: 60 },
    { name: "b.js", gzipBytes: 60 },
  ];
  expect(evaluate(js, [], budget)).toHaveLength(1);
});

test("gzip size is smaller than the input for repetitive text", () => {
  expect(gzipSize(new TextEncoder().encode("a".repeat(10_000)))).toBeLessThan(200);
});

test("the committed budget.json declares both ceilings", () => {
  const committed = loadBudget();
  expect(committed.js.maxGzipBytes).toBeGreaterThan(0);
  expect(committed.css.maxGzipBytes).toBeLessThanOrEqual(25 * 1024);
});
