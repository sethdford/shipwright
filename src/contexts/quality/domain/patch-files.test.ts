import { expect, test } from "bun:test";
import { filesFromPatch } from "./patch-files";

test("counts added and removed lines per file, not the --- and +++ headers", () => {
  const patch = [
    "diff --git a/src/a.ts b/src/a.ts",
    "index 1..2 100644",
    "--- a/src/a.ts",
    "+++ b/src/a.ts",
    "@@ -1,2 +1,2 @@",
    "-old",
    "+new",
    "+more",
    " same",
    "diff --git a/img.png b/img.png",
    "Binary files a/img.png and b/img.png differ",
  ].join("\n");
  expect(filesFromPatch(patch)).toEqual([
    { path: "src/a.ts", additions: 2, deletions: 1 },
    { path: "img.png", additions: 0, deletions: 0 },
  ]);
});

test("quoted paths, and content lines that look like headers, are read correctly", () => {
  const patch = [
    "diff --git a/a b.txt b/a b.txt",
    "--- a/a b.txt",
    "+++ b/a b.txt",
    "@@ -0,0 +1,3 @@",
    "+one",
    "+++ looks like a header",
    "+three",
    'diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"',
    "new file mode 100644",
    "--- /dev/null",
    '+++ "b/caf\\303\\251.txt"',
    "@@ -0,0 +1,2 @@",
    "+x",
    "+y",
  ].join("\n");
  expect(filesFromPatch(patch)).toEqual([
    { path: "a b.txt", additions: 3, deletions: 0 },
    { path: "café.txt", additions: 2, deletions: 0 },
  ]);
});
