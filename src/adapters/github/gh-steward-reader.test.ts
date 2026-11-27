import { expect, test } from "bun:test";
import { z } from "zod";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import { GhStewardReader, markedBy, parseLines } from "./gh-steward-reader";

const R = "repos/{owner}/{repo}";
const SHA = "e".repeat(40);
const ok = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const get = (path: string, stdout: string): ScriptedCall => ({
  prefix: ["gh", "api", "-X", "GET", path],
  result: ok(stdout),
});
const lines = (...rows: unknown[]) => `${rows.map((r) => JSON.stringify(r)).join("\n")}\n`;

test("parseLines reads NDJSON, skips blank lines and rejects bad rows", () => {
  const schema = z.object({ a: z.number() });
  expect(parseLines('{"a":1}\n\n  \n{"a":2}\n', schema)).toEqual({
    ok: true,
    value: [{ a: 1 }, { a: 2 }],
  });
  expect(parseLines("", schema)).toEqual({ ok: true, value: [] });
  const bad = parseLines('{"a":1}\n{"a":', schema);
  expect(bad.ok).toBe(false);
  expect(parseLines('{"a":"x"}', schema).ok).toBe(false);
});

test("self reads the login and rejects an empty one", async () => {
  const runner = new FakeProcessRunner([get("user", "octo-bot\n")]);
  expect(await new GhStewardReader(runner).self()).toEqual({ ok: true, value: "octo-bot" });
  expect(runner.calls[0]?.argv).toEqual(["gh", "api", "-X", "GET", "user", "--jq", ".login"]);
  expect(runner.calls[0]?.timeoutMs).toBeGreaterThan(0);
  const empty = new FakeProcessRunner([get("user", "\n")]);
  expect((await new GhStewardReader(empty).self()).ok).toBe(false);
});

test("pull maps open, closed and merged", async () => {
  const pull = (state: string, merged: boolean, fork = false) =>
    new GhStewardReader(
      new FakeProcessRunner([
        get(
          `${R}/pulls/5`,
          lines({ state, merged, head: SHA, base: "f".repeat(40), ref: "feat/x", fork }),
        ),
      ]),
    ).pull(5);
  expect(await pull("open", false)).toEqual({
    ok: true,
    value: {
      number: 5,
      state: "open",
      headSha: SHA,
      baseSha: "f".repeat(40),
      headRef: "feat/x",
      crossRepository: false,
    },
  });
  expect(await pull("open", false, true)).toMatchObject({ value: { crossRepository: true } });
  expect(await pull("closed", false)).toMatchObject({ value: { state: "closed" } });
  expect(await pull("closed", true)).toMatchObject({ value: { state: "merged" } });
  const none = new FakeProcessRunner([get(`${R}/pulls/5`, "")]);
  expect((await new GhStewardReader(none).pull(5)).ok).toBe(false);
});

test("pull asks jq whether the head repository differs from the base (a deleted fork counts)", async () => {
  const runner = new FakeProcessRunner([get(`${R}/pulls/5`, "")]);
  await new GhStewardReader(runner).pull(5);
  const jq = runner.calls[0]?.argv.at(-1) ?? "";
  expect(jq).toContain('fork: ((.head.repo.full_name // "") != .base.repo.full_name)');
  const noFork = new FakeProcessRunner([
    get(`${R}/pulls/5`, lines({ state: "open", merged: false, head: SHA, base: SHA, ref: "x" })),
  ]);
  expect((await new GhStewardReader(noFork).pull(5)).ok).toBe(false);
});

test("gh failures are classified", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["gh", "api"],
      result: { exitCode: 1, stdout: "", stderr: "HTTP 403: Bad credentials" },
    },
  ]);
  const r = await new GhStewardReader(runner).pull(5);
  expect(r).toEqual({ ok: false, error: { kind: "auth", message: "HTTP 403: Bad credentials" } });
  const timeout = new FakeProcessRunner([
    { prefix: ["gh", "api"], result: { exitCode: 0, stdout: "x", stderr: "", timedOut: true } },
  ]);
  expect(await new GhStewardReader(timeout).self()).toMatchObject({ error: { kind: "transient" } });
});

