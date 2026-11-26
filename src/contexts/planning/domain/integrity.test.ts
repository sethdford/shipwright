import { describe, expect, test } from "bun:test";
import { blocks, checkIntegrity, parseDiff } from "./integrity";

const diff = (path: string, body: string, header = "") =>
  `diff --git a/${path} b/${path}\n${header}--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n${body}\n`;

const rules = (text: string, locked: string[] = []) =>
  checkIntegrity(parseDiff(text), locked).map((v) => `${v.rule}:${v.severity}`);

describe("parseDiff", () => {
  test("reads status, renames and changed lines", () => {
    const text = `${diff("a.ts", "-x\n+y", "")}diff --git a/old.test.ts b/new.ts\nsimilarity index 90%\nrename from old.test.ts\nrename to new.ts\n`;
    const [a, b] = parseDiff(text);
    expect(a).toMatchObject({ path: "a.ts", status: "modified", added: ["y"], removed: ["x"] });
    expect(b).toMatchObject({ path: "new.ts", from: "old.test.ts", status: "renamed" });
  });
});

describe("checkIntegrity", () => {
  test("editing a locked acceptance test blocks", () => {
    expect(
      rules(diff("tests/login.test.ts", "-  expect(a).toBe(1)\n+  expect(a).toBe(a)"), [
        "tests/login.test.ts",
      ]),
    ).toContain("acceptance_test_changed:block");
  });

  test("deleting any test, or renaming it out of the test paths, blocks", () => {
    expect(rules(diff("tests/old.test.ts", "-x", "deleted file mode 100644\n"))).toContain(
      "test_deleted:block",
    );
    expect(
      rules("diff --git a/a.test.ts b/a.ts\nrename from a.test.ts\nrename to a.ts\n"),
    ).toContain("test_deleted:block");
  });

  test.each([
    ["it.skip(", "+it.skip('x', () => {})"],
    ["test.only(", "+test.only('x', () => {})"],
    ["xit(", "+xit('x', () => {})"],
    ["pytest skip", "+@pytest.mark.skip(reason='later')"],
    ["go skip", '+\tt.Skip("flaky")'],
    ["rust ignore", "+#[ignore]"],
  ])("adding %s to a test blocks", (_n, body) => {
    expect(rules(diff("tests/a.test.ts", body))).toContain("test_disabled:block");
  });

  test("moving a skip marker without adding one is fine", () => {
    expect(rules(diff("tests/a.test.ts", "-it.skip('x')\n+it.skip('y')"))).toEqual([]);
  });

  test("dropping assertions from an existing test blocks; rewriting them is fine", () => {
    expect(
      rules(
        diff(
          "tests/a.test.ts",
          "-  expect(x).toBe(1);\n-  expect(y).toBe(2);\n+  expect(x).toBe(1);",
        ),
      ),
    ).toContain("assertions_removed:block");
    expect(
      rules(diff("tests/a.test.ts", "-  expect(x).toBe(1);\n+  expect(x).toEqual(1);")),
    ).toEqual([]);
  });

  test("test config: narrowing collection blocks, other edits warn", () => {
    expect(rules(diff("vitest.config.ts", "+    exclude: ['tests/login.test.ts'],"))).toContain(
      "test_collection_narrowed:block",
    );
    expect(rules(diff("vitest.config.ts", "+    globals: true,"))).toEqual([
      "test_config_changed:warn",
    ]);
    expect(
      rules(diff("package.json", '-    "test": "bun test",\n+    "test": "bun test src/other",')),
    ).toEqual(["test_config_changed:warn"]);
  });

  test("new tests and source changes are clean", () => {
    const v = checkIntegrity(
      parseDiff(
        `${diff("src/a.ts", "+x")}${diff("tests/b.test.ts", "+expect(1).toBe(1)", "new file mode 100644\n")}`,
      ),
      [],
    );
    expect(v).toEqual([]);
    expect(blocks(v)).toBe(false);
  });
});
