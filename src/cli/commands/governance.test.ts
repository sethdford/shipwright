import { describe, expect, test } from "bun:test";
import type { DocSource, RepoDocs } from "../../contexts/governance";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { governanceCommand } from "./governance";

const DOCS: Record<string, string> = {
  "docs/adr/0001-bun.md": "# 0001. Bun\n\nStatus: accepted\n\n## Decision\nUse Bun.\n",
  "docs/policies/ci.md":
    "---\nid: POL-CI\napplies_to: [.github/**]\n---\n# CI\n\nPin actions by SHA.\n",
  ".shipwright/lessons/L-0001.md":
    "---\nid: L-0001\nstatus: active\nfingerprint: known\nkeywords: [mktemp]\n---\nCreate the temp dir first.\n",
};

const repo: RepoDocs = {
  async list(
    _s: DocSource,
    prefixes: readonly string[],
  ): Promise<Result<readonly string[], AdapterError>> {
    return ok(Object.keys(DOCS).filter((p) => prefixes.some((x) => p.startsWith(x))));
  },
  async read(_s: DocSource, path: string): Promise<Result<string, AdapterError>> {
    const t = DOCS[path];
    return t === undefined ? err({ kind: "not_found", message: path }) : ok(t);
  },
};

const files = new FakeFileReader({
  "/issue.md": "The heartbeat test fails at mktemp",
  "/changed.txt": ".github/workflows/ci.yml\n",
  "/fail.log": "running tests\nError: something new broke\n",
});

async function run(args: string[], env: Record<string, string> = {}) {
  const io = captureIO();
  const code = await governanceCommand.run(args, commandContext(io, undefined, env, files, repo));
  return { code, out: io.outLines.join("\n"), err: io.errLines.join("\n") };
}

describe("governance brief", () => {
  test("includes documents and the lessons that fit, and reports which in --json", async () => {
    const r = await run(["brief", "--issue", "/issue.md", "--json"]);
    expect(r.code).toBe(0);
    const j = JSON.parse(r.out);
    expect(j.docs).toEqual(["POL-CI", "ADR-0001"]);
    expect(j.lessons.map((l: { id: string }) => l.id)).toEqual(["L-0001"]);
    expect(j.brief).toContain("Create the temp dir first.");
  });

  test("SHIPWRIGHT_LESSONS=off and --no-governance are the two ablation arms", async () => {
    const noLessons = JSON.parse(
      (await run(["brief", "--issue", "/issue.md", "--json"], { SHIPWRIGHT_LESSONS: "off" })).out,
    );
    expect(noLessons.lessons).toEqual([]);
    expect(noLessons.docs).toHaveLength(2);
    const noDocs = JSON.parse(
      (await run(["brief", "--issue", "/issue.md", "--no-governance", "--json"])).out,
    );
    expect(noDocs.docs).toEqual([]);
    expect(noDocs.lessons).toHaveLength(1);
  });

  test("prints nothing when both halves are off", async () => {
    const r = await run(["brief", "--no-lessons", "--no-governance"]);
    expect([r.code, r.out]).toEqual([0, ""]);
  });

  test("an unreadable --issue fails closed", async () => {
    expect((await run(["brief", "--issue", "/missing.md"])).code).toBe(1);
  });
});

describe("governance check, list and propose", () => {
  test("check names the scoped policy for a workflow change", async () => {
    const r = await run(["check", "--changed", "/changed.txt"]);
    expect(r.code).toBe(0);
    expect(r.out).toContain("- [ ] POL-CI: CI (docs/policies/ci.md)");
  });

  test("check needs --changed", async () => {
    expect((await run(["check"])).code).toBe(2);
  });

  test("list shows every document and lesson", async () => {
    const r = JSON.parse((await run(["list", "--json"])).out);
    expect(r.documents.map((d: { id: string }) => d.id)).toEqual(["ADR-0001", "POL-CI", "L-0001"]);
  });

  test("propose drafts the next lesson from a log", async () => {
    const r = await run(["propose", "--log", "/fail.log", "--source", "run 7"]);
    expect(r.code).toBe(0);
    expect(r.out).toContain("id: L-0002");
    expect(r.out).toContain("status: proposed");
  });

  test("usage errors exit 2", async () => {
    expect((await run([])).code).toBe(2);
    expect((await run(["nope"])).code).toBe(2);
    expect((await run(["brief", "--log", "/x"])).code).toBe(2);
    expect((await run(["propose", "--log", "/fail.log"])).code).toBe(2);
    expect((await run(["--help"])).code).toBe(0);
  });
});