test("checkRuns merges check runs and commit statuses; only Actions jobs carry a job id", async () => {
  const runner = new FakeProcessRunner([
    get(
      `${R}/commits/${SHA}/check-runs?per_page=100&filter=latest`,
      lines(
        { id: 1, name: "unit", status: "completed", conclusion: "failure", app: "github-actions" },
        { id: 2, name: "codecov", status: "queued", conclusion: null, app: "codecov" },
        { id: 3, name: "ext", status: "completed", conclusion: "success", app: null },
      ),
    ),
    get(
      `${R}/commits/${SHA}/status?per_page=100`,
      lines(
        { context: "ci/legacy", state: "error" },
        { context: "ci/ok", state: "success" },
        { context: "ci/wait", state: "pending" },
        { context: "ci/odd", state: "weird" },
      ),
    ),
  ]);
  const r = await new GhStewardReader(runner).checkRuns(SHA);
  expect(r).toEqual({
    ok: true,
    value: [
      { name: "unit", status: "completed", conclusion: "failure", jobId: 1, app: "github-actions" },
      { name: "codecov", status: "queued", conclusion: null, jobId: null, app: "codecov" },
      { name: "ext", status: "completed", conclusion: "success", jobId: null, app: "" },
      { name: "ci/legacy", status: "completed", conclusion: "failure", jobId: null, app: "status" },
      { name: "ci/ok", status: "completed", conclusion: "success", jobId: null, app: "status" },
      { name: "ci/wait", status: "in_progress", conclusion: null, jobId: null, app: "status" },
      { name: "ci/odd", status: "in_progress", conclusion: null, jobId: null, app: "status" },
    ],
  });
  expect(runner.calls[0]?.argv).toContain("--paginate");
  expect(runner.calls[1]?.argv).toContain("--paginate");
});

test("checkRuns refuses a partial sha without calling gh", async () => {
  const runner = new FakeProcessRunner([{ prefix: ["gh"], result: ok() }]);
  const r = await new GhStewardReader(runner).checkRuns("abc123");
  expect(r.ok).toBe(false);
  expect(runner.calls).toEqual([]);
});

test("jobLog returns the log, keeping only the tail of a huge one", async () => {
  const path = `${R}/actions/jobs/9/logs`;
  const small = new FakeProcessRunner([get(path, "log text")]);
  expect(await new GhStewardReader(small).jobLog(9)).toEqual({ ok: true, value: "log text" });
  expect(small.calls[0]?.argv).toEqual(["gh", "api", "-X", "GET", path]);
  const huge = `${"a".repeat(2_000_000)}END`;
  const big = await new GhStewardReader(new FakeProcessRunner([get(path, huge)])).jobLog(9);
  expect(big.ok && big.value.length).toBe(2_000_000);
  expect(big.ok && big.value.endsWith("END")).toBe(true);
});

test("comments reads all three kinds, marks outdated inline comments, sorts oldest first", async () => {
  const base = { login: "alice", association: "MEMBER" };
  const runner = new FakeProcessRunner([
    get(
      `${R}/pulls/5/comments?per_page=100`,
      lines(
        {
          ...base,
          id: 1,
          body: "live",
          at: "2026-01-03",
          path: "a.ts",
          line: 3,
          position: 4,
          replyTo: null,
        },
        {
          ...base,
          id: 2,
          body: "old",
          at: "2026-01-01",
          path: "a.ts",
          line: null,
          position: null,
          replyTo: 1,
        },
      ),
    ),
    get(
      `${R}/pulls/5/reviews?per_page=100`,
      lines({ ...base, id: 3, body: null, at: null, state: "APPROVED" }),
    ),
    get(
      `${R}/issues/5/comments?per_page=100`,
      lines({ ...base, id: 4, body: "hi\nthere", at: "2026-01-02" }),
    ),
  ]);
  const r = await new GhStewardReader(runner).comments(5);
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.map((c) => [c.id, c.kind, c.outdated, c.createdAt])).toEqual([
    [3, "review", false, ""],
    [2, "inline", true, "2026-01-01"],
    [4, "conversation", false, "2026-01-02"],
    [1, "inline", false, "2026-01-03"],
  ]);
  expect(r.value.find((c) => c.id === 2)).toMatchObject({ inReplyTo: 1, path: "a.ts", line: null });
  expect(r.value.find((c) => c.id === 3)).toMatchObject({ body: "", reviewState: "APPROVED" });
  expect(r.value.find((c) => c.id === 4)?.body).toBe("hi\nthere");
  expect(runner.calls.every((c) => c.argv.includes("--paginate"))).toBe(true);
});

