import { describe, expect, test } from "bun:test";
import { type Lesson, parseLesson, scoreLesson, selectLessons } from "./lesson";

function lesson(id: string, meta: string, body = "Do the thing."): Lesson {
  return parseLesson(`.shipwright/lessons/${id}.md`, `---\nid: ${id}\n${meta}\n---\n${body}\n`);
}

const ctx = {
  text: "Fix the mktemp failure in the heartbeat test",
  paths: ["scripts/sw-heartbeat-test.sh"],
};

describe("parseLesson", () => {
  test("reads the trigger fields and lower-cases keywords", () => {
    const l = lesson(
      "L-0001",
      "status: active\nfailure_class: test\nkeywords: [MkTemp]\nhypothesis: fewer test failures",
    );
    expect(l).toMatchObject({
      failureClass: "test",
      keywords: ["mktemp"],
      hypothesis: "fewer test failures",
    });
  });
});

describe("selectLessons", () => {
  test("only active lessons are selected", () => {
    const ls = [
      lesson("L-0001", "status: proposed"),
      lesson("L-0002", "status: retired"),
      lesson("L-0003", "status: active"),
    ];
    expect(selectLessons(ls, ctx).map((s) => s.lesson.id)).toEqual(["L-0003"]);
  });

  test("a lesson with triggers that none match is left out", () => {
    expect(selectLessons([lesson("L-0001", "status: active\napplies_to: [src/**]")], ctx)).toEqual(
      [],
    );
  });

  test("ranks fingerprint over class over paths over keywords, then by id", () => {
    const ls = [
      lesson("L-0004", "status: active\nkeywords: [mktemp]"),
      lesson("L-0003", "status: active\napplies_to: [scripts/**]"),
      lesson("L-0002", "status: active\nfailure_class: test"),
      lesson("L-0001", "status: active\nfingerprint: abc"),
      lesson("L-0005", "status: active"),
    ];
    const got = selectLessons(ls, { ...ctx, failureClass: "test", fingerprint: "abc" });
    expect(got.map((s) => s.lesson.id)).toEqual(["L-0001", "L-0002", "L-0003", "L-0004", "L-0005"]);
  });

  test("keeps at most the limit", () => {
    const ls = ["L-0001", "L-0002", "L-0003"].map((id) => lesson(id, "status: active"));
    expect(selectLessons(ls, ctx, 2)).toHaveLength(2);
  });

  test("keyword hits count at most three", () => {
    const l = lesson("L-0001", "status: active\nkeywords: [fix, the, mktemp, failure, heartbeat]");
    expect(scoreLesson(l, ctx).score).toBe(3);
  });
});
