import { expect, test } from "bun:test";
import type { CheckRun, PrComment } from "../../contexts/delivery";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { FakeSteward, type FakeStewardScript, HEAD_SHA } from "../../testing/fake-steward";
import { stewardCommand } from "./steward";

const SHA = "9".repeat(40);
const failing = (name: string, jobId: number): CheckRun => ({
  name,
  status: "completed",
  conclusion: "failure",
  jobId,
});
const ask: PrComment = {
  id: 11,
  kind: "inline",
  author: "alice",
  association: "OWNER",
  body: "Please rename.",
  path: "src/a.ts",
  line: 2,
  inReplyTo: null,
  outdated: false,
  reviewState: null,
  createdAt: "2026-11-01T00:00:00Z",
};
const offeredReport = JSON.stringify({
  decision: {
    fixComments: [
      {
        id: 11,
        threadId: 11,
        kind: "inline",
        author: "alice",
        path: "a.ts",
        line: 2,
        body: "x",
        intent: "change",
      },
    ],
  },
});

async function run(
  args: string[],
  fake = new FakeSteward(),
  files: Record<string, string> = {},
  env: Record<string, string> = {},
) {
  const io = captureIO();
  const ctx = commandContext(io, undefined, env, new FakeFileReader(files), {
    steward: fake.ports(),
  });
  const code = await stewardCommand.run(args, ctx);
  return { code, out: io.outLines.join("\n"), err: io.errLines.join("\n"), fake };
}
const steward = (s: FakeStewardScript) => new FakeSteward(s);

test("help and usage errors", async () => {
  expect((await run(["--help"])).code).toBe(0);
  expect((await run(["inspect", "--help"])).code).toBe(0);
  for (const args of [
    [],
    ["nope"],
    ["inspect"],
    ["inspect", "--pr", "0"],
    ["inspect", "--pr", "5", "--format", "yaml"],
    ["inspect", "--pr", "5", "--max-rounds", "99"],
    ["inspect", "--pr", "5", "--bots", "al ice"],
    ["reply", "--pr", "5", "--sha", SHA, "--report", "/r.json", "--changed", "maybe"],
    ["push", "--pr", "5", "--branch", "feat/x", "--sha", SHA],
    ["inspect", "--pr", "5", "--jobs", "1"],
    ["inspect", "--pr"],
    ["rerun", "--pr", "5"],
    ["rerun", "--pr", "5", "--jobs", "1,x"],
    ["reply", "--pr", "5", "--sha", "abc", "--report", "/r.json"],
    ["reply", "--pr", "5", "--sha", SHA],
    ["push", "--pr", "5", "--sha", SHA],
    ["scan", "--base"],
  ]) {
    expect({ args, code: (await run(args)).code }).toEqual({ args, code: 2 });
  }
});

test("inspect prints the decision and json carries the brief", async () => {
  const fake = () =>
    steward({ checkRuns: { [HEAD_SHA]: [failing("unit", 3)] }, logs: { 3: "error: x" } });
  const text = await run(["inspect", "--pr", "5"], fake());
  expect(text.code).toBe(0);
  expect(text.out).toContain("PR #5 (open) at aaaaaaaaaaaa");
  expect(text.out).toContain("✗ unit [code]");
  expect(text.out).toContain("next: fix");
  const json = await run(["inspect", "--pr", "5", "--format", "json"], fake());
  const report = JSON.parse(json.out);
  expect(report.decision.action).toBe("fix");
  expect(report.brief.items[0].text).toBe("error: x");
});

test("inspect reads the history file and honours --max-rounds", async () => {
  const fake = () => steward({ comments: [ask] });
  const files = { "/h.json": JSON.stringify({ rounds: 1 }) };
  const limited = await run(
    ["inspect", "--pr", "5", "--history", "/h.json", "--max-rounds", "1"],
    fake(),
    files,
  );
  expect(limited.out).toContain("next: stop");
  const missing = await run(["inspect", "--pr", "5", "--history", "/none.json"], fake(), files);
  expect(missing.out).toContain("next: fix");
  expect(missing.out).toContain("• 11 alice src/a.ts (change)");
});

