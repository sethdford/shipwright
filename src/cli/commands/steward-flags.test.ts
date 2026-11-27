import { expect, test } from "bun:test";
import { botList, intIn, jobIds, parseStewardFlags, prNumber } from "./steward-flags";

test("flags: allowed options with values; text by default", () => {
  expect(parseStewardFlags(["--pr", "5"], ["--pr", "--format"])).toEqual({
    values: { "--pr": "5" },
    json: false,
  });
  expect(parseStewardFlags(["--format", "json"], ["--format"])).toEqual({
    values: { "--format": "json" },
    json: true,
  });
  expect(parseStewardFlags(["--x", "1"], ["--pr"])).toBe("unknown option: --x");
  expect(parseStewardFlags(["--pr"], ["--pr"])).toBe("--pr needs a value");
  expect(parseStewardFlags(["--pr", "--format"], ["--pr", "--format"])).toBe("--pr needs a value");
  expect(parseStewardFlags(["5"], ["--pr"])).toBe("unknown option: 5");
  expect(parseStewardFlags(["--format", "xml"], ["--format"])).toBe(
    "--format must be text or json",
  );
});

test("pr numbers", () => {
  expect(prNumber("42")).toBe(42);
  for (const bad of ["0", "-1", "01", "4.2", "1e3", "1234567890", "", " 5"]) {
    expect(typeof prNumber(bad)).toBe("string");
  }
  expect(prNumber(undefined)).toBe("--pr is required");
});

test("bounded integers", () => {
  expect(intIn("--n", undefined, 3, 20)).toBe(3);
  expect(intIn("--n", "0", 3, 20)).toBe(0);
  expect(intIn("--n", "20", 3, 20)).toBe(20);
  for (const bad of ["21", "-1", "x", "1.5", "1000"])
    expect(typeof intIn("--n", bad, 3, 20)).toBe("string");
});

test("job ids", () => {
  expect(jobIds("1, 2,3")).toEqual([1, 2, 3]);
  for (const bad of [undefined, "", " ", "1,,2", "0", "a", "1;2", "-5"]) {
    expect(typeof jobIds(bad)).toBe("string");
  }
});

test("bot logins are lowercased; empty means the defaults", () => {
  expect(botList(undefined, ["a[bot]"])).toEqual(new Set(["a[bot]"]));
  expect(botList("Claude[bot], x-y[bot],", [])).toEqual(new Set(["claude[bot]", "x-y[bot]"]));
  expect(botList("", ["a[bot]"])).toEqual(new Set(["a[bot]"]));
  expect(botList("  ", ["a[bot]"])).toEqual(new Set(["a[bot]"]));
  // Bot-typed logins without the suffix (Copilot) are accepted too.
  expect(botList("Copilot", [])).toEqual(new Set(["copilot"]));
  for (const bad of ["a[bot] b[bot]", "../[bot]", "a[bot]x", "a_b", "x[bot][bot]"]) {
    expect(typeof botList(bad, [])).toBe("string");
  }
});
