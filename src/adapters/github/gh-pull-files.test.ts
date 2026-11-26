import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhPullFiles, parseFileRows } from "./gh-pull-files";

const row = (filename: string, additions: number, deletions: number) =>
  JSON.stringify({ filename, additions, deletions });

test("reads every page of a PR's files through REST, argv only", async () => {
  const stdout = `${row("a.ts", 3, 1)}\n${row(".claude/x.log", 900, 0)}\n`;
  const fake = new FakeProcessRunner([
    { prefix: ["gh", "api"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  const r = await new GhPullFiles(fake).files(42);
  expect(r).toEqual({
    ok: true,
    value: [
      { path: "a.ts", additions: 3, deletions: 1 },
      { path: ".claude/x.log", additions: 900, deletions: 0 },
    ],
  });
  expect(fake.calls[0]?.argv).toEqual([
    "gh",
    "api",
    "--paginate",
    "repos/{owner}/{repo}/pulls/42/files?per_page=100",
    "--jq",
    ".[] | {filename, additions, deletions}",
  ]);
});

test("gh failures are classified; bad output and bad numbers fail", async () => {
  const fake = new FakeProcessRunner([
    {
      prefix: ["gh", "api"],
      result: { exitCode: 1, stdout: "", stderr: "HTTP 403: rate limit exceeded" },
    },
  ]);
  const r = await new GhPullFiles(fake).files(1);
  expect(!r.ok && r.error.kind).toBe("transient");
  expect((await new GhPullFiles(fake).files(0)).ok).toBe(false);
  expect(parseFileRows("not json").ok).toBe(false);
  expect(parseFileRows(JSON.stringify({ filename: 1 })).ok).toBe(false);
  expect(parseFileRows("\n")).toEqual({ ok: true, value: [] });
});
