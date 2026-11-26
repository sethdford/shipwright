import { describe, expect, test } from "bun:test";
import { parseLesson } from "./lesson";
import { type FailedRun, mineCandidates } from "./mine";

const run = (source: string, fingerprint: string, failureClass = "execution"): FailedRun => ({
  source,
  failureClass,
  fingerprint,
  log: `log of ${source}`,
});

describe("mineCandidates", () => {
  test("keeps recurring failures, most frequent first, with every source and the last log", () => {
    const got = mineCandidates(
      [
        run("r1", "a"),
        run("r2", "b"),
        run("r3", "b"),
        run("r4", "a"),
        run("r5", "b"),
        run("r6", "c"),
      ],
      [],
    );
    expect(got.map((c) => [c.fingerprint, c.count])).toEqual([
      ["b", 3],
      ["a", 2],
    ]);
    expect(got[0]?.sources).toEqual(["r2", "r3", "r5"]);
    expect(got[0]?.log).toBe("log of r5");
  });

  test("drops failures a lesson covers, in any status", () => {
    const retired = parseLesson(
      ".shipwright/lessons/L-0001.md",
      "---\nid: L-0001\nstatus: retired\nfingerprint: a\n---\nx",
    );
    expect(mineCandidates([run("r1", "a"), run("r2", "a")], [retired])).toEqual([]);
  });

  test("never mines classes a prompt cannot fix", () => {
    for (const cls of ["auth", "environment", "transient", "contamination", "budget", "refusal"]) {
      expect(mineCandidates([run("r1", "x", cls), run("r2", "x", cls)], [])).toEqual([]);
    }
  });

  test("honours minCount and limit; ties keep first-seen order", () => {
    const runs = [run("r1", "a"), run("r2", "b"), run("r3", "c")];
    expect(mineCandidates(runs, [], { minCount: 1, limit: 2 }).map((c) => c.fingerprint)).toEqual([
      "a",
      "b",
    ]);
  });
});
