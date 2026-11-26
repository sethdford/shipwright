import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhHoldoutSource } from "./gh-holdout-source";

const A = "a".repeat(40);
const B = "b".repeat(40);
const out = (value: unknown) => ({ exitCode: 0, stdout: JSON.stringify(value), stderr: "" });
const pulls = [
  {
    number: 9,
    title: "fix",
    body: "Fixes #3",
    user: { login: "sethdford" },
    merged_at: "2026-11-01T00:00:00Z",
    merge_commit_sha: B,
  },
  {
    number: 8,
    title: "closed",
    body: null,
    user: null,
    merged_at: null,
    merge_commit_sha: null,
  },
];

test("merged PRs come with files and the merge commit's parent as base", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: [
        "gh",
        "api",
        "repos/o/r/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1",
      ],
      result: out(pulls),
    },
    {
      prefix: [
        "gh",
        "api",
        "repos/o/r/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=2",
      ],
      result: out([]),
    },
    { prefix: ["gh", "api", `repos/o/r/commits/${B}`], result: out({ parents: [{ sha: A }] }) },
    {
      prefix: ["gh", "api", "repos/o/r/pulls/9/files?per_page=100"],
      result: out([{ filename: "src/x.ts" }]),
    },
  ]);
  const r = await new GhHoldoutSource(runner, "o/r").mergedSince(0, 10);
  expect(r.ok && r.value).toEqual([
    {
      number: 9,
      title: "fix",
      body: "Fixes #3",
      author: "sethdford",
      mergedAtMs: Date.parse("2026-11-01T00:00:00Z"),
      baseSha: A,
      mergeSha: B,
      files: ["src/x.ts"],
    },
  ]);
});

test("issue and diff are read-only gh api calls", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["gh", "api", "repos/o/r/issues/3"],
      result: out({ title: "t", body: null, created_at: "2026-10-01" }),
    },
    {
      prefix: ["gh", "api", "-H", "Accept: application/vnd.github.diff"],
      result: { exitCode: 0, stdout: "diff --git", stderr: "" },
    },
  ]);
  const src = new GhHoldoutSource(runner, "o/r");
  expect(await src.issue(3)).toEqual({
    ok: true,
    value: { title: "t", body: "", createdAt: "2026-10-01" },
  });
  expect(await src.diff(A, B)).toEqual({ ok: true, value: "diff --git" });
  expect((await src.diff("x", B)).ok).toBe(false);
  expect(() => new GhHoldoutSource(runner, "o/r; rm")).toThrow();
});
