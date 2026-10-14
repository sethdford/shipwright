import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GitCli } from "./git-cli";

test("headSha and currentBranch trim git output", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["git", "rev-parse", "--abbrev-ref", "HEAD"],
      result: { exitCode: 0, stdout: "main\n", stderr: "" },
    },
    { prefix: ["git", "rev-parse", "HEAD"], result: { exitCode: 0, stdout: "abc\n", stderr: "" } },
  ]);
  const git = new GitCli(runner);
  expect(await git.headSha("/repo")).toEqual({ ok: true, value: "abc" });
  expect(await git.currentBranch("/repo")).toEqual({ ok: true, value: "main" });
  expect(runner.calls[0]?.cwd).toBe("/repo");
});

test("outside a repository is not_found", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["git"],
      result: {
        exitCode: 128,
        stdout: "",
        stderr: "fatal: not a git repository (or any of the parent directories): .git\n",
      },
    },
  ]);
  const r = await new GitCli(runner).headSha("/tmp");
  expect(!r.ok && r.error.kind).toBe("not_found");
});
