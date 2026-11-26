import { describe, expect, test } from "bun:test";
import type { AdapterError, ProcessResult } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import type { AcceptanceWorkspace, ArtifactStore, TestExecutor } from "../ports";
import { materialize, verifyRed } from "./acceptance";
import { lockTests, verifyGreen } from "./gate";

const HEAD = "c".repeat(40);
const blobOf = (text: string) => `b${String(text.length).padStart(39, "0")}`;

class FakeWorkspace implements AcceptanceWorkspace {
  readonly files = new Map<string, string>();
  readonly committed = new Map<string, string>();
  diff = "";
  restored: string[] = [];
  async readText(p: string): Promise<Result<string, AdapterError>> {
    const t = this.files.get(p);
    return t === undefined ? err({ kind: "not_found", message: p }) : ok(t);
  }
  async writeText(p: string, t: string): Promise<Result<void, AdapterError>> {
    this.files.set(p, t);
    return ok(undefined);
  }
  async exists(p: string) {
    return this.files.has(p);
  }
  async headCommit(): Promise<Result<string, AdapterError>> {
    return ok(HEAD);
  }
  async blobAt(_c: string, p: string): Promise<Result<string | null, AdapterError>> {
    const t = this.committed.get(p);
    return ok(t === undefined ? null : blobOf(t));
  }
  async worktreeBlob(p: string): Promise<Result<string, AdapterError>> {
    return ok(blobOf(this.files.get(p) ?? ""));
  }
  async diffSince(): Promise<Result<string, AdapterError>> {
    return ok(this.diff);
  }
  async restore(_c: string, p: string): Promise<Result<void, AdapterError>> {
    this.files.set(p, this.committed.get(p) ?? "");
    this.restored.push(p);
    return ok(undefined);
  }
  commit() {
    for (const [p, t] of this.files) this.committed.set(p, t);
  }
}

class MemArtifacts implements ArtifactStore {
  readonly files = new Map<string, string>();
  async read(p: string): Promise<Result<string, AdapterError>> {
    const t = this.files.get(p);
    return t === undefined ? err({ kind: "not_found", message: p }) : ok(t);
  }
  async write(p: string, t: string): Promise<Result<void, AdapterError>> {
    this.files.set(p, t);
    return ok(undefined);
  }
}

class ScriptedExec implements TestExecutor {
  readonly calls: string[][] = [];
  constructor(public next: (argv: readonly string[]) => ProcessResult) {}
  async run(argv: readonly string[]) {
    this.calls.push([...argv]);
    return this.next(argv);
  }
}

const PATH = "tests/login.test.ts";
const TEST_SRC = "test('AC-1: rejects expired', () => { expect(login('old')).toBe(false) })\n";
const ANSWER = `\`\`\`acceptance.json
{"criteria":[{"id":"AC-1","text":"rejects expired tokens"}],"tests":[{"path":"${PATH}","criteria":["AC-1"]}]}
\`\`\`
\`\`\`${PATH}
${TEST_SRC}\`\`\``;
const red: ProcessResult = {
  exitCode: 1,
  stdout: `${PATH}:\n(fail) AC-1\nexpect(received).toBe(expected)\n 0 pass\n 1 fail`,
  stderr: "",
  timedOut: false,
};
const green: ProcessResult = {
  exitCode: 0,
  stdout: `${PATH}:\n(pass) AC-1\n 1 pass\n 0 fail`,
  stderr: "",
  timedOut: false,
};

function setup() {
  const ws = new FakeWorkspace();
  const artifacts = new MemArtifacts();
  const exec = new ScriptedExec(() => red);
  return { ws, artifacts, exec, ports: { ws, artifacts, exec } };
}

