import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhPullRequests } from "./gh-pull-requests";

test("lists open PRs as summaries", async () => {
  const stdout = JSON.stringify([
    {
      number: 6765,
      author: { is_bot: true, login: "app/github-actions" },
      labels: [{ name: "shipwright" }],
      isDraft: false,
      reviewDecision: "",
    },
    {
      number: 9,
      author: { login: "sethdford" },
      labels: [],
      isDraft: true,
      reviewDecision: "APPROVED",
    },
  ]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh", "pr", "list"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  expect(await new GhPullRequests(runner).open()).toEqual({
    ok: true,
    value: [
      {
        number: 6765,
        author: "app/github-actions",
        labels: ["shipwright"],
        draft: false,
        approved: false,
      },
      { number: 9, author: "sethdford", labels: [], draft: true, approved: true },
    ],
  });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "pr",
    "list",
    "--state",
    "open",
    "--limit",
    "200",
    "--json",
    "number,author,labels,isDraft,reviewDecision",
  ]);
});

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 401: Bad credentials" } },
  ]);
  const r = await new GhPullRequests(runner).open();
  expect(!r.ok && r.error.kind).toBe("auth");
});
