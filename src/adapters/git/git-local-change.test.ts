import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GitLocalChange, parseNumstat } from "./git-local-change";

test("numstat: counts, binary files as zero, junk lines skipped", () => {
  expect(parseNumstat("3\t1\tsrc/a.ts\n-\t-\timg.png\nwarning: x\n")).toEqual([
    { path: "src/a.ts", additions: 3, deletions: 1 },
    { path: "img.png", additions: 0, deletions: 0 },
  ]);
});

test("diffs base...HEAD in the given checkout", async () => {
  const fake = new FakeProcessRunner([
    {
      prefix: ["git", "diff", "--no-renames", "--numstat"],
      result: { exitCode: 0, stdout: "1\t0\ta\n", stderr: "" },
    },
    {
      prefix: ["git", "diff", "--no-renames", "origin/main...HEAD"],
      result: { exitCode: 0, stdout: "+x", stderr: "" },
    },
  ]);
  const r = await new GitLocalChange(fake, "/repo").diff("origin/main");
  expect(r).toEqual({
    ok: true,
    value: { files: [{ path: "a", additions: 1, deletions: 0 }], patch: "+x" },
  });
  expect(fake.calls.map((c) => c.cwd)).toEqual(["/repo", "/repo"]);
  expect(fake.calls[0]?.argv.at(-1)).toBe("origin/main...HEAD");
});

test("refuses refs that could be options or ranges, and reports git errors", async () => {
  const fake = new FakeProcessRunner([
    { prefix: ["git"], result: { exitCode: 128, stdout: "", stderr: "fatal: bad revision" } },
  ]);
  const g = new GitLocalChange(fake, "/repo");
  for (const ref of ["--output=/tmp/x", "a..b", "a b", ""])
    expect((await g.diff(ref)).ok).toBe(false);
  expect(fake.calls).toHaveLength(0);
  const r = await g.diff("main");
  expect(!r.ok && r.error.message).toBe("fatal: bad revision");
});
