import { describe, expect, test } from "bun:test";
import { anyGlobMatches, globMatch } from "./glob";

describe("globMatch", () => {
  test.each([
    ["src/**", "src/a/b.ts", true],
    ["src/**/*.ts", "src/x.ts", true],
    ["src/**/*.ts", "src/a/b/x.ts", true],
    ["src/*.ts", "src/a/x.ts", false],
    ["scripts/", "scripts/lib/a.sh", true],
    ["*.md", "docs/a.md", false],
    ["**/*.md", "docs/a.md", true],
    ["a?c.ts", "abc.ts", true],
    ["docs/adr/0001.md", "docs/adr/0001.md", true],
    ["docs/adr/0001.md", "docs/adr/0001xmd", false],
  ])("%s vs %s is %p", (glob, path, want) => {
    expect(globMatch(glob, path)).toBe(want);
  });

  test("anyGlobMatches is false for no paths", () => {
    expect(anyGlobMatches(["**"], [])).toBe(false);
  });
});
