import { expect, test } from "bun:test";
import { FakeSteward, type FakeStewardScript, HEAD_SHA } from "../../../testing/fake-steward";
import { pushFix } from "./steward-push";

const SHA = "c".repeat(40);
const KEY = `AKIA${"ABCDEFGHIJKLMNOP"}`;
const patch = (...lines: string[]) =>
  ["+++ b/src/a.test.ts", `@@ -0,0 +1,${lines.length} @@`, ...lines.map((l) => `+${l}`)].join("\n");
const req = (over: Partial<Parameters<typeof pushFix>[1]> = {}) => ({
  pr: 7,
  repoDir: "/w",
  branch: "feat/x",
  sha: SHA,
  from: HEAD_SHA,
  ...over,
});

async function push(script: FakeStewardScript, over: Partial<Parameters<typeof pushFix>[1]> = {}) {
  const fake = new FakeSteward(script);
  const r = await pushFix(fake.ports(), req(over));
  return { r, fake, message: r.ok ? "" : r.error.message };
}

test("a clean round on the PR's own branch is pushed, scanned from --from to --sha", async () => {
  const { r, fake } = await push({ patch: patch("const x = 1;", "console.log(x);") });
  expect(r).toEqual({ ok: true, value: "done" });
  expect(fake.diffs).toEqual([{ base: HEAD_SHA, head: SHA }]);
  expect(fake.writes.map((w) => [w.method, ...w.args])).toEqual([
    ["pushCommit", "/w", "feat/x", SHA],
  ]);
});

test("unusable branches and shas are refused before anything is read", async () => {
  for (const over of [
    { branch: "--force" },
    { branch: "-f" },
    { branch: "+main" },
    { branch: "a..b" },
    { branch: "feat x" },
    { branch: "" },
    { sha: "abc123" },
    { sha: "C".repeat(40) },
    { sha: `${SHA}:refs/heads/main` },
    { from: "HEAD" },
    { from: "" },
  ]) {
    const { r, fake } = await push({}, over);
    expect(r.ok).toBe(false);
    expect(fake.writes).toEqual([]);
    expect(fake.diffs).toEqual([]);
  }
});

test("only the PR's own head branch, open and not from a fork", async () => {
  const cases: [FakeStewardScript, Partial<Parameters<typeof pushFix>[1]>, string][] = [
    [{}, { branch: "main" }, "is on feat/x, not main"],
    [{ pull: { state: "closed" } }, {}, "is closed"],
    [{ pull: { state: "merged" } }, {}, "is merged"],
    [{ pull: { crossRepository: true } }, {}, "fork"],
  ];
  for (const [script, over, why] of cases) {
    const { r, fake, message } = await push(script, over);
    expect(r.ok).toBe(false);
    expect(message).toContain(why);
    expect(fake.writes).toEqual([]);
  }
});

test("a PR that moved during the round is not pushed over", async () => {
  const { r, fake, message } = await push({ pull: { headSha: "d".repeat(40) } });
  expect(r.ok).toBe(false);
  expect(message).toContain("moved to dddddddddddd");
  expect(fake.writes).toEqual([]);
});

test("a PR already at --sha (a retried push) still goes through the writer, which reconciles", async () => {
  const { r, fake } = await push({ pull: { headSha: SHA } });
  expect(r.ok).toBe(true);
  expect(fake.diffs).toHaveLength(1);
  expect(fake.writes).toHaveLength(1);
});

test("a secret, focused test or conflict marker in the round's change refuses the push", async () => {
  for (const line of [`const k = "${KEY}";`, 'test.only("x", f);', "<<<<<<< HEAD"]) {
    const { r, fake, message } = await push({ patch: patch(line) });
    expect(r.ok).toBe(false);
    expect(message).toContain("scan findings");
    expect(message).toContain("src/a.test.ts:1");
    expect(fake.writes).toEqual([]);
  }
});

test("a failing read or diff refuses the push", async () => {
  for (const method of ["pull", "diff"]) {
    const { r, fake } = await push({ failing: { [method]: { kind: "transient", message: "x" } } });
    expect(r).toEqual({ ok: false, error: { kind: "transient", message: "x" } });
    expect(fake.writes).toEqual([]);
  }
});
