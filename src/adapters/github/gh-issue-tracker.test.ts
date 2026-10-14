import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhIssueTracker } from "./gh-issue-tracker";

const gh = (exitCode: number, stdout: string, stderr = "", timedOut = false) =>
  new FakeProcessRunner([{ prefix: ["gh"], result: { exitCode, stdout, stderr, timedOut } }]);

test("parses gh JSON into an Issue; a title with backticks stays data", async () => {
  const runner = gh(
    0,
    JSON.stringify({
      number: 7690,
      title: "Decompose `sw-memory.sh`",
      body: null,
      state: "OPEN",
      author: { login: "patrol-bot", is_bot: true },
      labels: [{ name: "ready-to-build" }],
    }),
  );
  expect(await new GhIssueTracker(runner).getIssue(7690)).toEqual({
    ok: true,
    value: {
      number: 7690,
      title: "Decompose `sw-memory.sh`",
      body: "",
      state: "open",
      author: "patrol-bot",
      labels: ["ready-to-build"],
    },
  });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "view",
    "7690",
    "--json",
    "number,title,body,state,author,labels",
  ]);
});

test.each([
  ["GraphQL: Could not resolve to an issue or pull request with the number of 1.", "not_found"],
  ["HTTP 401: Bad credentials", "auth"],
  ["To get started with GitHub CLI, please run:  gh auth login", "auth"],
  ["HTTP 403: API rate limit exceeded for user", "transient"],
  ["HTTP 502: Bad Gateway", "transient"],
  ["dial tcp: lookup api.github.com: no such host", "transient"],
  ["could not resolve host: api.github.com", "transient"],
  ["HTTP 429: Too Many Requests", "transient"],
  ["HTTP 403: You have exceeded a secondary rate limit", "transient"],
  ["HTTP 403: Resource not accessible by integration", "auth"],
  ["GraphQL: Could not resolve to a Repository with the name 'o/r'.", "failed"],
  ["HTTP 404: Not Found (https://api.github.com/repos/o/r)", "failed"],
  ["something unexpected", "failed"],
  ["gh: command not found", "failed"],
])("classifies gh error %p as %p", async (stderr, kind) => {
  const r = await new GhIssueTracker(gh(1, "", stderr)).getIssue(1);
  expect(r).toEqual({ ok: false, error: { kind: kind as never, message: stderr } });
});

test("a timeout is transient", async () => {
  const r = await new GhIssueTracker(gh(143, "", "", true)).getIssue(1);
  expect(!r.ok && r.error.kind).toBe("transient");
});

test("unexpected JSON is a failed error, not a crash", async () => {
  const r = await new GhIssueTracker(gh(0, JSON.stringify({ number: "x" }))).getIssue(1);
  expect(!r.ok && r.error.kind).toBe("failed");
});

test("non-JSON stdout is a failed error, not a thrown SyntaxError", async () => {
  const r = await new GhIssueTracker(gh(0, "not json")).getIssue(1);
  expect(!r.ok && r.error.kind).toBe("failed");
  expect(!r.ok && r.error.message).toMatch(/unexpected gh output/);
});

test("a spawn failure is a failed error, not a rejection", async () => {
  const r = await new GhIssueTracker(new FakeProcessRunner([])).getIssue(1);
  expect(!r.ok && r.error.kind).toBe("failed");
});

test("an invalid issue number fails without calling gh", async () => {
  const runner = gh(0, "");
  const r = await new GhIssueTracker(runner).getIssue(-1);
  expect(!r.ok && r.error.kind).toBe("failed");
  expect(runner.calls).toHaveLength(0);
});
