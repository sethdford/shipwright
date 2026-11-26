import { describe, expect, test } from "bun:test";
import { docKindOf, inForce, parseDoc, sectionText } from "./doc";

const ADR = `# 0007. Safety controls gate every dispatch

Status: accepted · Date: 2026-10-14

## Context
Why.

## Decision
Gates fail closed.

### Detail
Kept.

## Consequences
Later.
`;

describe("docKindOf", () => {
  test.each([
    ["docs/adr/0007-safety.md", "adr"],
    ["docs/decisions/0001-x.md", "adr"],
    ["docs/policies/merge.md", "policy"],
    [".shipwright/standards/api.md", "standard"],
    [".shipwright/lessons/L-0001.md", "lesson"],
    ["docs/adr/README.md", null],
    ["docs/adr/template.md", null],
    ["docs/adr/0007.txt", null],
    ["src/adr/0001.md", null],
  ])("%s is %p", (path, kind) => {
    expect(docKindOf(path)).toBe(kind as ReturnType<typeof docKindOf>);
  });
});

describe("parseDoc", () => {
  test("an ADR gets its id from the file name, its title without the number and its Decision section", () => {
    const d = parseDoc("adr", "docs/adr/0007-safety.md", ADR);
    expect(d).toMatchObject({
      id: "ADR-0007",
      title: "Safety controls gate every dispatch",
      status: "accepted",
    });
    expect(d.text).toBe("Gates fail closed.\n\n### Detail\nKept.");
  });

  test("front matter wins over the body", () => {
    const d = parseDoc(
      "policy",
      "docs/policies/merge.md",
      "---\nid: POL-MERGE\ntitle: Merge policy\nstatus: active\napplies_to: [.github/**]\n---\nHumans merge.\n",
    );
    expect(d).toMatchObject({
      id: "POL-MERGE",
      title: "Merge policy",
      appliesTo: [".github/**"],
      text: "Humans merge.",
    });
  });

  test("a MADR '## Status' section is read", () => {
    expect(
      parseDoc("adr", "adr/adr-12-x.md", "# X\n\n## Status\n\nSuperseded by 13\n").status,
    ).toBe("superseded");
    expect(parseDoc("adr", "adr/adr-12-x.md", "# X\n").id).toBe("ADR-0012");
  });

  test("proposed, superseded and retired documents are not in force; unknown is", () => {
    expect(inForce({ status: "proposed" })).toBe(false);
    expect(inForce({ status: "superseded" })).toBe(false);
    expect(inForce({ status: "retired" })).toBe(false);
    expect(inForce({ status: "unknown" })).toBe(true);
  });

  test("sectionText is undefined for a missing section", () => {
    expect(sectionText("# x\n", "Decision")).toBeUndefined();
  });
});
