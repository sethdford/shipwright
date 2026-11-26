import { expect, test } from "bun:test";
import { choose, passHatK } from "./pass-k";

test("choose matches known values and rejects impossible picks", () => {
  expect(choose(5, 2)).toBe(10);
  expect(choose(20, 10)).toBe(184_756);
  expect(choose(3, 0)).toBe(1);
  expect(choose(2, 3)).toBe(0);
  expect(choose(-1, 0)).toBe(0);
});

test("pass^3 over exactly three runs is all-or-nothing", () => {
  expect(passHatK(3, 3, 3)).toBe(1);
  expect(passHatK(3, 2, 3)).toBe(0);
});

test("pass^k uses every run when there are more runs than k", () => {
  expect(passHatK(5, 4, 3)).toBeCloseTo(4 / 10);
  expect(passHatK(4, 4, 1)).toBe(1);
});

test("too few runs or a nonsense count gives no estimate", () => {
  expect(passHatK(2, 2, 3)).toBeNull();
  expect(passHatK(3, 4, 3)).toBeNull();
  expect(passHatK(3, 1, 0)).toBeNull();
});
