import { expect, test } from "bun:test";
import { idempotencyKey } from "../../shared/kernel/durability";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import {
  GhGithubWriter,
  INCIDENT_LABEL,
  idempotencyMarker,
  MAX_BODY_CHARS,
  MAX_TITLE_CHARS,
} from "./gh-github-writer";

const key = idempotencyKey("breaker", "open", "1760440000000");
const report = { title: "Breaker open", body: "Dispatch stopped." };
const ME = "shipwright-bot";
const ok = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const fail = (stderr: string): ScriptedCall["result"] => ({ exitCode: 1, stdout: "", stderr });
const whoami = (): ScriptedCall => ({ prefix: ["gh", "api", "user"], result: ok(`${ME}\n`) });
const openIncidents = (incidents: unknown[]): ScriptedCall => ({
  prefix: ["gh", "issue", "list"],
  result: ok(JSON.stringify(incidents)),
});
const incident = (number: number, over: Record<string, unknown> = {}) => ({
  number,
  body: "old",
  author: { login: ME },
  comments: [],
  ...over,
});
const created = (n: number): ScriptedCall => ({
  prefix: ["gh", "issue", "create"],
  result: ok(`https://github.com/o/r/issues/${n}\n`),
});
const marked = `Dispatch stopped.\n\n${idempotencyMarker(key)}`;

test("creates the incident when none is open (label already exists)", async () => {
  const runner = new FakeProcessRunner([whoami(), openIncidents([]), created(901)]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 901, action: "created" } });
  expect(runner.calls.map((c) => c.argv.slice(0, 3))).toEqual([
    ["gh", "api", "user"],
    ["gh", "issue", "list"],
    ["gh", "issue", "create"],
    ["gh", "issue", "list"],
  ]);
  expect(runner.calls[0]?.argv).toEqual(["gh", "api", "user", "--jq", ".login"]);
  expect(runner.calls[1]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--label",
    INCIDENT_LABEL,
    "--limit",
    "20",
    "--json",
    "number,body,author,comments",
  ]);
  expect(runner.calls[2]?.argv).toEqual([
    "gh",
    "issue",
    "create",
    "--title=Breaker open",
    "--body-file",
    "-",
    "--label",
    INCIDENT_LABEL,
  ]);
  expect(runner.calls[2]?.stdin).toBe(marked);
});

test("creates the label only when gh reports it missing, then retries once", async () => {
  let creates = 0;
  const runner = new FakeProcessRunner([
    whoami(),
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    // Scripted lookups take the first match, so switch behaviour by call count below.
    created(5),
  ]);
  const original = runner.run.bind(runner);
  runner.run = async (req) => {
    if (req.argv[1] === "issue" && req.argv[2] === "create" && creates++ === 0) {
      (runner.calls as unknown[]).push(req);
      return {
        exitCode: 1,
        stdout: "",
        stderr: `could not add label: '${INCIDENT_LABEL}' not found`,
        timedOut: false,
      };
    }
    return original(req);
  };
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 5, action: "created" } });
  const seq = runner.calls.map((c) => c.argv.slice(1, 3).join(" "));
  expect(seq).toEqual([
    "api user",
    "issue list",
    "issue create",
    "label create",
    "issue create",
    "issue list",
  ]);
  const label = runner.calls.find((c) => c.argv[1] === "label");
  expect(label?.argv).not.toContain("--force");
});

test("comments once on the open incident for a new key", async () => {
  const runner = new FakeProcessRunner([
    whoami(),
    openIncidents([incident(7, { comments: [{ body: "earlier trip", author: { login: ME } }] })]),
    { prefix: ["gh", "issue", "comment"], result: ok("https://github.com/o/r/issues/7#c1") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 7, action: "commented" } });
  expect(runner.calls[2]?.argv).toEqual(["gh", "issue", "comment", "7", "--body-file", "-"]);
  expect(runner.calls[2]?.stdin).toBe(marked);
});

test("does nothing when our own key is already on the incident (body or comment)", async () => {
  for (const found of [
    incident(7, { body: `x ${idempotencyMarker(key)}` }),
    incident(7, {
      body: null,
      comments: [{ body: `y ${idempotencyMarker(key)}`, author: { login: ME } }],
    }),
  ]) {
    const runner = new FakeProcessRunner([whoami(), openIncidents([found])]);
    const r = await new GhGithubWriter(runner).ensureIncident(key, report);
    expect(r).toEqual({ ok: true, value: { issue: 7, action: "unchanged" } });
    expect(runner.calls).toHaveLength(2);
  }
});

