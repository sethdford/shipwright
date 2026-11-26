import { describe, expect, test } from "bun:test";
import { parseLesson } from "../domain/lesson";
import { mineDrafts } from "./learn";

const mk = (n: number) =>
  `running\nscripts/a-test.sh: line ${n}: mktemp: failed to create directory /tmp/claude/x-${n}: No such file\n`;

describe("mineDrafts", () => {
  test("drafts one proposed lesson per recurring failure, with ids after the existing ones", () => {
    const existing = [
      parseLesson(".shipwright/lessons/L-0004.md", "---\nid: L-0004\nstatus: active\n---\nx"),
    ];
    const drafts = mineDrafts(existing, [
      { source: "run-1", log: mk(1) },
      { source: "run-2", log: mk(22) },
      { source: "run-3", log: "Error: Invalid API key" },
    ]);
    expect(drafts.map((d) => [d.draft.id, d.candidate.count])).toEqual([["L-0005", 2]]);
    const back = parseLesson(drafts[0]?.draft.path ?? "", drafts[0]?.draft.markdown ?? "");
    expect(back).toMatchObject({ id: "L-0005", status: "proposed", source: "2 runs: run-1 run-2" });
  });

  test("nothing recurs, nothing is drafted", () => {
    expect(mineDrafts([], [{ source: "run-1", log: mk(1) }])).toEqual([]);
  });
});