test("comments fails on malformed gh output", async () => {
  const runner = new FakeProcessRunner([get(`${R}/pulls/5/comments?per_page=100`, '{"id":"x"}\n')]);
  expect((await new GhStewardReader(runner).comments(5)).ok).toBe(false);
});

test("markedBy counts a marker only from the given login", async () => {
  const path = `${R}/issues/5/comments`;
  const rows = lines({ login: "mallory", body: "<!-- k -->" }, { login: "me", body: null });
  const runner = new FakeProcessRunner([get(`${path}?per_page=100`, rows)]);
  expect(await markedBy(runner, path, "me", "<!-- k -->")).toEqual({ ok: true, value: false });
  expect(await markedBy(runner, path, "mallory", "<!-- k -->")).toEqual({ ok: true, value: true });
});

test("permission reads the login's permission; 404 and odd logins are none", async () => {
  const path = (l: string) => `${R}/collaborators/${l}/permission`;
  const reader = (calls: ScriptedCall[]) => new GhStewardReader(new FakeProcessRunner(calls));
  expect(await reader([get(path("alice"), "write\n")]).permission("alice")).toEqual({
    ok: true,
    value: "write",
  });
  expect(await reader([get(path("alice"), "\n")]).permission("alice")).toEqual({
    ok: true,
    value: "none",
  });
  const missing = { exitCode: 1, stdout: "", stderr: "gh: Not Found (HTTP 404)" };
  expect(await reader([{ prefix: ["gh"], result: missing }]).permission("ghost")).toEqual({
    ok: true,
    value: "none",
  });
  const denied = { exitCode: 1, stdout: "", stderr: "HTTP 403: Must have push access" };
  expect(await reader([{ prefix: ["gh"], result: denied }]).permission("bob")).toMatchObject({
    ok: false,
    error: { kind: "auth" },
  });
  for (const bad of ["../admin", "a b", "claude[bot]", "", "x".repeat(40), "a/b"]) {
    const runner = new FakeProcessRunner([]);
    expect(await new GhStewardReader(runner).permission(bad)).toEqual({ ok: true, value: "none" });
    expect(runner.calls).toEqual([]);
  }
});

test("comments carry isBot, and file-level comments are never outdated", async () => {
  const base = { association: "NONE", at: "2026-01-01", body: "x" };
  const runner = new FakeProcessRunner([
    get(
      `${R}/pulls/5/comments?per_page=100`,
      lines(
        { ...base, id: 1, login: "Copilot", type: "Bot", position: 2, subject: "line" },
        { ...base, id: 2, login: "alice", type: "User", position: null, subject: "file" },
        { ...base, id: 3, login: "bob", type: "User", position: null, subject: "line" },
      ),
    ),
    get(`${R}/pulls/5/reviews?per_page=100`, ""),
    get(`${R}/issues/5/comments?per_page=100`, lines({ ...base, id: 4, login: "carol" })),
  ]);
  const r = await new GhStewardReader(runner).comments(5);
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.map((c) => [c.id, c.isBot, c.outdated])).toEqual([
    [1, true, false],
    [2, false, false],
    [3, false, true],
    [4, false, false],
  ]);
});
