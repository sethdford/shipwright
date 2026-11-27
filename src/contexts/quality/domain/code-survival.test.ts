import { expect, test } from "bun:test";
import { isSignificant, measureSurvival, parseAddedLines, survivalVerdict } from "./code-survival";

const DIFF = [
  "diff --git a/src/a.ts b/src/a.ts",
  "--- a/src/a.ts",
  "+++ b/src/a.ts",
  "@@ -1,0 +1,3 @@",
  "+export const alpha = 1;",
  "+}",
  "+export const beta = 2;",
  "diff --git a/old.ts b/old.ts",
  "--- a/old.ts",
  "+++ /dev/null",
  "@@ -1 +0,0 @@",
  "-gone",
  "diff --git a/b.sh b/b.sh",
  "--- /dev/null",
  "+++ b/b.sh",
  "@@ -0,0 +1 @@",
  '+echo "hello world"',
].join("\n");

test("added lines per file; deleted files add nothing", () => {
  const added = parseAddedLines(DIFF);
  expect([...added.keys()]).toEqual(["src/a.ts", "b.sh"]);
  expect(added.get("src/a.ts")).toEqual(["export const alpha = 1;", "}", "export const beta = 2;"]);
});

test("trivial lines are not tracked", () => {
  for (const l of ["", "   ", "}", "});", "fi", "else", "x=1"])
    expect(isSignificant(l)).toBe(false);
  expect(isSignificant("  const total = a + b;")).toBe(true);
});

test("survival counts each added line once against the file at the horizon", () => {
  const s = measureSurvival({
    added: parseAddedLines(DIFF),
    later: new Map([
      ["src/a.ts", "  export const alpha = 1;\nexport const gamma = 3;\n"],
      ["b.sh", null],
    ]),
  });
  // alpha kept (indentation ignored); beta rewritten; b.sh deleted. `}` is not counted.
  expect(s).toEqual({ added: 3, kept: 1, rate: 1 / 3 });
});

test("a repeated line in the change needs as many copies at the horizon", () => {
  const line = "doSomething(value);";
  const s = measureSurvival({
    added: new Map([["a.ts", [line, line]]]),
    later: new Map([["a.ts", line]]),
  });
  expect(s.kept).toBe(1);
});

test("verdicts: survived, rewritten, too small, unmeasured (no sample)", () => {
  expect(survivalVerdict({ added: 10, kept: 6, rate: 0.6 })).toBe("survived");
  expect(survivalVerdict({ added: 10, kept: 4, rate: 0.4 })).toBe("rewritten");
  expect(survivalVerdict({ added: 2, kept: 0, rate: 0 })).toBe("too-small");
  expect(survivalVerdict(null)).toBe("unmeasured");
});

test("an added line starting with '++ ' is content, not a file header; quoted paths are unquoted", () => {
  const diff = [
    'diff --git "a/caf\\303\\251 x.txt" "b/caf\\303\\251 x.txt"',
    '--- "a/caf\\303\\251 x.txt"',
    '+++ "b/caf\\303\\251 x.txt"',
    "@@ -0,0 +1,2 @@",
    "+++ added marker",
    "+second line here",
  ].join("\n");
  const added = parseAddedLines(diff);
  expect([...added.keys()]).toEqual(["café x.txt"]);
  expect(added.get("café x.txt")).toEqual(["++ added marker", "second line here"]);
});

test("a change with only trivial lines is too small, not unmeasured", () => {
  expect(survivalVerdict({ added: 0, kept: 0, rate: null })).toBe("too-small");
});
