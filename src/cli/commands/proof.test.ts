import { expect, test } from "bun:test";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { type FakeProofOptions, fakeProof } from "../../testing/fake-proof";
import { proofCommand } from "./proof";

async function run(args: string[], opts: FakeProofOptions = {}, env: Record<string, string> = {}) {
  const io = captureIO();
  const fake = fakeProof(opts);
  const outDirs: (string | null)[] = [];
  const code = await proofCommand.run(
    args,
    commandContext(io, undefined, env, undefined, {
      proof: (outDir) => {
        outDirs.push(outDir);
        return fake.ports;
      },
    }),
  );
  return { code, out: io.outLines.join("\n"), err: io.errLines.join("\n"), fake, outDirs };
}

test("help and usage errors", async () => {
  expect((await run(["--help"])).code).toBe(0);
  expect((await run(["run", "--help"])).code).toBe(0);
  expect((await run([])).code).toBe(2);
  expect((await run(["nope"])).code).toBe(2);
  expect((await run(["run", "--mode", "loud"])).code).toBe(2);
  expect((await run(["run", "--base", "--evil"])).code).toBe(2);
  expect((await run(["run", "--label", "a b"])).code).toBe(2);
  expect((await run(["run"], {}, { SHIPWRIGHT_PROOF: "maybe" })).code).toBe(2);
});

test("plan prints what would run and runs nothing", async () => {
  const r = await run(["plan"]);
  expect(r.code).toBe(0);
  expect(r.out).toContain("web: npm run start (detected, port 4000)");
  expect(r.out).toContain("cli: node bin/todo.js --help");
  expect(r.fake.started).toEqual([]);
});

test("run: text by default, markdown section on request, publish only when asked", async () => {
  const text = await run(["run", "--out", "/tmp/p"]);
  expect(text.code).toBe(0);
  expect(text.out).toContain("proof: pass");
  expect(text.outDirs).toEqual(["/tmp/p"]);
  expect(text.fake.published).toEqual([]);
  const md = await run(["run", "--format", "markdown", "--publish", "--label", "feat/x"]);
  expect(md.out).toContain("### Proof it runs");
  expect(md.fake.published).toEqual(["feat/x"]);
});

test("run: a failure exits 3 only in enforce mode", async () => {
  const failing = { cli: { exitCode: 1, stdout: "", stderr: "bad", timedOut: false } };
  expect((await run(["run"], failing)).code).toBe(0);
  expect((await run(["run", "--mode", "enforce"], failing)).code).toBe(3);
  expect((await run(["run"], failing, { SHIPWRIGHT_PROOF: "enforce" })).code).toBe(3);
});

test("run: an unreadable repository exits 1", async () => {
  const r = await run(["run"], { config: "{" });
  expect(r.code).toBe(1);
  expect(r.err).toContain("proof");
});