test("inspect: bots come from --bots, else the environment, else the defaults", async () => {
  const bot = { ...ask, author: "my-reviewer[bot]", association: "NONE" };
  const green: CheckRun = { name: "unit", status: "completed", conclusion: "success", jobId: 1 };
  const fake = () => steward({ comments: [bot], checkRuns: { [HEAD_SHA]: [green] } });
  expect((await run(["inspect", "--pr", "5"], fake())).out).toContain("next: done");
  const empty = await run(["inspect", "--pr", "5", "--bots", ""], fake());
  expect(empty.out).toContain("next: done");
  const flag = await run(["inspect", "--pr", "5", "--bots", "My-Reviewer[bot]"], fake());
  expect(flag.out).toContain("next: fix");
  const env = await run(
    ["inspect", "--pr", "5"],
    fake(),
    {},
    { SHIPWRIGHT_STEWARD_BOTS: "my-reviewer[bot]" },
  );
  expect(env.out).toContain("next: fix");
  const badEnv = await run(
    ["inspect", "--pr", "5"],
    fake(),
    {},
    { SHIPWRIGHT_STEWARD_BOTS: "no bot" },
  );
  expect(badEnv.code).toBe(2);
});

test("inspect: a GitHub failure exits 1", async () => {
  const r = await run(
    ["inspect", "--pr", "5"],
    steward({ failing: { pull: { kind: "auth", message: "401" } } }),
  );
  expect(r.code).toBe(1);
  expect(r.err).toContain("401");
});

test("reply posts from the report and the fixer's replies", async () => {
  const files = {
    "/r.json": offeredReport,
    "/replies.json": JSON.stringify({ replies: [{ id: 11, status: "fixed", note: "done" }] }),
  };
  const args = [
    "reply",
    "--pr",
    "5",
    "--sha",
    SHA,
    "--report",
    "/r.json",
    "--replies",
    "/replies.json",
    "--changed",
    "yes",
  ];
  const r = await run(args, new FakeSteward(), files);
  expect(r.code).toBe(0);
  expect(r.out).toBe("replied to 1; unhandled: none");
  expect(r.fake.writes.map((w) => w.method)).toEqual(["replyToReviewComment"]);
  const json = await run([...args, "--format", "json"], new FakeSteward(), files);
  expect(JSON.parse(json.out)).toEqual({ replied: [11], unhandled: [] });
});

test("reply without a replies file leaves every comment unhandled", async () => {
  const args = [
    "reply",
    "--pr",
    "5",
    "--sha",
    SHA,
    "--report",
    "/r.json",
    "--replies",
    "/none",
    "--changed",
    "no",
  ];
  const r = await run(args, new FakeSteward(), { "/r.json": offeredReport });
  expect(r.out).toBe("replied to 0; unhandled: 11");
  expect(r.fake.writes).toEqual([]);
});

test("reply rejects a report that is not an inspect report", async () => {
  const r = await run(
    ["reply", "--pr", "5", "--sha", SHA, "--report", "/r.json"],
    new FakeSteward(),
    {
      "/r.json": '{"x":1}',
    },
  );
  expect(r.code).toBe(2);
  expect(r.err).toContain("not a steward report");
});

test("rerun re-runs the listed jobs", async () => {
  const r = await run(["rerun", "--pr", "5", "--jobs", "4, 5"]);
  expect(r.code).toBe(0);
  expect(r.out).toBe("re-ran 2 job(s)");
  expect(r.fake.writes.map((w) => w.args[0])).toEqual([4, 5]);
});

