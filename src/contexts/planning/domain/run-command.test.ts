import { describe, expect, test } from "bun:test";
import { chooseTemplate, deriveTemplate, renderRun, templateProblem } from "./run-command";

describe("deriveTemplate", () => {
  test.each([
    ["bun test", ["bun", "test", "{file}"]],
    ["bun test ./src ./tools", ["bun", "test", "{file}"]],
    ["bun test --timeout 5000 ./src", ["bun", "test", "--timeout", "5000", "{file}"]],
    ["npx vitest run", ["npx", "vitest", "run", "{file}"]],
    ["pytest -q", ["pytest", "-q", "{file}"]],
    ["python -m pytest", ["python", "-m", "pytest", "{file}"]],
    ["npm test", ["npm", "test", "--", "{file}"]],
    ["go test ./...", ["go", "test", "-count=1", "{dir}"]],
    ["cargo test", ["cargo", "test", "--test", "{stem}"]],
    ["make test", null],
    ["bun run test", null],
    ["npm test && rm -rf /", null],
    ["pytest $FLAGS", null],
  ])("%s", (cmd, want) => {
    expect(deriveTemplate(cmd)).toEqual(want);
  });
});

describe("renderRun", () => {
  test("fills file, dir and stem", () => {
    expect(renderRun(["x", "{file}", "{dir}", "{stem}"], "pkg/auth/token_test.go")).toEqual([
      "x",
      "pkg/auth/token_test.go",
      "./pkg/auth",
      "token_test",
    ]);
  });
});

describe("templateProblem and chooseTemplate", () => {
  test("a proposed command must be a known runner naming the file, with no inline code", () => {
    expect(templateProblem(["bun", "test", "{file}"])).toBeNull();
    expect(templateProblem(["curl", "{file}"])).toContain("not a known test runner");
    expect(templateProblem(["bun", "test"])).toContain("never names");
    expect(templateProblem(["node", "-e", "{file}"])).toContain("inline code");
  });

  test("configured beats derived beats proposed", () => {
    const proposed = ["npx", "jest", "{file}"];
    expect(
      chooseTemplate({ configured: ["pytest", "{file}"], testCmd: "bun test", proposed }),
    ).toMatchObject({ source: "configured" });
    expect(chooseTemplate({ testCmd: "bun test", proposed })).toMatchObject({ source: "derived" });
    expect(chooseTemplate({ testCmd: "make test", proposed })).toMatchObject({
      source: "proposed",
    });
    expect(chooseTemplate({ testCmd: "make test" }).ok).toBe(false);
  });
});
