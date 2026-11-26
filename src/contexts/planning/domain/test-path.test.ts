import { describe, expect, test } from "bun:test";
import { isTestConfigPath, testPathProblem } from "./test-path";

describe("testPathProblem", () => {
  test.each([
    ["tests/auth.test.ts", null],
    ["src/auth/__tests__/login.ts", null],
    ["pkg/auth/token_test.go", null],
    ["tests/test_login.py", null],
    ["spec/models/user_spec.rb", null],
    ["src/LoginTest.java", null],
    ["scripts/sw-foo-test.sh", null],
    ["", "empty"],
    ["/etc/passwd", "absolute"],
    ["~/x.test.ts", "absolute"],
    ["../outside/a.test.ts", "traversal"],
    ["tests/../../a.test.ts", "traversal"],
    ["tests//a.test.ts", "traversal"],
    ["tests\\a.test.ts", "traversal"],
    [".github/workflows/a.test.yml", "forbidden_root"],
    [".git/hooks/pre-commit.test.js", "forbidden_root"],
    [".claude/settings.test.json", "forbidden_root"],
    ["src/auth.ts", "not_a_test"],
    ["package.json", "not_a_test"],
  ])("%s -> %p", (path, want) => {
    expect(testPathProblem(path)).toBe(want as ReturnType<typeof testPathProblem>);
  });
});

describe("isTestConfigPath", () => {
  test.each([
    ["vitest.config.ts", true],
    ["packages/a/jest.config.js", true],
    ["pytest.ini", true],
    ["conftest.py", true],
    ["bunfig.toml", true],
    ["src/config.ts", false],
  ])("%s -> %p", (path, want) => {
    expect(isTestConfigPath(path)).toBe(want);
  });
});
