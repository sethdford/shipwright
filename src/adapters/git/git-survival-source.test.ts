import { expect, test } from "bun:test";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import { GitSurvivalSource } from "./git-survival-source";

const MERGE = "abc1234def";
const SNAP = "fedcba98765";
const DIFF = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -0,0 +1 @@\n+const kept = 1;\n";
const okRun = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const fail: ScriptedCall["result"] = { exitCode: 1, stdout: "", stderr: "no" };

function script(over: Partial<Record<string, ScriptedCall["result"]>> = {}): ScriptedCall[] {
  return [
    { prefix: ["git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD"], result: over.base ?? okRun() },
    { prefix: ["git", "rev-parse"], result: fail },
    { prefix: ["git", "cat-file"], result: over.cat ?? okRun() },
    { prefix: ["git", "rev-list"], result: over.snap ?? okRun(`${SNAP}\n`) },
    { prefix: ["git", "merge-base"], result: over.ancestor ?? okRun() },
    { prefix: ["git", "diff"], result: okRun(DIFF) },
    { prefix: ["git", "show"], result: over.show ?? okRun("const kept = 1;\n") },
  ];
}

test("reads the merge's added lines and each file at the horizon commit", async () => {
  const fake = new FakeProcessRunner(script());
  const r = await new GitSurvivalSource(fake, "/repo").read(MERGE, Date.UTC(2026, 9, 1), 86_400_000);
  if (!r.ok || r.value === null) throw new Error("expected input");
  expect(r.value.added.get("a.ts")).toEqual(["const kept = 1;"]);
  expect(r.value.later.get("a.ts")).toBe("const kept = 1;\n");
  const revList = fake.calls.find((c) => c.argv[1] === "rev-list")?.argv;
  expect(revList).toEqual([
    "git", "rev-list", "-1", "--first-parent",
    `--before=@${Math.floor((Date.UTC(2026, 9, 1) + 86_400_000) / 1000)}`,
    "refs/remotes/origin/HEAD",
  ]);
  expect(fake.calls.at(-1)?.argv).toEqual(["git", "show", `${SNAP}:a.ts`]);
  expect(fake.calls.every((c) => c.cwd === "/repo")).toBe(true);
});

test("a file gone at the horizon reads as null", async () => {
  const r = await new GitSurvivalSource(new FakeProcessRunner(script({ show: fail })), "/r").read(MERGE, 0, 1000);
  expect(r.ok && r.value?.later.get("a.ts")).toBeNull();
});

test("missing history is null, not an error: unknown merge, no horizon commit, not an ancestor", async () => {
  for (const over of [{ cat: fail }, { snap: okRun("") }, { ancestor: fail }]) {
    const r = await new GitSurvivalSource(new FakeProcessRunner(script(over)), "/r").read(MERGE, 0, 1000);
    expect(r).toEqual({ ok: true, value: null });
  }
});

test("refuses a merge sha that is not a commit id, before running git", async () => {
  const fake = new FakeProcessRunner(script());
  expect((await new GitSurvivalSource(fake, "/r").read("--output=x", 0, 1)).ok).toBe(false);
  expect(fake.calls).toHaveLength(0);
});
