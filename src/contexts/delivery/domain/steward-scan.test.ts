import { expect, test } from "bun:test";
import { addedLines, containsSecret, scanDiff, scanVerdict } from "./steward-scan";

// Fake secrets are built by concatenation so no secret-looking literal lands in the repository.
const AWS = "AKIA" + "ABCDEFGHIJKLMNOP";
const GITHUB = "ghp" + "_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8";
const ANTHROPIC = "sk-" + "ant-" + "api03-abcdefghijklmnopqrstuvwxyz";
const OPENAI = `sk-${"a".repeat(20)}${"B".repeat(20)}1234`;
const OPENAI_PROJ = `sk-${"proj-"}${"aB3_".repeat(8)}${"x-Y9".repeat(4)}`;
const OPENAI_SVC = `sk-${"svcacct-"}${"Q_w-".repeat(12)}`;
const SLACK = "xox" + "b-" + "123456789012-abcdefgh";
const STRIPE = "sk_" + "live_" + "abcdefghijklmnopqrstuvwx";
const GOOGLE = "AI" + "za" + "SyA1234567890abcdefghijklmnopqrstuv";
const PEM = "-----BEGIN " + "RSA PRIVATE KEY-----";

/** A one-file diff adding `lines` at line `start` of `path`. */
function diff(path: string, lines: readonly string[], start = 1): string {
  return [
    `diff --git a/${path} b/${path}`,
    `--- a/${path}`,
    `+++ b/${path}`,
    `@@ -${start},0 +${start},${lines.length} @@`,
    ...lines.map((l) => `+${l}`),
  ].join("\n");
}
const rules = (d: string) => scanDiff(d).map((f) => f.rule);

test("each secret type blocks", () => {
  const cases: [string, string][] = [
    [`const key = "${AWS}";`, "secret-aws"],
    [`token: ${GITHUB}`, "secret-github"],
    [`ANTHROPIC_API_KEY=${ANTHROPIC}`, "secret-anthropic"],
    [`OPENAI_API_KEY=${OPENAI}`, "secret-openai"],
    [`slack = '${SLACK}'`, "secret-slack"],
    [`stripe(${STRIPE})`, "secret-stripe"],
    [`maps_key = "${GOOGLE}"`, "secret-google"],
    [PEM, "secret-private-key"],
  ];
  for (const [line, rule] of cases) {
    const found = scanDiff(diff("config/app.env", [line]));
    expect(found.map((f) => f.rule)).toEqual([rule]);
    expect(found[0]?.severity).toBe("block");
    expect(scanVerdict(found)).toBe("block");
  }
});

test("a Google key ending in a dash before a quote still blocks", () => {
  const key = `AI${"za"}${"A".repeat(34)}-`;
  expect(rules(diff("a.js", [`k = "${key}";`]))).toEqual(["secret-google"]);
});

test("near-misses are not secrets", () => {
  expect(rules(diff("a.ts", [`const id = "AKIA" + "SHORT";`]))).toEqual([]);
  expect(rules(diff("a.ts", ["const prefix = 'sk-ant-';"]))).toEqual([]);
  expect(rules(diff("a.ts", ["// rotate the ghp_ tokens yearly"]))).toEqual([]);
});

test("there is no in-line opt-out: an allow comment silences nothing", () => {
  const optOut = " // shipwright-scan: allow";
  expect(rules(diff("src/a.test.ts", [`it.only("x", () => {});${optOut}`]))).toEqual([
    "focused-test",
  ]);
  expect(rules(diff("src/a.ts", [`console.log(1);${optOut}`]))).toEqual(["console-log"]);
  const secret = scanDiff(diff("src/a.ts", [`const k = "${AWS}";${optOut}`]));
  expect(secret.map((f) => f.rule)).toEqual(["secret-aws"]);
  expect(scanVerdict(secret)).toBe("block");
});

test("OpenAI project and service-account keys with _ and - block", () => {
  for (const key of [OPENAI_PROJ, OPENAI_SVC]) {
    expect(rules(diff("a.env", [`OPENAI_API_KEY=${key}`]))).toEqual(["secret-openai"]);
  }
});

test("containsSecret uses the block rules only", () => {
  for (const s of [AWS, GITHUB, ANTHROPIC, OPENAI, OPENAI_PROJ, SLACK, STRIPE, GOOGLE, PEM]) {
    expect(containsSecret(`see ${s} here`)).toBe(true);
  }
  expect(containsSecret("debugger; it.only(x) <<<<<<< HEAD console.log(1)")).toBe(false);
  expect(containsSecret("")).toBe(false);
});

test("conflict markers, focused tests and debugger statements need a fix", () => {
  const d = diff("src/a.test.ts", [
    "<<<<<<< HEAD",
    "=======",
    ">>>>>>> feature",
    'describe.only("suite", () => {',
    'fit("x", () => {});',
    "  debugger;",
  ]);
  const found = scanDiff(d);
  expect(found.map((f) => [f.rule, f.line])).toEqual([
    ["conflict-marker", 1],
    ["conflict-marker", 3],
    ["focused-test", 4],
    ["focused-test", 5],
    ["debugger", 6],
  ]);
  expect(scanVerdict(found)).toBe("fix");
  expect(rules(diff("app.py", ["    breakpoint()", "pdb.set_trace()"]))).toEqual([
    "debugger",
    "debugger",
  ]);
});

