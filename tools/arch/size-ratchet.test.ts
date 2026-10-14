import { expect, test } from "bun:test";
import { checkBudgets, measure } from "./size-ratchet";

const longFn = `export function big() {\n${"  const a = 1;\n".repeat(45)}}\n`;

test("measures file lines and function lines", () => {
  const m = measure("x.ts", longFn);
  expect(m.fileLines).toBe(47);
  expect(m.functions).toEqual([{ id: "x.ts#big", lines: 47 }]);
});

test("new violations fail; baselined ones may shrink but not grow", () => {
  const m = measure("x.ts", longFn);
  expect(checkBudgets([m], { files: {}, functions: {} })).toEqual([
    "x.ts#big is 47 lines (limit 40). Split it into smaller functions.",
  ]);
  expect(checkBudgets([m], { files: {}, functions: { "x.ts#big": 50 } })).toEqual([]);
  expect(checkBudgets([m], { files: {}, functions: { "x.ts#big": 46 } })).toEqual([
    "x.ts#big grew to 47 lines (baseline 46). Baselined code may only shrink.",
  ]);
});

const body = (n: number) => `{\n${"  const a = 1;\n".repeat(n)}}`;

test("function ids are unique and deterministic for repeated names", () => {
  const text = [
    `class A { run() ${body(2)} }`,
    `class B { run() ${body(2)} run() ${body(2)} }`,
    `const f = () => ${body(2)};`,
    `function g() { const h = () => ${body(2)}; return h; }`,
    `export default function () ${body(2)}`,
    `foo(() => ${body(2)});`,
    `foo(() => ${body(2)});`,
    `function dup() ${body(2)}`,
    `function dup() ${body(2)}`,
  ].join("\n");
  const ids = measure("y.ts", text).functions.map((f) => f.id);
  expect(new Set(ids).size).toBe(ids.length);
  expect(ids).toEqual(
    expect.arrayContaining([
      "y.ts#A.run",
      "y.ts#B.run",
      "y.ts#B.run#2",
      "y.ts#f",
      "y.ts#g.h",
      "y.ts#g",
      "y.ts#dup",
      "y.ts#dup#2",
    ]),
  );
  expect(measure("y.ts", text).functions.map((f) => f.id)).toEqual(ids);
});
