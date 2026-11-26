import { describe, expect, test } from "bun:test";
import { parseLesson } from "./lesson";
import { renderLesson } from "./render-lesson";

describe("renderLesson", () => {
  test("round-trips through parseLesson, defusing quotes, commas and newlines in front matter", () => {
    const md = renderLesson({
      id: "L-0009",
      status: "proposed",
      failureClass: "execution",
      fingerprint: "execution:abc",
      appliesTo: ["src/**", "a,b"],
      keywords: ["it's"],
      source: 'run "7"\nand 8',
      hypothesis: "x # not a comment",
      title: "T",
      rule: "Do it.",
      sections: [{ heading: "Evidence", body: "e" }],
    });
    const l = parseLesson(".shipwright/lessons/L-0009.md", md);
    expect(l).toMatchObject({
      id: "L-0009",
      appliesTo: ["src/**", "a b"],
      keywords: ["its"],
      source: "run '7' and 8",
      hypothesis: "x # not a comment",
      title: "T",
      text: "Do it.",
    });
  });
});
