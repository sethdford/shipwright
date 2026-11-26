import { describe, expect, test } from "bun:test";
import { BRIEF_LIMITS, buildChecklist, renderBrief, renderChecklist } from "./brief";
import { parseDoc } from "./doc";
import { parseLesson, selectLessons } from "./lesson";

const adr = parseDoc(
  "adr",
  "docs/adr/0001-bun.md",
  "# 0001. Bun\n\nStatus: accepted\n\n## Decision\nUse Bun.\n",
);
const old = parseDoc(
  "adr",
  "docs/adr/0002-node.md",
  "# 0002. Node\n\nStatus: superseded\n\n## Decision\nUse Node.\n",
);
const policy = parseDoc(
  "policy",
  "docs/policies/ci.md",
  "---\nid: POL-CI\napplies_to: [.github/**]\n---\n# CI\n\nPin actions by SHA.\n",
);
const wide = parseDoc("standard", "docs/standards/style.md", "# Style\n\nPlain words.\n");
const lesson = parseLesson(
  ".shipwright/lessons/L-0001.md",
  "---\nid: L-0001\nstatus: active\nhypothesis: fewer reruns\n---\nCreate the temp dir first.\n",
);

describe("renderBrief", () => {
  test("lists policies, standards, ADRs in force, then lessons; leaves out superseded ADRs", () => {
    const text = renderBrief(
      [adr, old, policy, wide],
      selectLessons([lesson], { text: "", paths: [] }),
    );
    expect(text.indexOf("## Policies")).toBeLessThan(text.indexOf("## Standards"));
    expect(text.indexOf("## Standards")).toBeLessThan(text.indexOf("## Architecture decisions"));
    expect(text).toContain("### ADR-0001: Bun");
    expect(text).not.toContain("Use Node.");
    expect(text).toContain("- [L-0001] Create the temp dir first. Why: fewer reruns");
  });

  test("with known paths, a scoped document that matches none is left out", () => {
    expect(renderBrief([policy], [], ["src/a.ts"])).toBe("");
    expect(renderBrief([policy], [], [".github/workflows/x.yml"])).toContain("POL-CI");
  });

  test("is empty when there is nothing to say", () => {
    expect(renderBrief([old], [])).toBe("");
  });

  test("is cut at the total limit with a marker", () => {
    const big = Array.from({ length: 60 }, (_, i) =>
      parseDoc("policy", `docs/policies/p${i}.md`, `# P${i}\n\n${"x".repeat(2000)}\n`),
    );
    const text = renderBrief(big, []);
    expect(text.length).toBeLessThanOrEqual(BRIEF_LIMITS.total);
    expect(text).toContain("[governance brief truncated");
  });
});

describe("buildChecklist", () => {
  test("scoped matches first, then repository-wide policies and standards; never unscoped ADRs", () => {
    const items = buildChecklist([adr, policy, wide], [".github/workflows/ci.yml"]);
    expect(items.map((i) => [i.id, i.reason])).toEqual([
      ["POL-CI", "scoped"],
      ["style", "repository-wide"],
    ]);
    expect(renderChecklist(items)).toContain("- [ ] POL-CI: CI (docs/policies/ci.md)");
  });

  test("renders nothing for no items", () => {
    expect(renderChecklist([])).toBe("");
  });
});
