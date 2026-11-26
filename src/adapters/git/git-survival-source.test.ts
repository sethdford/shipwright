import { expect, test } from "bun:test";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import { GitSurvivalSource } from "./git-survival-source";

const MERGE = "abc1234def";
const SNAP = "fedcba98765";
const AT = Date.UTC(2026, 9, 1);
const H = 86_400_000;
const STAMP = `@${Math.floor((AT + H) / 1000)}`;
const G = ["git", "-c", "core.quotePath=false"];
const DIFF = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -0,0 +1 @@\n+const kept = 1;\n";
const okRun = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const fail: ScriptedCall["result"] = { exitCode: 1, stdout: "", stderr: "no" };
type Over = Partial<Record<"cat" | "snap" | "past" | "ancestor" | "show", ScriptedCall["result"]>>;

function script(over: Over = {}): ScriptedCall[] {
  const revList = [...G, "rev-list", "-1", "--first-parent"];
  return [
    {
      prefix: [...G, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD"],
      result: okRun(),
    },
    { prefix: [...G, "cat-file"], result: over.cat ?? okRun() },
    { prefix: [...revList, `--before=${STAMP}`], result: over.snap ?? okRun(`${SNAP}\n`) },
    { prefix: [...revList, `--since=${STAMP}`], result: over.past ?? okRun("1234567\n") },
    { prefix: [...G, "merge-base"], result: over.ancestor ?? okRun() },
    { prefix: [...G, "diff"], result: okRun(DIFF) },
    { prefix: [...G, "show"], result: over.show ?? okRun("const kept = 1;\n") },
  ];
}
const read = (over: Over = {}) =>
  new GitSurvivalSource(new FakeProcessRunner(script(over)), "/r").read(MERGE, AT, H);

test("reads the merge's added lines and each file at the horizon commit", async () => {
  const fake = new FakeProcessRunner(script());
  const r = await new GitSurvivalSource(fake, "/repo").read(MERGE, AT, H);
  if (!r.ok || r.value === null) throw new Error("expected input");
  expect(r.value.added.get("a.ts")).toEqual(["const kept = 1;"]);
  expect(r.value.later.get("a.ts")).toBe("const kept = 1;\n");
  expect(fake.calls.at(-1)?.argv).toEqual([...G, "show", `${SNAP}:a.ts`]);
  expect(fake.calls.every((c) => c.cwd === "/repo")).toBe(true);
});

test("a file gone at the horizon reads as null", async () => {
  const r = await read({ show: fail });
  expect(r.ok && r.value?.later.get("a.ts")).toBeNull();
});

test("missing history is null, not an error: unknown merge, no horizon commit, not an ancestor, clone not fetched past the horizon", async () => {
  for (const over of [{ cat: fail }, { snap: okRun("") }, { ancestor: fail }, { past: okRun("") }])
    expect(await read(over)).toEqual({ ok: true, value: null });
});

test("refuses a merge sha that is not a commit id, before running git", async () => {
  const fake = new FakeProcessRunner(script());
  expect((await new GitSurvivalSource(fake, "/r").read("--output=x", 0, 1)).ok).toBe(false);
  expect(fake.calls).toHaveLength(0);
});
