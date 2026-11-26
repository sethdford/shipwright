import { expect, test } from "bun:test";
import { FakeSteward } from "../../../testing/fake-steward";
import type { ActionableComment } from "../domain/steward-reviews";
import { postReplies, rerunJobs } from "./steward";

const SHA = "c".repeat(40);
const offered = (
  id: number,
  kind: ActionableComment["kind"],
  threadId = id,
): ActionableComment => ({
  id,
  threadId,
  kind,
  author: "alice",
  path: kind === "inline" ? "a.ts" : null,
  line: kind === "inline" ? 1 : null,
  body: "Please fix.",
  intent: "change",
});
const report = (...replies: unknown[]) => JSON.stringify({ replies });
const OFFERED = [offered(11, "inline", 10), offered(12, "review"), offered(13, "conversation")];

test("inline replies go to the thread root; the rest share one summary comment", async () => {
  const fake = new FakeSteward();
  const r = await postReplies(fake.ports(), {
    pr: 7,
    sha: SHA,
    offered: OFFERED,
    changed: true,
    repliesText: report(
      { id: 11, status: "fixed", note: "Renamed." },
      { id: 12, status: "answered", note: "Because IO." },
      { id: 13, status: "declined", note: "Out of scope." },
    ),
  });
  expect(r).toEqual({ ok: true, value: { replied: [11, 12, 13], unhandled: [] } });
  expect(fake.writes.map((w) => [w.method, w.args[0], w.args[1]])).toEqual([
    ["replyToReviewComment", 7, 10],
    ["commentOnPull", 7, expect.stringContaining("comment 12: answered. Because IO.")],
  ]);
  expect(String(fake.writes[0]?.args[2])).toContain("reply-to:11 -->");
  expect(String(fake.writes[1]?.args[1])).toContain("reply-to:12,13 -->");
});

test("comments the fixer did not report on are unhandled; unknown ids are ignored", async () => {
  const fake = new FakeSteward();
  const r = await postReplies(fake.ports(), {
    pr: 7,
    sha: SHA,
    offered: OFFERED,
    changed: true,
    repliesText: report({ id: 12, status: "fixed" }, { id: 555, status: "fixed", note: "x" }),
  });
  expect(r).toEqual({ ok: true, value: { replied: [12], unhandled: [11, 13] } });
  expect(fake.writes.map((w) => w.method)).toEqual(["commentOnPull"]);
});

test("no report (or a bad one) posts nothing and leaves every comment unhandled", async () => {
  for (const repliesText of ["", "{oops", '{"replies":[{"id":"11"}]}']) {
    const fake = new FakeSteward();
    const r = await postReplies(fake.ports(), {
      pr: 7,
      sha: SHA,
      offered: OFFERED,
      repliesText,
      changed: true,
    });
    expect(r).toEqual({ ok: true, value: { replied: [], unhandled: [11, 12, 13] } });
    expect(fake.writes).toEqual([]);
  }
});

test("a retried reply round reuses its keys, so the writer can reconcile", async () => {
  const fake = new FakeSteward();
  const req = {
    pr: 7,
    sha: SHA,
    offered: OFFERED,
    changed: true,
    repliesText: report({ id: 11, status: "fixed" }, { id: 13, status: "fixed" }),
  };
  await postReplies(fake.ports(), req);
  await postReplies(fake.ports(), req);
  const keys = fake.writes.map((w) => w.key);
  expect(keys).toHaveLength(4);
  expect(keys[2]).toBe(keys[0]);
  expect(keys[3]).toBe(keys[1]);
  expect(new Set(keys).size).toBe(2);
  const later = await postReplies(fake.ports(), { ...req, sha: "d".repeat(40) });
  expect(later.ok).toBe(true);
  expect(new Set(fake.writes.map((w) => w.key)).size).toBe(4);
});

test("a failed write stops the round with its error", async () => {
  const fake = new FakeSteward({
    failing: { replyToReviewComment: { kind: "transient", message: "502" } },
  });
  const r = await postReplies(fake.ports(), {
    pr: 7,
    sha: SHA,
    offered: OFFERED,
    changed: true,
    repliesText: report({ id: 11, status: "fixed" }, { id: 12, status: "fixed" }),
  });
  expect(r).toEqual({ ok: false, error: { kind: "transient", message: "502" } });
  expect(fake.writes).toEqual([]);
});

test("rerunJobs re-runs each job with its own key and stops on the first failure", async () => {
  const fake = new FakeSteward();
  expect(await rerunJobs(fake.ports(), 7, [1, 2])).toEqual({ ok: true, value: [1, 2] });
  expect(fake.writes.map((w) => w.args[0])).toEqual([1, 2]);
  expect(fake.writes[0]?.key).not.toBe(fake.writes[1]?.key);
  const failing = new FakeSteward({ failing: { rerunJob: { kind: "auth", message: "403" } } });
  expect((await rerunJobs(failing.ports(), 7, [1])).ok).toBe(false);
  expect(await rerunJobs(fake.ports(), 7, [])).toEqual({ ok: true, value: [] });
});

test("a round that committed nothing cannot claim 'fixed'", async () => {
  const fake = new FakeSteward();
  const r = await postReplies(fake.ports(), {
    pr: 7,
    sha: SHA,
    offered: OFFERED,
    changed: false,
    repliesText: report(
      { id: 11, status: "fixed", note: "Renamed." },
      { id: 12, status: "answered", note: "Because IO." },
    ),
  });
  expect(r).toEqual({ ok: true, value: { replied: [11, 12], unhandled: [13] } });
  const [inline, summary] = fake.writes.map((w) => String(w.args.at(-1)));
  expect(inline).toContain("No change made at");
  expect(inline).not.toContain("Fixed in");
  expect(summary).toContain("comment 12: answered.");
});
