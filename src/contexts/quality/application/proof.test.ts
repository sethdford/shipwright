import { expect, test } from "bun:test";
import { err } from "../../../shared/kernel/result";
import { fakeProof } from "../../../testing/fake-proof";
import type { FlowResult } from "../domain/proof/result";
import { type ProofRequest, runProof } from "./proof";

const req = (over: Partial<ProofRequest> = {}): ProofRequest => ({
  baseRef: "origin/main",
  mode: "advisory",
  publish: true,
  label: "feat-x",
  video: true,
  dryRun: false,
  ...over,
});
const flow: FlowResult = {
  name: "page /",
  steps: [{ step: "goto /", ok: true }],
  screenshots: [{ name: "home", file: "1-home.png" }],
  video: "1-flow.webm",
  consoleErrors: [],
  pageErrors: [],
  httpErrors: [],
  blocked: [],
};

test("runs the detected web app and CLI, publishes, and renders the PR section", async () => {
  const f = fakeProof({ flows: [flow] });
  const r = await runProof(f.ports, req());
  expect(r.ok).toBe(true);
  if (!r.ok) return;
  expect(f.started).toEqual([["npm", "run", "start"]]);
  expect(f.stopped).toBe(1);
  expect(f.cliRuns).toEqual([["node", "bin/todo.js", "--help"]]);
  expect(f.published).toEqual(["feat-x"]);
  expect(f.publishedFiles[0]).toEqual([
    "cli/1.txt",
    "web/server.log",
    "web/1-home.png",
    "web/1-flow.webm",
  ]);
  expect(r.value.verdict.status).toBe("pass");
  expect(r.value.blocked).toBe(false);
  expect(r.value.section).toContain(
    "![home](https://github.com/o/r/raw/abc/feat-x/web/1-home.png)",
  );
  expect(r.value.section).toContain("usage: todo");
  expect(f.written["web/server.log"]).toBe("ready token=[redacted]");
  expect(f.written["proof.md"]).toBe(r.value.section);
  expect(JSON.parse(f.written["report.json"] ?? "{}").verdict.status).toBe("pass");
});

test("an app that does not start fails, blocks in enforce, and shows its log", async () => {
  const f = fakeProof({ start: { ok: false, reason: "exited 1", log: "Error: no DATABASE_URL" } });
  const r = await runProof(f.ports, req({ mode: "enforce", publish: false }));
  expect(r.ok && r.value.blocked).toBe(true);
  if (!r.ok) return;
  expect(r.value.verdict.failures[0]).toBe("app did not start: exited 1");
  expect(r.value.section).toContain("Error: no DATABASE_URL");
  expect(f.published).toEqual([]);
});

test("no browser: the app still has to start, and the proof is noted, not failed", async () => {
  const f = fakeProof({
    browserMissing: "Playwright is not installed",
    cli: { exitCode: 0, stdout: "", stderr: "", timedOut: false },
  });
  const r = await runProof(f.ports, req({ mode: "enforce" }));
  expect(r.ok && r.value.verdict.status).toBe("pass");
  expect(f.stopped).toBe(1);
});

test("a publish failure keeps the proof and says so", async () => {
  const f = fakeProof({
    flows: [flow],
    publish: err({ kind: "failed", message: "push rejected" }),
  });
  const r = await runProof(f.ports, req());
  expect(r.ok).toBe(true);
  if (!r.ok) return;
  expect(r.value.baseUrl).toBeNull();
  expect(r.value.verdict.warnings).toContain("artifacts not published: push rejected");
  expect(r.value.section).toContain("`web/1-home.png`");
});

test("off and dry runs start nothing", async () => {
  const off = fakeProof();
  const r1 = await runProof(off.ports, req({ mode: "off" }));
  expect(r1.ok && r1.value.verdict.status).toBe("skipped");
  const dry = fakeProof();
  const r2 = await runProof(dry.ports, req({ dryRun: true }));
  expect(r2.ok && r2.value.plan.cli.length).toBe(1);
  expect([...off.started, ...dry.started, ...off.cliRuns, ...dry.cliRuns]).toEqual([]);
});

test("a broken proof.json fails the proof (and blocks in enforce); the app still runs", async () => {
  const f = fakeProof({ config: '{"web":{"port":1}}' });
  const r = await runProof(f.ports, req({ mode: "enforce" }));
  expect(r.ok && r.value.blocked).toBe(true);
  if (!r.ok) return;
  expect(r.value.verdict.failures[0]).toContain(".shipwright/proof.json: web.port");
  expect(f.started).toEqual([["npm", "run", "start"]]);
});

test("a proof.json this change turned off fails; one that was already off is skipped", async () => {
  const off = '{"enabled":false}';
  const changed = await runProof(
    fakeProof({ config: off, changed: [".shipwright/proof.json"] }).ports,
    req({ mode: "enforce" }),
  );
  expect(changed.ok && changed.value.blocked).toBe(true);
  const before = await runProof(fakeProof({ config: off }).ports, req({ mode: "enforce" }));
  expect(before.ok && before.value.verdict.status).toBe("skipped");
});
