import { describe, expect, test } from "bun:test";
import { extractBlocks, parseAnswer } from "./agent-output";

const manifest = (o: unknown) => `\`\`\`acceptance.json\n${JSON.stringify(o)}\n\`\`\``;
const good = {
  criteria: [
    { id: "AC-1", text: "login rejects an expired token" },
    { id: "AC-2", text: "login accepts a fresh token" },
  ],
  tests: [{ path: "tests/login.test.ts", criteria: ["AC-1", "AC-2"] }],
};
const file =
  "```tests/login.test.ts\ntest('AC-1: rejects expired', () => {});\ntest('AC-2: accepts fresh', () => {});\n```";

describe("extractBlocks", () => {
  test("keeps path-labelled blocks and skips prose and language-only fences", () => {
    const blocks = extractBlocks("intro\n```ts\nnot a file\n```\n```a/b.test.ts\nx\n```\n");
    expect(blocks).toEqual([{ path: "a/b.test.ts", content: "x\n" }]);
  });
});

describe("parseAnswer", () => {
  test("accepts a manifest whose tests are all given and traced", () => {
    const r = parseAnswer(`Plan...\n${manifest(good)}\n${file}`);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.files.map((f) => f.path)).toEqual(["tests/login.test.ts"]);
  });

  test("needs exactly one manifest", () => {
    const r = parseAnswer(file);
    expect(r.ok).toBe(false);
  });

  test("lists every manifest problem: uncovered criterion, unknown id", () => {
    const bad = {
      criteria: [...good.criteria, { id: "AC-3", text: "logs the attempt" }],
      tests: [{ path: "tests/login.test.ts", criteria: ["AC-1", "AC-9"] }],
    };
    const r = parseAnswer(
      `${manifest(bad)}\n${file.replace("AC-1", "AC-0")}\n\`\`\`src/hack.ts\nx\n\`\`\``,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) {
      const all = r.problems.join("\n");
      expect(all).toContain("AC-3 has no test");
      expect(all).toContain("unknown criterion AC-9");
    }
  });

  test("a file block not listed in the manifest is rejected (no stray writes)", () => {
    const r = parseAnswer(`${manifest(good)}\n${file}\n\`\`\`src/hack.ts\nx\n\`\`\``);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems.join()).toContain("src/hack.ts: file is not listed");
  });

  test("an untraced criterion is rejected (the id must appear in the test)", () => {
    const r = parseAnswer(`${manifest(good)}\n${file.replace("AC-2: accepts", "accepts")}`);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems.join()).toContain("claims AC-2 but never mentions it");
  });

  test("rejects paths outside the repository even when listed", () => {
    const bad = { ...good, tests: [{ path: "../x/login.test.ts", criteria: ["AC-1", "AC-2"] }] };
    const r = parseAnswer(`${manifest(bad)}\n${file.replace("tests/login", "../x/login")}`);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems.join()).toContain("traversal");
  });

  test("not_testable needs a reason and no tests", () => {
    expect(parseAnswer(manifest({ not_testable: "docs-only change" })).ok).toBe(true);
    expect(parseAnswer(manifest({ not_testable: "" })).ok).toBe(false);
    expect(parseAnswer(`${manifest({ not_testable: "x", tests: good.tests })}\n${file}`).ok).toBe(
      false,
    );
  });

  test("unknown manifest keys are rejected", () => {
    expect(parseAnswer(`${manifest({ ...good, skip_gate: true })}\n${file}`).ok).toBe(false);
  });
});
