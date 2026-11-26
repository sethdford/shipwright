import { expect, test } from "bun:test";
import { parseLog } from "./git-history-source";

test("parseLog reads first-parent records and skips malformed ones", () => {
  const a = "a".repeat(40);
  const p = "b".repeat(40);
  const out = `${a}\x1f${p} ${"c".repeat(40)}\x1fMerge pull request #1 from x\x1f\nfix: y\n\x1e\nnot-a-sha\x1f\x1fx\x1f\x1e`;
  expect(parseLog(out)).toEqual([
    { sha: a, parent: p, subject: "Merge pull request #1 from x", body: "fix: y" },
  ]);
});
