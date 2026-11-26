import { describe, expect, test } from "bun:test";
import type { LineChannel } from "../../contexts/intelligence";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { fakeRepoPorts } from "../../testing/repo-model-fixture";
import { repomodelCommand } from "./repomodel";

const FILES = {
  "src/budget.ts": "export function evaluateBudget(spent: number) {\n  return spent;\n}\n",
  "src/budget.test.ts": 'import { evaluateBudget } from "./budget";\n',
};

function run(args: string[], env: Record<string, string> = {}, stdio?: LineChannel) {
  const io = captureIO();
  const { ports } = fakeRepoPorts(FILES);
  const files = new FakeFileReader({ "/task.md": "the daily budget is ignored" });
  const ctx = commandContext(io, undefined, { PWD: "/repo", ...env }, files, undefined, {
    repoModel: ports,
    stdio,
  });
  return repomodelCommand
    .run(args, ctx)
    .then((code) => ({ code, out: io.outLines.join("\n"), err: io.errLines.join("\n") }));
}

describe("shipwright repomodel", () => {
  test("build reports what it read; queries answer", async () => {
    expect((await run(["build"])).out).toBe("✓ 2 files (2 re-read, 0 reused, 0 removed)");
    expect((await run(["def", "evaluateBudget"])).out).toContain("src/budget.ts:1");
    expect((await run(["tests", "src/budget.ts"])).out).toBe("src/budget.test.ts (imports)");
    expect((await run(["localize", "--task", "/task.md"])).out).toContain("src/budget.ts");
  });

  test("brief: JSON with the files it named; nothing on the off arm", async () => {
    const on = JSON.parse((await run(["brief", "--task", "/task.md", "--json"])).out);
    expect(on).toMatchObject({ arm: "on", files: ["src/budget.ts"] });
    expect(on.brief).toContain("## Repository model");
    const off = await run(["brief", "--task", "/task.md"], { SHIPWRIGHT_REPO_MODEL: "OFF" });
    expect(off).toEqual({ code: 0, out: "", err: "" });
  });

  test("usage errors exit 2", async () => {
    expect((await run([])).code).toBe(2);
    expect((await run(["nope"])).code).toBe(2);
    expect((await run(["def"])).code).toBe(2);
    expect((await run(["search", "x", "--limit", "0"])).code).toBe(2);
    expect((await run(["brief"])).code).toBe(2);
    expect((await run(["--help"])).code).toBe(0);
  });

  test("mcp serves one JSON-RPC reply per request line", async () => {
    const written: string[] = [];
    const stdio: LineChannel = {
      async *lines() {
        yield JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" });
        yield JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" });
      },
      write: (l) => written.push(l),
    };
    expect((await run(["mcp"], {}, stdio)).code).toBe(0);
    expect(written).toHaveLength(1);
    expect(JSON.parse(written[0] ?? "{}").result.tools).toHaveLength(9);
  });
});