test("push checks the PR, scans the round and fast-forwards", async () => {
  const args = ["push", "--pr", "5", "--branch", "feat/x", "--sha", SHA, "--from", HEAD_SHA];
  const r = await run([...args, "--repo-dir", "/w"]);
  expect(r.code).toBe(0);
  expect(r.out).toBe(`pushed ${SHA.slice(0, 12)} to feat/x`);
  expect(r.fake.writes[0]?.args).toEqual(["/w", "feat/x", SHA]);
  expect(r.fake.diffs).toEqual([{ base: HEAD_SHA, head: SHA }]);
  const again = new FakeSteward();
  await run(args, again);
  const second = await run(args, again);
  expect(second.out).toBe(`feat/x is already at ${SHA.slice(0, 12)}`);
  for (const [bad, fake] of [
    [
      ["push", "--pr", "5", "--branch", "x..y", "--sha", SHA, "--from", HEAD_SHA],
      new FakeSteward(),
    ],
    [
      ["push", "--pr", "5", "--branch", "main", "--sha", SHA, "--from", HEAD_SHA],
      new FakeSteward(),
    ],
    [args, steward({ pull: { crossRepository: true } })],
    [args, steward({ patch: "+++ b/a.test.ts\n@@ -0,0 +1,1 @@\n+it.only(x)" })],
  ] as const) {
    const out = await run([...bad], fake);
    expect(out.code).toBe(1);
    expect(out.fake.writes).toEqual([]);
  }
});

test("reply --changed no posts a 'fixed' report as no change", async () => {
  const files = {
    "/r.json": offeredReport,
    "/replies.json": JSON.stringify({ replies: [{ id: 11, status: "fixed", note: "done" }] }),
  };
  const args = ["reply", "--pr", "5", "--sha", SHA, "--report", "/r.json"];
  const r = await run(
    [...args, "--replies", "/replies.json", "--changed", "no"],
    new FakeSteward(),
    files,
  );
  expect(r.code).toBe(0);
  expect(String(r.fake.writes[0]?.args.at(-1))).toContain("No change made at");
  const yes = await run(
    [...args, "--replies", "/replies.json", "--changed", "yes"],
    new FakeSteward(),
    files,
  );
  expect(String(yes.fake.writes[0]?.args.at(-1))).toContain("Fixed in");
  const missing = await run([...args, "--replies", "/replies.json"], new FakeSteward(), files);
  expect(missing.code).toBe(2);
  expect(missing.fake.writes).toEqual([]);
});

test("inspect --no-checks-ok takes yes or no", async () => {
  const r = await run(["inspect", "--pr", "5", "--no-checks-ok", "maybe"], new FakeSteward());
  expect(r.code).toBe(2);
});

test("scan exit codes: pass 0, fix 4, block 3", async () => {
  const patch = (line: string) => `+++ b/src/a.ts\n@@ -0,0 +1,1 @@\n+${line}`;
  const pass = await run(["scan"], steward({ patch: "" }));
  expect([pass.code, pass.out]).toEqual([0, "✓ scan: nothing found in the added lines"]);
  expect(pass.fake.diffs).toEqual([{ base: "origin/main", head: undefined }]);
  const note = await run(
    ["scan", "--base", "origin/dev"],
    steward({ patch: patch("console.log(1)") }),
  );
  expect([note.code, note.out.split("\n")[0]]).toEqual([0, "✓ scan: notes only"]);
  expect(note.fake.diffs).toEqual([{ base: "origin/dev", head: undefined }]);
  const fix = await run(["scan"], steward({ patch: patch("debugger;") }));
  expect(fix.code).toBe(4);
  expect(fix.out).toContain("fix src/a.ts:1 debugger");
  const block = await run(
    ["scan", "--format", "json"],
    steward({ patch: patch(`k="${"AKIA"}${"Q".repeat(16)}"`) }),
  );
  expect(block.code).toBe(3);
  expect(JSON.parse(block.out).verdict).toBe("block");
  const broken = await run(
    ["scan"],
    steward({ failing: { diff: { kind: "failed", message: "bad ref" } } }),
  );
  expect(broken.code).toBe(1);
});
