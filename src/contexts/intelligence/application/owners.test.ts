import { describe, expect, test } from "bun:test";
import { ownershipOf, ownersOf, parseCodeowners } from "./owners";

const RULES = parseCodeowners(
  [
    "# comment",
    "*.sh @shell",
    "/src/ @core",
    "docs @docs # inline",
    "src/adapters/**/*.ts @io",
  ].join("\n"),
);

describe("CODEOWNERS", () => {
  test("the last matching rule wins; unanchored names match at any depth", () => {
    expect(ownersOf(RULES, "scripts/sw-loop.sh")).toEqual(["@shell"]);
    expect(ownersOf(RULES, "src/main.ts")).toEqual(["@core"]);
    expect(ownersOf(RULES, "src/adapters/git/x.ts")).toEqual(["@io"]);
    expect(ownersOf(RULES, "website/docs/a.md")).toEqual(["@docs"]);
    expect(ownersOf(RULES, "README.md")).toEqual([]);
  });

  test("ownership adds the top three recent authors", () => {
    const authors = {
      "a.ts": [1, 2, 3, 4].map((n) => ({ name: `A${n}`, commits: 5 - n, last: "2026-11-01" })),
    };
    expect(ownershipOf(RULES, authors, "a.ts").authors.map((a) => a.name)).toEqual([
      "A1",
      "A2",
      "A3",
    ]);
  });
});
