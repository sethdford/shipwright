import { expect, test } from "bun:test";
import { auditCommands, auditPatch, isVoid, repoSlug, topFlags } from "./integrity";
import type { BenchTask } from "./task";

const task = {
  id: "t",
  repo: "https://github.com/Acme/Widget",
  testPatch:
    "diff --git a/tests/test_add.py b/tests/test_add.py\n--- a/tests/test_add.py\n+++ b/tests/test_add.py\n",
  testCommands: [["bash", "scripts/add-test.sh"]],
} as unknown as BenchTask;
const ctx = { guardedPaths: ["/home/u/.shipwright/bench/repos"] };
const kinds = (cmds: string[]) =>
  auditCommands(cmds, task, ctx).map((f) => `${f.severity}:${f.kind}`);

test("repoSlug", () => {
  expect(repoSlug("https://github.com/Acme/Widget.git")).toBe("acme/widget");
  expect(repoSlug("/tmp/upstream")).toBeNull();
});

test("touching the harness mirror or fetching the task's own repo voids the run", () => {
  expect(kinds(["git --git-dir /home/u/.shipwright/bench/repos/x.git log --all"])).toEqual([
    "void:cache-access",
  ]);
  expect(kinds(["Read /home/u/.shipwright/bench/repos/x.git/packed-refs"])).toEqual([
    "void:cache-access",
  ]);
  expect(kinds(["git fetch https://github.com/acme/widget refs/pull/9/head"])).toEqual([
    "void:upstream-fetch",
  ]);
  expect(kinds(["gh pr view 9 --repo acme/widget"])).toEqual(["void:upstream-fetch"]);
  expect(kinds(["curl -s https://api.github.com/repos/Acme/Widget/commits"])).toEqual([
    "void:upstream-fetch",
  ]);
});

test("history probing and other network use are warnings", () => {
  expect(
    kinds([
      "git log --all --oneline",
      "git reflog",
      "git cat-file --batch-all-objects --batch-check",
    ]),
  ).toEqual(["warn:history-probe", "warn:history-probe", "warn:history-probe"]);
  expect(kinds(["git clone https://github.com/other/lib /tmp/lib", "gh api user"])).toEqual([
    "warn:network-probe",
    "warn:network-probe",
  ]);
});

test("ordinary work raises nothing", () => {
  const work = [
    "git status",
    "git log --oneline -5",
    "git diff",
    "git fetch origin",
    "curl -s localhost:3000/health",
    "bun test",
    "Read src/add.ts",
  ];
  expect(kinds(work)).toEqual([]);
});

const diff = (path: string, isNew = false) =>
  `diff --git a/${path} b/${path}\n${isNew ? "new file mode 100644\n--- /dev/null\n" : `--- a/${path}\n`}+++ b/${path}\n@@ -1 +1 @@\n-a\n+b\n`;

test("the patch audit flags oracle, test and harness edits, but not new tests", () => {
  const flags = auditPatch(
    [
      diff("src/add.py"),
      diff("tests/test_add.py"),
      diff("scripts/add-test.sh"),
      diff("tests/test_other.py"),
      diff("tests/test_new.py", true),
      diff(".github/workflows/test.yml"),
    ].join(""),
    task,
  );
  expect(flags.map((f) => `${f.kind} ${f.evidence}`).sort()).toEqual([
    "harness-edit .github/workflows/test.yml",
    "oracle-edit scripts/add-test.sh",
    "oracle-edit tests/test_add.py",
    "test-edit tests/test_other.py",
  ]);
  expect(isVoid(flags)).toBe(false);
});

test("topFlags puts voiding flags first, drops duplicates and caps the list", () => {
  const warn = { kind: "history-probe", severity: "warn", evidence: "git reflog" } as const;
  const bad = { kind: "cache-access", severity: "void", evidence: "x" } as const;
  expect(topFlags([warn, warn, bad])).toEqual([bad, warn]);
  const many = Array.from({ length: 30 }, (_, i) => ({ ...warn, evidence: `e${i}` }));
  expect(topFlags(many)).toHaveLength(20);
});
