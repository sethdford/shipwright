import { expect, test } from "bun:test";
import { difficultyPrior, tierOfScore, tierUp } from "./difficulty";
import { extractFeatures } from "./features";

const prior = (title: string, body = "", labels: string[] = []) =>
  difficultyPrior(extractFeatures({ title, body, labels }));

test("score bands map to tiers", () => {
  expect([0, 24, 25, 45, 65, 85, 100].map(tierOfScore)).toEqual([
    "trivial",
    "trivial",
    "small",
    "medium",
    "large",
    "xl",
    "xl",
  ]);
});

test("tierUp stops at xl", () => {
  expect(tierUp("medium")).toBe("large");
  expect(tierUp("xl")).toBe("xl");
});

test("a docs typo is trivial and a cross-cutting migration is large or more", () => {
  expect(prior("docs: fix typo in README").tier).toBe("trivial");
  const body = `${"word ".repeat(450)}\nMigrate every command; race condition; breaking change.`;
  const hard = prior("refactor: migrate storage", body);
  expect(["large", "xl"]).toContain(hard.tier);
  expect(hard.reasons.some((r) => r.includes("hard:"))).toBe(true);
});

test("a size label a person set wins over the score", () => {
  const p = prior("docs: typo", "", ["size/L"]);
  expect(p.tier).toBe("large");
  expect(p.reasons.at(-1)).toContain("size label large");
});
