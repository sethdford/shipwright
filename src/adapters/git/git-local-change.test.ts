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
      prefix: ["git", "diff", "--no-renames", "--no-color"],
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
  // The patch is plain text whatever the user's git config or attributes say.
  expect(fake.calls[1]?.argv).toEqual([
    "git",
    "diff",
    "--no-renames",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--text",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    "origin/main...HEAD",
  ]);
});

test("diffs base...head when a head is given", async () => {
  const fake = new FakeProcessRunner([
    { prefix: ["git", "diff"], result: { exitCode: 0, stdout: "", stderr: "" } },
  ]);
  const head = "c".repeat(40);
  const r = await new GitLocalChange(fake, "/repo").diff("b".repeat(40), head);
  expect(r.ok).toBe(true);
  expect(fake.calls.map((c) => c.argv.at(-1))).toEqual([
    `${"b".repeat(40)}...${head}`,
    `${"b".repeat(40)}...${head}`,
  ]);
});

test("refuses refs that could be options or ranges, and reports git errors", async () => {
  const fake = new FakeProcessRunner([
    { prefix: ["git"], result: { exitCode: 128, stdout: "", stderr: "fatal: bad revision" } },
  ]);
  const g = new GitLocalChange(fake, "/repo");
  for (const ref of ["--output=/tmp/x", "a..b", "a b", ""]) {
    expect((await g.diff(ref)).ok).toBe(false);
    expect((await g.diff("main", ref)).ok).toBe(false);
  }
  expect(fake.calls).toHaveLength(0);
  const r = await g.diff("main");
  expect(!r.ok && r.error.message).toBe("fatal: bad revision");
});