describe("acceptance workflow", () => {
  test("materialize → verify-red → lock → verify-green", async () => {
    const { ws, artifacts, exec, ports } = setup();
    expect(await materialize(ANSWER, "/a/m.json", ports)).toEqual({
      ok: true,
      kind: "tests",
      files: [PATH],
    });
    const r = await verifyRed(
      { manifestPath: "/a/m.json", testCmd: "bun test", timeoutMs: 1000 },
      ports,
    );
    expect(r).toMatchObject({ ok: true, kind: "tests" });
    expect(exec.calls[0]).toEqual(["bun", "test", PATH]);
    ws.commit();
    const lock = await lockTests(
      { manifestPath: "/a/m.json", lockPath: "/a/lock.json", testCmd: "bun test", timeoutMs: 1000 },
      ports,
    );
    expect(lock.ok).toBe(true);
    expect(artifacts.files.get("/a/lock.json")).toContain(HEAD);
    exec.next = () => green;
    const g = await verifyGreen(
      { lockPath: "/a/lock.json", timeoutMs: 1000, integrity: "enforce" },
      ports,
    );
    expect(g).toMatchObject({ ok: true, violations: [], restored: [] });
  });

  test("materialize refuses to overwrite an existing file and writes nothing", async () => {
    const { ws, ports } = setup();
    ws.files.set(PATH, "old");
    const m = await materialize(ANSWER, "/a/m.json", ports);
    expect(m.ok).toBe(false);
    expect(ws.files.get(PATH)).toBe("old");
  });

  test("verify-red fails when a test already passes", async () => {
    const { exec, ports } = setup();
    await materialize(ANSWER, "/a/m.json", ports);
    exec.next = () => green;
    const r = await verifyRed(
      { manifestPath: "/a/m.json", testCmd: "bun test", timeoutMs: 1000 },
      ports,
    );
    expect(r.ok).toBe(false);
    if (r.kind === "tests") expect(r.runs[0]?.verdict.reason).toBe("passed");
  });

  test("lock refuses uncommitted or edited tests", async () => {
    const { ws, ports } = setup();
    await materialize(ANSWER, "/a/m.json", ports);
    const opts = {
      manifestPath: "/a/m.json",
      lockPath: "/a/lock.json",
      testCmd: "bun test",
      timeoutMs: 1000,
    };
    expect(await lockTests(opts, ports)).toMatchObject({
      ok: false,
      problems: [`${PATH}: not committed at HEAD`],
    });
    ws.commit();
    ws.files.set(PATH, `${TEST_SRC}// edited`);
    expect(await lockTests(opts, ports)).toMatchObject({
      ok: false,
      problems: [`${PATH}: working tree differs from HEAD`],
    });
  });

  test("verify-green restores a weakened acceptance test, runs the original, and blocks on tampering", async () => {
    const { ws, exec, ports } = setup();
    await materialize(ANSWER, "/a/m.json", ports);
    ws.commit();
    await lockTests(
      { manifestPath: "/a/m.json", lockPath: "/a/lock.json", testCmd: "bun test", timeoutMs: 1000 },
      ports,
    );
    ws.files.set(PATH, "test('AC-1', () => {})\n");
    ws.diff = `diff --git a/${PATH} b/${PATH}\n--- a/${PATH}\n+++ b/${PATH}\n-${TEST_SRC.trim()}\n+test('AC-1', () => {})\n`;
    exec.next = () => green;
    const g = await verifyGreen(
      { lockPath: "/a/lock.json", timeoutMs: 1000, integrity: "enforce" },
      ports,
    );
    expect(ws.restored).toEqual([PATH]);
    expect(ws.files.get(PATH)).toBe(TEST_SRC);
    expect(g.ok).toBe(false);
    expect(g.violations.map((v) => v.rule)).toContain("acceptance_test_changed");
    const warn = await verifyGreen(
      { lockPath: "/a/lock.json", timeoutMs: 1000, integrity: "warn" },
      ports,
    );
    expect(warn.ok).toBe(true);
  });

  test("verify-green fails closed on a missing or malformed lock", async () => {
    const { artifacts, ports } = setup();
    expect(
      (await verifyGreen({ lockPath: "/none", timeoutMs: 1, integrity: "enforce" }, ports)).ok,
    ).toBe(false);
    artifacts.files.set("/bad", '{"version":1,"commit":"HEAD"}');
    expect(
      (await verifyGreen({ lockPath: "/bad", timeoutMs: 1, integrity: "enforce" }, ports)).ok,
    ).toBe(false);
  });

  test("not_testable passes verify-red with its reason", async () => {
    const { ports } = setup();
    await materialize(
      '```acceptance.json\n{"not_testable":"README wording only"}\n```',
      "/a/m.json",
      ports,
    );
    expect(await verifyRed({ manifestPath: "/a/m.json", timeoutMs: 1 }, ports)).toEqual({
      ok: true,
      kind: "not_testable",
      reason: "README wording only",
    });
  });
});
