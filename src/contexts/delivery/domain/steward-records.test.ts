import { expect, test } from "bun:test";
import { EMPTY_HISTORY } from "./steward-policy";
import { offeredComments, parseHistory } from "./steward-records";
import type { ActionableComment } from "./steward-reviews";

const comment: ActionableComment = {
  id: 11,
  threadId: 10,
  kind: "inline",
  author: "alice",
  path: "src/a.ts",
  line: 3,
  body: "Please fix.",
  intent: "change",
};

test("parseHistory reads a full history", () => {
  const h = {
    rounds: 2,
    fixedSignatures: [["unit: error"], []],
    rerunChecks: ["e2e"],
    commentAttempts: { "11": 1 },
  };
  expect(parseHistory(JSON.stringify(h))).toEqual(h);
});

test("parseHistory fills missing fields and starts empty on anything unreadable", () => {
  expect(parseHistory(JSON.stringify({ rounds: 1 }))).toEqual({ ...EMPTY_HISTORY, rounds: 1 });
  for (const text of ["", "  \n", "{", "null", "[]", '{"rounds":-1}', '{"rounds":"3"}']) {
    expect(parseHistory(text)).toEqual(EMPTY_HISTORY);
  }
  expect(parseHistory('{"commentAttempts":{"11":-2}}')).toEqual(EMPTY_HISTORY);
  expect(parseHistory('{"rerunChecks":[7]}')).toEqual(EMPTY_HISTORY);
  // A history written before re-runs were keyed by check name: the old field is ignored.
  expect(parseHistory('{"rounds":1,"rerunJobs":[7]}')).toEqual({ ...EMPTY_HISTORY, rounds: 1 });
});

test("offeredComments reads the fix comments of an inspect report", () => {
  const report = { pr: 5, decision: { action: "fix", fixComments: [comment] } };
  expect(offeredComments(JSON.stringify(report))).toEqual([comment]);
  const none = { decision: { fixComments: [] } };
  expect(offeredComments(JSON.stringify(none))).toEqual([]);
});

test("offeredComments rejects what is not a steward report", () => {
  for (const text of [
    "",
    "nope",
    "{}",
    JSON.stringify({ decision: { fixComments: [{ ...comment, kind: "email" }] } }),
    JSON.stringify({ decision: { fixComments: [{ ...comment, id: 0 }] } }),
  ]) {
    const r = offeredComments(text);
    expect(typeof r).toBe("string");
    expect(r as string).toStartWith("not a steward report:");
  }
});
