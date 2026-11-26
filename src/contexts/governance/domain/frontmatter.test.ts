import { describe, expect, test } from "bun:test";
import { metaList, metaString, parseFrontmatter } from "./frontmatter";

describe("parseFrontmatter", () => {
  test("reads scalars, inline lists and dash lists, and returns the body", () => {
    const p = parseFrontmatter(
      "---\nid: L-0001\nstatus: active # approved in #12\napplies_to: [src/**, 'scripts/*.sh']\nkeywords:\n  - mktemp\n  - tmpdir\n---\n# Title\n\nBody\n",
    );
    expect(metaString(p.meta, "id")).toBe("L-0001");
    expect(metaString(p.meta, "status")).toBe("active");
    expect(metaList(p.meta, "applies_to")).toEqual(["src/**", "scripts/*.sh"]);
    expect(metaList(p.meta, "keywords")).toEqual(["mktemp", "tmpdir"]);
    expect(p.body).toBe("# Title\n\nBody\n");
  });

  test("keeps a # that is part of a word, such as an issue number", () => {
    expect(metaString(parseFrontmatter("---\nsource: run#8644\n---\n").meta, "source")).toBe(
      "run#8644",
    );
  });

  test("a file without front matter is all body", () => {
    expect(parseFrontmatter("# ADR\n\nStatus: accepted\n")).toEqual({
      meta: {},
      body: "# ADR\n\nStatus: accepted\n",
    });
  });

  test("an unterminated block is treated as body", () => {
    expect(parseFrontmatter("---\nid: x\n").meta).toEqual({});
  });

  test("an empty list stays empty and a scalar reads as a one-item list", () => {
    const p = parseFrontmatter("---\napplies_to: []\nkeywords: auth\n---\n");
    expect(metaList(p.meta, "applies_to")).toEqual([]);
    expect(metaList(p.meta, "keywords")).toEqual(["auth"]);
  });
});
