import { describe, expect, test } from "bun:test";
import { parseManifest } from "./task";

const SHA = "a".repeat(40);
const holdout = {
  id: "pr-1",
  suite: "holdout",
  repo: "https://github.com/o/r",
  baseCommit: SHA,
  problem: "fix it",
  testPatch: "diff --git a/t.test.ts b/t.test.ts\n",
  testCommands: [["bun", "test", "./t.test.ts"]],
};

describe("parseManifest", () => {
  test("accepts holdout and SWE-bench tasks with defaults", () => {
    const swe = {
      id: "django__django-1",
      suite: "swe-bench-verified",
      repo: "https://github.com/django/django",
      baseCommit: SHA,
      problem: "p",
    };
    const r = parseManifest({ name: "m", tasks: [holdout, swe] });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.tasks[1]?.setup).toEqual([]);
    expect(r.value.tasks[1]?.testPatch).toBeNull();
    expect(r.value.tasks[0]?.goldCommit).toBeNull();
  });

  test("a holdout task without hidden tests is rejected", () => {
    const r = parseManifest({ name: "m", tasks: [{ ...holdout, testPatch: undefined }] });
    expect(r.ok ? "" : r.reason).toContain("needs testPatch and testCommands");
  });

  test.each([
    [{ baseCommit: "abc" }, "baseCommit"],
    [{ id: "../x" }, "id must match"],
    [{ suite: "other" }, "suite must be"],
    [{ repo: "git@github.com:o/r" }, "repo must be"],
    [{ testCommands: ["bun test"] }, "argv lists"],
    [{ setup: [[]] }, "setup must be"],
    [{ goldCommit: "nope" }, "goldCommit"],
  ])("rejects %p", (patch, reason) => {
    const r = parseManifest({ name: "m", tasks: [{ ...holdout, ...patch }] });
    expect(r.ok ? "" : r.reason).toContain(reason);
  });

  test("duplicate ids and empty manifests fail closed", () => {
    expect(parseManifest({ name: "m", tasks: [holdout, holdout] }).ok).toBe(false);
    expect(parseManifest({ name: "m", tasks: [] }).ok).toBe(false);
    expect(parseManifest({ tasks: [holdout] }).ok).toBe(false);
  });
});
