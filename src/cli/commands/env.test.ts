import { describe, expect, test } from "bun:test";
import { RECIPE_PATH } from "../../contexts/platform";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeEnv } from "../../testing/fake-env-ports";
import { envCommand } from "./env";

const RECIPE = JSON.stringify({
  version: 1,
  setup: [["npm", "ci"]],
  cache: ["node_modules"],
  keyFiles: ["package-lock.json"],
});

function setup() {
  const f = new FakeEnv();
  f.tree(".").set("package.json", "{}").set("package-lock.json", "v1");
  f.committed.set(RECIPE_PATH, RECIPE);
  f.script = {
    "npm ci": (cwd) => {
      f.tree(cwd).set("node_modules/a", "a");
      return {};
    },
  };
  const io = captureIO();
  const run = (...args: string[]) =>
    envCommand.run(args, commandContext(io, undefined, {}, undefined, { environments: f.ports() }));
  return { f, io, run };
}

describe("shipwright env", () => {
  test("help and usage errors", async () => {
    const { io, run } = setup();
    expect(await run("--help")).toBe(0);
    expect(io.outLines.join("\n")).toContain("hydrate");
    expect(await run()).toBe(2);
    expect(await run("bogus")).toBe(2);
    expect(await run("hydrate", "--nope")).toBe(2);
    expect(await run("hydrate", "--ref", "--json")).toBe(2);
    expect(await run("hydrate", "--ref", "-x")).toBe(2);
    expect(await run("key", "extra")).toBe(2);
    expect(await run("init", "--attempts", "0")).toBe(2);
    expect(await run("init", "--effort", "huge")).toBe(2);
  });

  test("hydrate builds, then hits; --json reports the status", async () => {
    const { f, io, run } = setup();
    expect(await run("hydrate")).toBe(0);
    expect(io.outLines.at(-1)).toContain("built and cached");
    io.outLines.length = 0;
    f.tree("/wt").set("package-lock.json", "v1");
    expect(await run("hydrate", "--dir", "/wt", "--json")).toBe(0);
    expect(JSON.parse(io.outLines.join("\n")).status).toBe("hit");
  });

  test("hydrate exits 1 on setup failure; --quiet keeps success silent", async () => {
    const { f, io, run } = setup();
    expect(await run("hydrate", "--quiet")).toBe(0);
    expect(io.outLines).toEqual([]);
    f.cache.clear();
    f.script["npm ci"] = { exitCode: 1, stderr: "boom" };
    expect(await run("hydrate", "--quiet")).toBe(1);
    expect(io.errLines.join("\n")).toContain("boom");
  });

  test("key --json gives the cache directory and paths for actions/cache", async () => {
    const { io, run } = setup();
    expect(await run("key", "--json")).toBe(0);
    const out = JSON.parse(io.outLines.join("\n"));
    expect(out.key).toMatch(/^[0-9a-f]{32}$/);
    expect(out.cacheDir).toBe(`/cache/repo-1/${out.key}`);
    expect(out.paths).toEqual(["node_modules"]);
  });

  test("show prints the recipe and its origin; an invalid recipe exits 1", async () => {
    const { f, io, run } = setup();
    expect(await run("show")).toBe(0);
    expect(io.outLines.join("\n")).toContain("# committed recipe");
    f.committed.set(RECIPE_PATH, "{}");
    expect(await run("show")).toBe(1);
  });

  test("init --no-agent --no-write proves the detected recipe and writes nothing", async () => {
    const { f, io, run } = setup();
    f.committed.clear();
    expect(await run("init", "--no-agent", "--no-write")).toBe(0);
    expect(io.outLines.join("\n")).toContain("would write .shipwright/env.json");
    expect(f.tree(".").has(RECIPE_PATH)).toBe(false);
  });

  test("list and prune", async () => {
    const { io, run } = setup();
    await run("hydrate");
    io.outLines.length = 0;
    expect(await run("list")).toBe(0);
    expect(io.outLines.length).toBe(1);
    expect(await run("prune", "--keep", "0", "--dry-run")).toBe(0);
    expect(io.outLines.at(-1)).toContain("would remove");
    expect(await run("prune", "--keep", "x")).toBe(2);
  });

  test("up refuses an uncommitted recipe unless trusted", async () => {
    const { f, run } = setup();
    f.committed.clear();
    f.tree(".").set(RECIPE_PATH, RECIPE);
    expect(await run("up", "--worktree")).toBe(1);
    expect(await run("up", "--worktree", "--trust-worktree")).toBe(0);
  });
});
