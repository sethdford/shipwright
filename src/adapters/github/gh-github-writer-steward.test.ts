import { expect, test } from "bun:test";
import { idempotencyKey } from "../../shared/kernel/durability";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import { GhGithubWriter, idempotencyMarker, MAX_BODY_CHARS } from "./gh-github-writer";

const R = "repos/{owner}/{repo}";
const ME = "shipwright-bot";
const SHA = "1".repeat(40);
const key = idempotencyKey("steward", "pr7", "reply", "11", SHA);
const marker = idempotencyMarker(key);
const ok = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const whoami: ScriptedCall = { prefix: ["gh", "api", "user"], result: ok(`${ME}\n`) };
const listing = (path: string, rows: { login: string; body: string | null }[]): ScriptedCall => ({
  prefix: ["gh", "api", "-X", "GET", `${path}?per_page=100`],
  result: ok(rows.map((r) => JSON.stringify(r)).join("\n")),
});
/** Answers any `gh api -X ...` call not scripted before it (the writes; asserted via `posted`). */
const post = (result = ok("{}")): ScriptedCall => ({ prefix: ["gh", "api", "-X"], result });
const posts = (runner: FakeProcessRunner) => runner.calls.filter((c) => c.argv.includes("POST"));
const posted = (runner: FakeProcessRunner, i = 0) => posts(runner)[i]?.argv.join(" ");

test("replyToReviewComment posts the body with its marker to the thread root", async () => {
  const runner = new FakeProcessRunner([whoami, listing(`${R}/pulls/7/comments`, []), post()]);
  const r = await new GhGithubWriter(runner).replyToReviewComment(key, 7, 10, "Fixed.");
  expect(r).toEqual({ ok: true, value: "done" });
  const [p] = posts(runner);
  expect(posted(runner)).toBe(`gh api -X POST ${R}/pulls/7/comments/10/replies --input -`);
  expect(JSON.parse(p?.stdin ?? "")).toEqual({ body: `Fixed.\n\n${marker}` });
});

test("a marker already posted by me: unchanged, nothing posted", async () => {
  const runner = new FakeProcessRunner([
    whoami,
    listing(`${R}/pulls/7/comments`, [{ login: ME, body: `Fixed.\n\n${marker}` }]),
  ]);
  const r = await new GhGithubWriter(runner).replyToReviewComment(key, 7, 10, "Fixed.");
  expect(r).toEqual({ ok: true, value: "unchanged" });
  expect(posts(runner)).toEqual([]);
});

test("the same marker forged by someone else does not stop the post", async () => {
  const runner = new FakeProcessRunner([
    whoami,
    listing(`${R}/issues/7/comments`, [
      { login: "mallory", body: marker },
      { login: ME, body: null },
      { login: ME, body: idempotencyMarker(idempotencyKey("other")) },
    ]),
    post(),
  ]);
  const r = await new GhGithubWriter(runner).commentOnPull(key, 7, "Summary.");
  expect(r).toEqual({ ok: true, value: "done" });
  expect(posts(runner)).toHaveLength(1);
  expect(posted(runner)).toBe(`gh api -X POST ${R}/issues/7/comments --input -`);
});

test("the body is trimmed so the marker always survives", async () => {
  const runner = new FakeProcessRunner([whoami, listing(`${R}/issues/7/comments`, []), post()]);
  await new GhGithubWriter(runner).commentOnPull(key, 7, "x".repeat(MAX_BODY_CHARS + 500));
  const body = JSON.parse(posts(runner)[0]?.stdin ?? "").body as string;
  expect(body.endsWith(marker)).toBe(true);
  expect(body.length).toBe(MAX_BODY_CHARS + 2 + marker.length);
});

test("the body travels on stdin as JSON, never in argv", async () => {
  const evil = '"; gh repo delete --yes; echo "';
  const runner = new FakeProcessRunner([whoami, listing(`${R}/issues/7/comments`, []), post()]);
  await new GhGithubWriter(runner).commentOnPull(key, 7, evil);
  expect(runner.calls.some((c) => c.argv.some((a) => a.includes(evil)))).toBe(false);
});

