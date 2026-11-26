import { describe, expect, test } from "bun:test";
import { extractFeatures, sizeFromLabels } from "./features";

describe("extractFeatures", () => {
  test("kind comes from labels first, then the title prefix", () => {
    expect(extractFeatures({ title: "feat: x", body: "", labels: ["bug"] }).kind).toBe("bug");
    expect(extractFeatures({ title: "docs: fix README", body: "", labels: [] }).kind).toBe("docs");
    expect(extractFeatures({ title: "Something", body: "", labels: [] }).kind).toBe("unknown");
  });

  test("counts named files, criteria and risky paths", () => {
    const body = [
      "Touch `src/main.ts`, src/cli/command.ts and .github/workflows/ci.yml.",
      "- [ ] one",
      "- [x] two",
    ].join("\n");
    const f = extractFeatures({ title: "t", body, labels: [] });
    expect(f.paths).toBe(3);
    expect(f.criteria).toBe(2);
    expect(f.riskyPaths).toEqual([".github/workflows/ci.yml"]);
  });

  test("finds easy and hard signals and stack traces", () => {
    const f = extractFeatures({
      title: "Fix typo",
      body: "Race condition during migration\n    at run (src/a.ts:1:2)",
      labels: [],
    });
    expect(f.easySignals).toEqual(["typo"]);
    expect(f.hardSignals).toEqual(["migration", "race condition"]);
    expect(f.stackTrace).toBe(true);
  });
});

test("size labels map to tiers; unknown sizes are ignored", () => {
  expect(sizeFromLabels(["size/XS"])).toBe("trivial");
  expect(sizeFromLabels(["difficulty: hard"])).toBe("large");
  expect(sizeFromLabels(["size/huge", "effort:m"])).toBe("medium");
  expect(sizeFromLabels(["bug"])).toBeUndefined();
});