test("a bare ======= (a setext heading) is not a conflict marker", () => {
  expect(rules(diff("docs/a.md", ["Title", "======="]))).toEqual([]);
});

test("focused tests in their other spellings, including e2e files", () => {
  const spellings = [
    'test.only.each([1, 2])("x %d", f);',
    'describe["only"]("suite", f);',
    "it[ 'only' ](\"x\", f);",
    'suite.only("s", f);',
    'context.only ("c", f);',
  ];
  for (const line of spellings) {
    expect(rules(diff("src/a.spec.ts", [line]))).toEqual(["focused-test"]);
  }
  expect(rules(diff("e2e/login.ts", ['test.only("logs in", f)']))).toEqual(["focused-test"]);
  expect(rules(diff("src/login.e2e.ts", ['test.only("logs in", f)']))).toEqual(["focused-test"]);
  expect(rules(diff("src/only.ts", ['const only = x["only"];']))).toEqual([]);
});

test("focused and skipped tests count only in test files; console.log only in source", () => {
  expect(rules(diff("docs/guide.md", ['it.only("x")', "console.log(1)"]))).toEqual([]);
  expect(rules(diff("tests/run.js", ["it.skip('x', f)"]))).toEqual(["skipped-test"]);
  expect(rules(diff("src/x.mjs", ["console.log(1)"]))).toEqual(["console-log"]);
  expect(scanVerdict(scanDiff(diff("src/x.ts", ["console.log(1)"])))).toBe("pass");
  expect(scanVerdict([])).toBe("pass");
});

test("line numbers follow the new file across hunks and context lines", () => {
  const d = [
    "diff --git a/src/a.ts b/src/a.ts",
    "--- a/src/a.ts",
    "+++ b/src/a.ts",
    "@@ -1,3 +1,4 @@",
    " one",
    "-two",
    "+TWO",
    "+debugger;",
    " three",
    "@@ -40,2 +41,3 @@ function f() {",
    " forty",
    "+console.log(x)",
    " forty-one",
  ].join("\n");
  expect(addedLines(d)).toEqual([
    { path: "src/a.ts", line: 2, text: "TWO" },
    { path: "src/a.ts", line: 3, text: "debugger;" },
    { path: "src/a.ts", line: 42, text: "console.log(x)" },
  ]);
});

test("several files keep their own paths", () => {
  const d = `${diff("src/a.ts", ["debugger;"])}\n${diff("src/b.test.ts", ["test.only('x', f)"], 9)}`;
  expect(scanDiff(d).map((f) => [f.path, f.line, f.rule])).toEqual([
    ["src/a.ts", 1, "debugger"],
    ["src/b.test.ts", 9, "focused-test"],
  ]);
});

test("deleted files and removed lines are not scanned", () => {
  const d = [
    "diff --git a/old.env b/old.env",
    "deleted file mode 100644",
    "--- a/old.env",
    "+++ /dev/null",
    "@@ -1,2 +0,0 @@",
    `-KEY=${AWS}`,
    "-debugger;",
  ].join("\n");
  expect(addedLines(d)).toEqual([]);
  expect(scanDiff(d)).toEqual([]);
});

test("binary files and lines before any hunk are skipped", () => {
  const d = [
    "diff --git a/img.png b/img.png",
    "new file mode 100644",
    "Binary files /dev/null and b/img.png differ",
  ].join("\n");
  expect(addedLines(d)).toEqual([]);
});

test("an added line that starts with '++ ' cannot hide a secret by posing as a file header", () => {
  const d = diff("src/a.ts", [`++ ${AWS}`, "debugger;"]);
  const found = scanDiff(d);
  expect(found.map((f) => [f.path, f.line, f.rule])).toEqual([
    ["src/a.ts", 1, "secret-aws"],
    ["src/a.ts", 2, "debugger"],
  ]);
});

test("a removed line that starts with '-- ' does not confuse the next file", () => {
  const d = [
    "--- a/src/a.ts",
    "+++ b/src/a.ts",
    "@@ -1,2 +1,1 @@",
    "--- old comment",
    "+debugger;",
  ].join("\n");
  expect(addedLines(d)).toEqual([{ path: "src/a.ts", line: 1, text: "debugger;" }]);
});

test("a no-newline marker does not shift line numbers", () => {
  const d = [
    "--- a/a.ts",
    "+++ b/a.ts",
    "@@ -1 +1,2 @@",
    "-x",
    "\\ No newline at end of file",
    "+x",
    "+debugger;",
  ].join("\n");
  expect(scanDiff(d).map((f) => f.line)).toEqual([2]);
});

test("an OpenAI-looking kebab-case word is not a key; real key shapes are", () => {
  expect(containsSecret("sk-learn-compatible-preprocessing-pipeline-helper-module")).toBe(false);
  expect(containsSecret(`sk-${"a1".repeat(24)}`)).toBe(true);
  expect(containsSecret(`sk-proj-${"Ab3_".repeat(10)}`)).toBe(true);
  const anthropic = `sk-ant-api03-${"x9".repeat(20)}`;
  const hits = scanDiff(`+++ b/a.ts\n@@ -0,0 +1,1 @@\n+${anthropic}`);
  expect(hits.length).toBe(1);
});
