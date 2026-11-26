import { describe, expect, test } from "bun:test";
import { fakeRepoPorts } from "../../../testing/repo-model-fixture";
import { handleMcpLine } from "./mcp";
import { RepoSession } from "./session";

const FILES = {
  "src/budget.ts":
    "/** Daily cap. */\nexport function evaluateBudget(spent: number) {\n  return spent;\n}\n",
  "src/daemon.ts":
    'import { evaluateBudget } from "./budget";\nexport function dispatch() {\n  evaluateBudget(1);\n}\n',
  "src/budget.test.ts": 'import { evaluateBudget } from "./budget";\n',
};

async function call(session: RepoSession, msg: object) {
  const out = await handleMcpLine(session, "4.0.0", JSON.stringify({ jsonrpc: "2.0", ...msg }));
  return out === undefined ? undefined : JSON.parse(out);
}

async function tool(session: RepoSession, name: string, args: object) {
  const r = await call(session, { id: 9, method: "tools/call", params: { name, arguments: args } });
  return { text: r.result.content[0].text as string, isError: r.result.isError as boolean };
}

describe("the repomodel MCP server", () => {
  const { ports } = fakeRepoPorts(FILES, "src/budget.ts @money\n");
  const session = new RepoSession(ports, "/repo");

  test("initialize echoes the protocol version and names the server; notifications get no reply", async () => {
    const r = await call(session, {
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-03-26" },
    });
    expect(r.result).toMatchObject({
      protocolVersion: "2025-03-26",
      serverInfo: { name: "repomodel" },
    });
    expect(await call(session, { method: "notifications/initialized" })).toBeUndefined();
  });

  test("tools/list lists every tool with a JSON schema", async () => {
    const r = await call(session, { id: 2, method: "tools/list" });
    const names = r.result.tools.map((t: { name: string }) => t.name);
    expect(names).toEqual([
      "search",
      "definition",
      "references",
      "outline",
      "dependencies",
      "tests_for",
      "owners",
      "repo_map",
      "localize",
    ]);
    expect(r.result.tools[0].inputSchema.required).toEqual(["query"]);
  });

  test("the queries answer from the model", async () => {
    expect((await tool(session, "definition", { name: "evaluateBudget" })).text).toContain(
      "src/budget.ts:2",
    );
    const refs = (await tool(session, "references", { name: "evaluateBudget" })).text;
    expect(refs).toContain("src/daemon.ts:3 in dispatch");
    expect(refs).toContain("src/budget.ts:2 [definition]");
    expect((await tool(session, "tests_for", { path: "src/budget.ts" })).text).toBe(
      "src/budget.test.ts (imports)",
    );
    expect((await tool(session, "owners", { path: "src/budget.ts" })).text).toContain("@money");
    expect((await tool(session, "owners", { path: "src/budget.ts" })).text).toContain(
      "Ada (3 commits",
    );
    expect((await tool(session, "dependencies", { path: "src/daemon.ts" })).text).toContain(
      "imports (1): src/budget.ts",
    );
    expect((await tool(session, "outline", { path: "src/daemon.ts" })).text).toContain(
      "function dispatch",
    );
    expect((await tool(session, "search", { query: "daily cap" })).text).toContain(
      "evaluateBudget",
    );
    expect((await tool(session, "localize", { task: "budget is ignored" })).text).toContain(
      "src/budget.ts",
    );
    expect((await tool(session, "repo_map", {})).text.split("\n")[0]).toBe("src/budget.ts");
  });

  test("bad calls come back as tool errors, bad JSON as a parse error, unknown methods as -32601", async () => {
    expect(await tool(session, "definition", {})).toEqual({
      text: "Missing argument: name",
      isError: true,
    });
    expect((await tool(session, "nope", {})).isError).toBe(true);
    expect((await tool(session, "references", { name: "a(b" })).text).toContain(
      "Not an identifier",
    );
    expect(JSON.parse((await handleMcpLine(session, "4", "{nope")) ?? "{}").error.code).toBe(
      -32700,
    );
    expect((await call(session, { id: 3, method: "resources/list" })).error.code).toBe(-32601);
  });
});
