import { describe, expect, test } from "bun:test";
import { fuzzCorpus, fuzzDivergences } from "./classify-fuzz";

describe("#8709 round-7 fuzz corpus (#8715)", () => {
  test("the generator is deterministic and yields 1786 rows", () => {
    const rows = fuzzCorpus();
    expect(rows.length).toBe(1786);
    expect(fuzzCorpus()).toEqual(rows);
  });

  // The full run (both locales, ~1786 bash calls each) is `bun src/testing/fixtures/wave2/classify-fuzz.ts`.
  test("a fixed sample escalates the same in TS and in bash under C and UTF-8", () => {
    const sample = fuzzCorpus().filter((_, i) => i % 9 === 0);
    expect(fuzzDivergences(sample)).toEqual([]);
  }, 120_000);
});
