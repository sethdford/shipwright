import { expect, test } from "bun:test";
import { idempotencyKey } from "../../shared/kernel/durability";
import { FakeProcessRunner, type ScriptedCall } from "../../testing/fake-process-runner";
import { GhGithubWriter, INCIDENT_LABEL, idempotencyMarker } from "./gh-github-writer";

const key = idempotencyKey("breaker", "open", "1760440000000");
const report = { title: "Breaker open", body: "Dispatch stopped." };
const ok = (stdout = ""): ScriptedCall["result"] => ({ exitCode: 0, stdout, stderr: "" });
const openIncidents = (incidents: unknown[]): ScriptedCall => ({
  prefix: ["gh", "issue", "list"],
  result: ok(JSON.stringify(incidents)),
});

test("creates the label and the incident when none is open", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    { prefix: ["gh", "issue", "create"], result: ok("https://github.com/o/r/issues/901\n") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 901, action: "created" } });
  expect(runner.calls.map((c) => c.argv.slice(0, 3))).toEqual([
    ["gh", "issue", "list"],
    ["gh", "label", "create"],
    ["gh", "issue", "create"],
  ]);
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--label",
    INCIDENT_LABEL,
    "--limit",
    "1",
    "--json",
    "number,body,comments",
  ]);
  expect(runner.calls[2]?.argv).toEqual([
    "gh",
    "issue",
    "create",
    "--title",
    "Breaker open",
    "--body",
    `Dispatch stopped.\n\n${idempotencyMarker(key)}`,
    "--label",
    INCIDENT_LABEL,
  ]);
});

test("comments once on the open incident for a new key", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([{ number: 7, body: "old", comments: [{ body: "earlier trip" }] }]),
    { prefix: ["gh", "issue", "comment"], result: ok("https://github.com/o/r/issues/7#c1") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(r).toEqual({ ok: true, value: { issue: 7, action: "commented" } });
  expect(runner.calls[1]?.argv).toEqual([
    "gh",
    "issue",
    "comment",
    "7",
    "--body",
    `Dispatch stopped.\n\n${idempotencyMarker(key)}`,
  ]);
});

test("does nothing when the key is already on the incident (body or comment)", async () => {
  for (const incident of [
    { number: 7, body: `x ${idempotencyMarker(key)}`, comments: [] },
    { number: 7, body: null, comments: [{ body: `y ${idempotencyMarker(key)}` }] },
  ]) {
    const runner = new FakeProcessRunner([openIncidents([incident])]);
    const r = await new GhGithubWriter(runner).ensureIncident(key, report);
    expect(r).toEqual({ ok: true, value: { issue: 7, action: "unchanged" } });
    expect(runner.calls).toHaveLength(1);
  }
});

test("a failed write is a classified error", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    {
      prefix: ["gh", "issue", "create"],
      result: {
        exitCode: 1,
        stdout: "",
        stderr: "HTTP 403: Resource not accessible by integration",
      },
    },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(!r.ok && r.error.kind).toBe("auth");
});

test("unexpected create output is a failed error", async () => {
  const runner = new FakeProcessRunner([
    openIncidents([]),
    { prefix: ["gh", "label", "create"], result: ok() },
    { prefix: ["gh", "issue", "create"], result: ok("created!") },
  ]);
  const r = await new GhGithubWriter(runner).ensureIncident(key, report);
  expect(!r.ok && r.error.message).toMatch(/issue URL/);
});
