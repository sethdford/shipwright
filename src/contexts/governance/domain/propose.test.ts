import { describe, expect, test } from "bun:test";
import { parseLesson } from "./lesson";
import { evidenceExcerpt, nextLessonId, proposeLesson } from "./propose";

const input = {
  failureClass: "test",
  fingerprint: "fp1",
  source: "run 42",
  log: "a\n\nb\n```\nError: boom\n",
};

describe("proposeLesson", () => {
  test("drafts a proposed lesson with the next id that parses back", () => {
    const existing = [
      parseLesson(".shipwright/lessons/L-0007.md", "---\nid: L-0007\nfingerprint: other\n---\nx"),
    ];
    const p = proposeLesson(existing, input);
    expect(p).toMatchObject({ kind: "draft", id: "L-0008", path: ".shipwright/lessons/L-0008.md" });
    if (p.kind !== "draft") throw new Error("expected a draft");
    const back = parseLesson(p.path, p.markdown);
    expect(back).toMatchObject({
      id: "L-0008",
      status: "proposed",
      failureClass: "test",
      fingerprint: "fp1",
      source: "run 42",
    });
    expect(p.markdown).toContain("Error: boom");
  });

  test("a failure an existing lesson covers is a duplicate", () => {
    const existing = [
      parseLesson(".shipwright/lessons/L-0001.md", "---\nid: L-0001\nfingerprint: fp1\n---\nx"),
    ];
    expect(proposeLesson(existing, input)).toEqual({
      kind: "duplicate",
      id: "L-0001",
      path: ".shipwright/lessons/L-0001.md",
    });
  });
});

describe("helpers", () => {
  test("nextLessonId starts at L-0001 and ignores other ids", () => {
    expect(nextLessonId([])).toBe("L-0001");
    expect(nextLessonId([{ id: "custom" }, { id: "L-0009" }])).toBe("L-0010");
  });

  test("evidence keeps the last 20 non-empty lines and defuses code fences", () => {
    const log = Array.from({ length: 30 }, (_, i) => `line ${i}`).join("\n\n");
    const ex = evidenceExcerpt(`${log}\n\`\`\``);
    expect(ex.split("\n")).toHaveLength(20);
    expect(ex).not.toContain("```");
    expect(ex.startsWith("line 11")).toBe(true);
  });
});
