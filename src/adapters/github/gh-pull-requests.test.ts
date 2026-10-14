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
    "201",
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

test("a null reviewDecision means not approved", async () => {
  const stdout = JSON.stringify([
    { number: 1, author: { login: "a" }, labels: [], isDraft: false, reviewDecision: null },
  ]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  const r = await new GhPullRequests(runner).open();
  expect(r.ok && r.value[0]?.approved).toBe(false);
});

test("more than 200 open PRs is an error, not a truncated count", async () => {
  const rows = Array.from({ length: 201 }, (_, i) => ({
    number: i + 1,
    author: { login: "a" },
    labels: [],
    isDraft: false,
    reviewDecision: "",
  }));
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 0, stdout: JSON.stringify(rows), stderr: "" } },
  ]);
  const r = await new GhPullRequests(runner).open();
  expect(!r.ok && r.error).toEqual({
    kind: "failed",
    message: "more than 200 open PRs; review WIP unknown",
  });
});

test("a malformed author is an error", async () => {
  const stdout = JSON.stringify([
    { number: 1, author: null, labels: [], isDraft: false, reviewDecision: "" },
  ]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  expect((await new GhPullRequests(runner).open()).ok).toBe(false);
});
