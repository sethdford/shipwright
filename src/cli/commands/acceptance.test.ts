import { describe, expect, test } from "bun:test";
import type { AcceptancePorts } from "../../contexts/planning";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { acceptanceCommand, parseFlags, parseTemplate } from "./acceptance";

const PATH = "tests/a.test.ts";
const ANSWER = `\`\`\`acceptance.json
{"criteria":[{"id":"AC-1","text":"x"}],"tests":[{"path":"${PATH}","criteria":["AC-1"]}]}
\`\`\`
\`\`\`${PATH}
test("AC-1: x", () => expect(f()).toBe(1))
\`\`\``;

function fakePorts(
  exitCode: number,
  stdout: string,
): AcceptancePorts & { written: Map<string, string> } {
  const written = new Map<string, string>();
  const read = async (p: string): Promise<Result<string, AdapterError>> => {
    const t = written.get(p);
    return t === undefined ? err({ kind: "not_found", message: p }) : ok(t);
  };
  const write = async (p: string, t: string): Promise<Result<void, AdapterError>> => {
    written.set(p, t);
    return ok(undefined);
  };
  return {
    written,
    ws: {
      readText: read,
      writeText: write,
      exists: async (p) => written.has(p),
      headCommit: async () => ok("a".repeat(40)),
      blobAt: async () => ok(null),
      worktreeBlob: async () => ok("b".repeat(40)),
      diffSince: async () => ok(""),
      restore: async () => ok(undefined),
    },
    exec: { run: async () => ({ exitCode, stdout, stderr: "", timedOut: false }) },
    artifacts: { read, write },
  };
}

async function run(args: string[], ports: AcceptancePorts) {
  const io = captureIO();
  const files = new FakeFileReader({ "/answer.md": ANSWER });
  const code = await acceptanceCommand.run(
    args,
    commandContext(io, undefined, {}, files, undefined, () => ports),
  );
  return { code, out: io.outLines.join("\n"), err: io.errLines.join("\n") };
}

describe("shipwright acceptance", () => {
  test("materialize then verify-red: red for the right reason exits 0", async () => {
    const ports = fakePorts(
      1,
      `${PATH}:\n(fail) AC-1: x\nexpect(received).toBe(expected)\n 0 pass\n 1 fail`,
    );
    expect(
      (await run(["materialize", "--answer", "/answer.md", "--manifest", "/m.json"], ports)).code,
    ).toBe(0);
    expect(ports.written.has(PATH)).toBe(true);
    const red = await run(["verify-red", "--manifest", "/m.json", "--test-cmd", "bun test"], ports);
    expect(red.code).toBe(0);
    expect(red.out).toContain("fails for the right reason");
  });

  test("verify-red exits 1 with the reason and the output tail when the test already passes", async () => {
    const ports = fakePorts(0, " 1 pass");
    await run(["materialize", "--answer", "/answer.md", "--manifest", "/m.json"], ports);
    const red = await run(["verify-red", "--manifest", "/m.json", "--test-cmd", "bun test"], ports);
    expect(red.code).toBe(1);
    expect(red.out).toContain("already passes");
    expect(red.out).toContain("--- tests/a.test.ts (bun test tests/a.test.ts) ---");
  });

  test("verify-green fails closed without a lock", async () => {
    expect((await run(["verify-green", "--lock", "/none.json"], fakePorts(0, ""))).code).toBe(1);
  });

  test("usage errors exit 2", async () => {
    const p = fakePorts(0, "");
    expect((await run([], p)).code).toBe(2);
    expect((await run(["nope"], p)).code).toBe(2);
    expect((await run(["verify-red"], p)).code).toBe(2);
    expect((await run(["verify-green", "--lock", "/l", "--integrity", "off"], p)).code).toBe(2);
    expect((await run(["verify-red", "--manifest", "/m", "--command", "bun test"], p)).code).toBe(
      2,
    );
    expect((await run(["--help"], p)).code).toBe(0);
  });

  test("flag and template parsing", () => {
    expect(parseFlags("lock", ["--manifest", "m"])).toBe("missing --lock");
    expect(parseFlags("verify-red", ["--manifest", "m", "--manifest", "n"])).toBe(
      "--manifest given twice",
    );
    expect(parseTemplate('["bun","test","{file}"]')).toEqual(["bun", "test", "{file}"]);
    expect(parseTemplate("[1]")).toBe("--command must be a JSON array of strings");
  });
});