test("failures while reconciling or posting are returned, not swallowed", async () => {
  const listFail = new FakeProcessRunner([
    whoami,
    { prefix: ["gh", "api", "-X", "GET"], result: { exitCode: 1, stdout: "", stderr: "HTTP 502" } },
  ]);
  expect(await new GhGithubWriter(listFail).commentOnPull(key, 7, "x")).toMatchObject({
    ok: false,
    error: { kind: "transient" },
  });
  expect(posts(listFail)).toEqual([]);
  const postFail = new FakeProcessRunner([
    whoami,
    listing(`${R}/issues/7/comments`, []),
    post({ exitCode: 1, stdout: "", stderr: "HTTP 403" }),
  ]);
  expect(await new GhGithubWriter(postFail).commentOnPull(key, 7, "x")).toMatchObject({
    error: { kind: "auth" },
  });
  const noLogin = new FakeProcessRunner([{ prefix: ["gh", "api", "user"], result: ok("") }]);
  expect((await new GhGithubWriter(noLogin).commentOnPull(key, 7, "x")).ok).toBe(false);
});

test("the login is looked up once per writer", async () => {
  const runner = new FakeProcessRunner([whoami, listing(`${R}/issues/7/comments`, []), post()]);
  const w = new GhGithubWriter(runner);
  await w.commentOnPull(key, 7, "a");
  await w.commentOnPull(idempotencyKey("b"), 7, "b");
  expect(runner.calls.filter((c) => c.argv[2] === "user")).toHaveLength(1);
});

test("rerunJob re-runs a completed job and leaves a running one alone", async () => {
  const status = (s: string): ScriptedCall => ({
    prefix: ["gh", "api", "-X", "GET", `${R}/actions/jobs/9`],
    result: ok(`${s}\n`),
  });
  const done = new FakeProcessRunner([status("completed"), post()]);
  expect(await new GhGithubWriter(done).rerunJob(key, 9)).toEqual({ ok: true, value: "done" });
  expect(posted(done)).toBe(`gh api -X POST ${R}/actions/jobs/9/rerun`);
  const running = new FakeProcessRunner([status("in_progress")]);
  expect(await new GhGithubWriter(running).rerunJob(key, 9)).toEqual({
    ok: true,
    value: "unchanged",
  });
  expect(posts(running)).toEqual([]);
});

const git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", "/w"];
const lsRemote = (stdout: string, exitCode = 0): ScriptedCall => ({
  prefix: [...git, "ls-remote"],
  result: { exitCode, stdout, stderr: "" },
});

test("pushCommit fast-forwards with hooks off and never forces", async () => {
  const runner = new FakeProcessRunner([
    lsRemote(`${"0".repeat(40)}\trefs/heads/feat/x\n`),
    { prefix: [...git, "push"], result: ok() },
  ]);
  const r = await new GhGithubWriter(runner).pushCommit(key, "/w", "feat/x", SHA);
  expect(r).toEqual({ ok: true, value: "done" });
  expect(runner.calls[0]?.argv).toEqual([...git, "ls-remote", "origin", "refs/heads/feat/x"]);
  const push = runner.calls[1]?.argv ?? [];
  expect(push).toEqual([...git, "push", "--no-verify", "origin", `${SHA}:refs/heads/feat/x`]);
  expect(push.some((a) => /^(-f|--force.*|\+.*)$/.test(a) || a.startsWith("+"))).toBe(false);
});

test("pushCommit is unchanged when origin is already at the sha", async () => {
  const runner = new FakeProcessRunner([lsRemote(`${SHA}\trefs/heads/feat/x\n`)]);
  expect(await new GhGithubWriter(runner).pushCommit(key, "/w", "feat/x", SHA)).toEqual({
    ok: true,
    value: "unchanged",
  });
  expect(runner.calls).toHaveLength(1);
});

test("pushCommit still pushes when ls-remote fails, and reports a rejected push", async () => {
  const runner = new FakeProcessRunner([
    lsRemote("", 128),
    {
      prefix: [...git, "push"],
      result: { exitCode: 1, stdout: "", stderr: "! [rejected] (non-fast-forward)" },
    },
  ]);
  const r = await new GhGithubWriter(runner).pushCommit(key, "/w", "feat/x", SHA);
  expect(r).toMatchObject({ ok: false, error: { kind: "failed" } });
  expect(runner.calls).toHaveLength(2);
});

test("pushCommit refuses a bad branch or sha without running git", async () => {
  const bad: [string, string][] = [
    ["--force", SHA],
    ["-f", SHA],
    ["+main", SHA],
    ["a..b", SHA],
    ["feat x", SHA],
    ["", SHA],
    ["feat/x", "abc"],
    ["feat/x", `+${SHA.slice(1)}`],
    ["feat/x", "G".repeat(40)],
  ];
  for (const [branch, sha] of bad) {
    const runner = new FakeProcessRunner([{ prefix: ["git"], result: ok() }]);
    const r = await new GhGithubWriter(runner).pushCommit(key, "/w", branch, sha);
    expect(r.ok).toBe(false);
    expect(runner.calls).toEqual([]);
  }
});
