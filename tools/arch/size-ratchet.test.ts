import { expect, test } from "bun:test";
import { checkBudgets, measure, nextBaseline } from "./size-ratchet";

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
  expect(checkBudgets([m], { files: {}, functions: { "x.ts#big": 47 } })).toEqual([]);
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

const ids = (text: string) => measure("z.ts", text).functions.map((f) => f.id);

test("accessors, object-literal methods, class expressions and computed names", () => {
  const text = [
    `class C { get v() ${body(1)} set v(x: number) ${body(1)} [Symbol.iterator]() ${body(1)} }`,
    `const h1 = { run() ${body(1)}, go: () => ${body(1)} };`,
    `const K = class { m() ${body(1)} };`,
  ].join("\n");
  expect(ids(text)).toEqual([
    "z.ts#C.get:v",
    "z.ts#C.set:v",
    "z.ts#C.[Symbol.iterator]",
    "z.ts#h1.run",
    "z.ts#h1.go",
    "z.ts#K.m",
  ]);
});

test("callbacks are named by callee and argument index", () => {
  const text = `function f() { setTimeout(() => ${body(1)}, 1); xs.map((x) => ${body(1)}); }`;
  expect(ids(text)).toEqual(["z.ts#f", "z.ts#f.<setTimeout-arg0>", "z.ts#f.<map-arg0>"]);
});

test("inserting a small callback above a large one keeps the large one's id", () => {
  const large = `setTimeout(() => ${body(50)}, 1);`;
  const before = measure("z.ts", `function f() { ${large} }`).functions;
  const after = measure("z.ts", `function f() { xs.map((x) => x); ${large} }`).functions;
  const pick = (fs: typeof before) => fs.find((f) => f.lines > 40);
  expect(pick(after)).toEqual(pick(before));
});

test("stale and loose baseline entries fail", () => {
  const m = measure("x.ts", longFn);
  expect(checkBudgets([m], { files: {}, functions: { "x.ts#big": 47, "x.ts#gone": 60 } })).toEqual([
    "remove stale baseline entry x.ts#gone",
  ]);
  expect(checkBudgets([m], { files: {}, functions: { "x.ts#big": 60 } })).toEqual([
    "tighten baseline x.ts#big to 47",
  ]);
  expect(checkBudgets([m], { files: { "gone.ts": 400 }, functions: { "x.ts#big": 47 } })).toEqual([
    "remove stale baseline entry gone.ts",
  ]);
});

test("write mode: absent baseline records everything over budget", () => {
  const m = measure("x.ts", longFn);
  expect(nextBaseline([m], undefined)).toEqual({
    baseline: { files: {}, functions: { "x.ts#big": 47 } },
  });
});

test("write mode refuses new violations and raised values, but tightens and prunes", () => {
  const m = measure("x.ts", longFn);
  expect(nextBaseline([m], { files: {}, functions: {} })).toEqual({
    errors: ["refusing to baseline new violation x.ts#big (47 lines)"],
  });
  expect(nextBaseline([m], { files: {}, functions: { "x.ts#big": 45 } })).toEqual({
    errors: ["refusing to raise baseline x.ts#big from 45 to 47"],
  });
  expect(nextBaseline([m], { files: {}, functions: { "x.ts#big": 60, "x.ts#gone": 99 } })).toEqual({
    baseline: { files: {}, functions: { "x.ts#big": 47 } },
  });
});