test("a marker forged by another author is ignored", async () => {
  const runner = new FakeProcessRunner([
    whoami(),
    openIncidents([
      incident(7, {
        body: `x ${idempotencyMarker(key)}`,
        author: { login: "mallory" },
        comments: [{ body: idempotencyMarker(key), author: { login: "mallory" } }],
      }),
    ]),
    { prefix: ["gh", "issue", "comment"], result: ok() },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 7, action: "commented" } });
});

test("fails closed when the authenticated login cannot be read", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh", "api", "user"], result: fail("HTTP 401: Bad credentials") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(!r.ok && r.error.kind).toBe("auth");
  expect(runner.calls).toHaveLength(1);
});

test("the login is fetched once per writer", async () => {
  const runner = new FakeProcessRunner([whoami(), openIncidents([incident(7, { body: marked })])]);
  const writer = new GhGithubWriter(runner);
  await writer.ensureIncident(key, report);
  await writer.ensureIncident(key, report);
  expect(runner.calls.filter((c) => c.argv[1] === "api")).toHaveLength(1);
});

test("checks the key across all open incidents and comments on the lowest-numbered", async () => {
  const runner = new FakeProcessRunner([
    whoami(),
    openIncidents([incident(12), incident(9, { comments: [] })]),
    { prefix: ["gh", "issue", "comment"], result: ok() },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 9, action: "commented" } });

  const second = new FakeProcessRunner([
    whoami(),
    openIncidents([incident(9), incident(12, { body: marked })]),
  ]);
  const r2 = await new GhGithubWriter(second).ensureIncident(key, report);
  expect(r2).toEqual({ ok: true, value: { issue: 12, action: "unchanged" } });
});

test("a concurrent tripper that lost the race closes its duplicate and returns the canonical", async () => {
  let lists = 0;
  const runner = new FakeProcessRunner([
    whoami(),
    created(21),
    { prefix: ["gh", "issue", "close"], result: ok() },
    { prefix: ["gh", "issue", "comment"], result: ok() },
  ]);
  const original = runner.run.bind(runner);
  runner.run = async (req) => {
    if (req.argv[1] === "issue" && req.argv[2] === "list") {
      (runner.calls as unknown[]).push(req);
      const out = lists++ === 0 ? [] : [incident(20), incident(21, { body: marked })];
      return { exitCode: 0, stdout: JSON.stringify(out), stderr: "", timedOut: false };
    }
    return original(req);
  };
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 20, action: "commented" } });
  const close = runner.calls.find((c) => c.argv[2] === "close");
  expect(close?.argv.slice(0, 5)).toEqual(["gh", "issue", "close", "21", "--comment"]);
  expect(close?.argv[5]).toContain("#20");
  const comment = runner.calls.find((c) => c.argv[2] === "comment");
  expect(comment?.argv.slice(3, 4)).toEqual(["20"]);
});

test("a huge body goes on stdin, trimmed so the marker survives; the title is capped", async () => {
  const runner = new FakeProcessRunner([whoami(), openIncidents([]), created(3)]);
  const big = { title: "t".repeat(1000), body: "x".repeat(200_000) };
  await new GhGithubWriter(runner).ensureIncident(key, big);
  const call = runner.calls[2];
  expect(call?.argv.join(" ").length).toBeLessThan(1000);
  expect(call?.argv.some((a) => a.includes("xxxx"))).toBe(false);
  expect(call?.argv[3]).toBe(`--title=${"t".repeat(MAX_TITLE_CHARS)}`);
  expect(call?.stdin?.length).toBe(MAX_BODY_CHARS + 2 + idempotencyMarker(key).length);
  expect(call?.stdin?.endsWith(idempotencyMarker(key))).toBe(true);
});

test("a failed write is a classified error", async () => {
  const runner = new FakeProcessRunner([
    whoami(),
    openIncidents([]),
    {
      prefix: ["gh", "issue", "create"],
      result: fail("HTTP 403: Resource not accessible by integration"),
    },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(!r.ok && r.error.kind).toBe("auth");
});

test("unexpected create output is a failed error", async () => {
  const bad = new FakeProcessRunner([
    whoami(),
    openIncidents([]),
    { prefix: ["gh", "issue", "create"], result: ok("created!") },
  ]);
  const r = await new GhGithubWriter(bad).ensureIncident(key, report);
  expect(!r.ok && r.error.message).toMatch(/issue URL/);
});
