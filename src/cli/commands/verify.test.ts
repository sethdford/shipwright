import { expect, test } from "bun:test";
import type { FileChange, PullRecord } from "../../contexts/quality";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { fakeVerifierPorts } from "../../testing/fake-verifier";
import { verifyCommand } from "./verify";

const f = (path: string, additions = 10): FileChange => ({ path, additions, deletions: 0 });

async function run(args: string[], ports = fakeVerifierPorts(), env: Record<string, string> = {}) {
  const io = captureIO();
  const files = new FakeFileReader({ "/tmp/body.md": "## Summary\nAdds a flag." });
  const code = await verifyCommand.run(
    args,
    commandContext(io, undefined, env, files, undefined, ports),
  );
  return { code, out: io.outLines.join("\n"), err: io.errLines.join("\n") };
}

test("help and usage errors", async () => {
  expect((await run(["--help"])).code).toBe(0);
  expect((await run(["score", "--help"])).code).toBe(0);
  expect((await run([])).code).toBe(2);
  expect((await run(["nope"])).code).toBe(2);
  expect((await run(["score", "--tests", "maybe"])).code).toBe(2);
  expect((await run(["score", "--cross", "1.5"])).code).toBe(2);
  expect((await run(["train", "--days", "0"])).code).toBe(2);
  expect((await run(["score"], fakeVerifierPorts(), { SHIPWRIGHT_VERIFIER: "loud" })).code).toBe(2);
});

test("score: a clean change passes and prints its chance", async () => {
  const ports = fakeVerifierPorts({
    local: { files: [f("src/a.ts"), f("src/a.test.ts")], patch: "" },
  });
  const r = await run(
    ["score", "--title", "fix(cli): a (#1)", "--tests", "pass", "--body-file", "/tmp/body.md"],
    ports,
  );
  expect(r.code).toBe(0);
  expect(r.out).toContain("✓ verifier: pass");
  expect(r.out).toContain("hand-set prior");
});

test("score: a hard stop exits 3 in enforce mode and 0 (warn) in advisory mode", async () => {
  const local = { files: [f("docs/plans/2026-01-01-x.md")], patch: "" };
  const enforce = await run(["score", "--mode", "enforce"], fakeVerifierPorts({ local }));
  expect(enforce.code).toBe(3);
  expect(enforce.out).toContain("no change beyond plans");
  const advisory = await run(["score"], fakeVerifierPorts({ local }));
  expect(advisory.code).toBe(0);
  expect(advisory.out).toContain("enforce mode would: block");
  const env = await run(["score"], fakeVerifierPorts({ local }), {
    SHIPWRIGHT_VERIFIER: "enforce",
  });
  expect(env.code).toBe(3);
});

test("score --format json carries the decision", async () => {
  const r = await run(["score", "--format", "json"]);
  expect(JSON.parse(r.out).decision.verdict).toBeDefined();
});

test("train then show", async () => {
  const pull: PullRecord = {
    number: 9,
    title: "feat: x",
    body: "via `shipwright pipeline`",
    headRef: "ci/issue-4",
    labels: [],
    createdAtMs: Date.UTC(2026, 9, 1),
    mergedAtMs: null,
    closedAtMs: Date.UTC(2026, 9, 2),
    commits: [],
  };
  const ports = fakeVerifierPorts({ pulls: [pull], prFiles: { 9: [f("a.ts")] } });
  const t = await run(["train"], ports);
  expect(t.code).toBe(0);
  expect(t.out).toContain("trained on 1 closed PRs");
  expect(t.out).toContain("#9");
  const s = await run(["show"], ports);
  expect(s.out).toContain("on 1 PRs");
  expect((await run(["show"])).out).toContain("No trained verifier yet");
});
