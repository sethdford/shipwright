import { describe, expect, test } from "bun:test";
import { detectRecipe } from "./env-detect";
import { isCacheKey, keyMaterial } from "./env-key";
import { canonicalJson, parseRecipe, relPathProblem } from "./env-recipe";

const minimal = {
  version: 1,
  setup: [["npm", "ci"]],
  cache: ["node_modules"],
  keyFiles: ["package-lock.json"],
};

describe("parseRecipe", () => {
  test("fills defaults for a minimal recipe", () => {
    const r = parseRecipe(JSON.stringify(minimal));
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.recipe.services).toEqual([]);
      expect(r.recipe.fingerprint).toEqual([]);
      expect(r.recipe.setupTimeoutSec).toBe(1800);
    }
  });

  test("lists every problem at once", () => {
    const r = parseRecipe(
      JSON.stringify({ version: 1, setup: ["npm ci"], cache: ["../x"], extra: 1 }),
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems.length).toBeGreaterThanOrEqual(3);
  });

  test("refuses shell strings: a command must be an argv array", () => {
    expect(parseRecipe(JSON.stringify({ ...minimal, setup: ["npm ci && npm test"] })).ok).toBe(
      false,
    );
  });

  test("refuses credentials and reserved variables in env", () => {
    for (const name of [
      "GH_TOKEN",
      "NPM_TOKEN",
      "AWS_SECRET_ACCESS_KEY",
      "DB_PASSWORD",
      "PATH",
      "LD_PRELOAD",
      "DYLD_INSERT_LIBRARIES",
      "SW_TEST_SANDBOX_WRITABLE",
      "SW_ENV_NO_JAIL",
      "_TEST_SANDBOX_LOADED",
      "GIT_CONFIG_COUNT",
      "NODE_OPTIONS",
      "BASH_FUNC_X",
      "lower",
    ]) {
      expect(parseRecipe(JSON.stringify({ ...minimal, env: { [name]: "x" } })).ok).toBe(false);
    }
    expect(parseRecipe(JSON.stringify({ ...minimal, env: { NODE_ENV: "test" } })).ok).toBe(true);
  });

  test("refuses duplicate service names and bad JSON", () => {
    const svc = { name: "db", start: ["a"], ready: ["b"] };
    expect(parseRecipe(JSON.stringify({ ...minimal, services: [svc, svc] })).ok).toBe(false);
    expect(parseRecipe("{nope").ok).toBe(false);
  });
});

describe("relPathProblem", () => {
  test.each([
    ["/etc"],
    ["../up"],
    ["a/../b"],
    [".git/hooks"],
    ["."],
    ["a//b"],
    ["C:x"],
    ["a\\b"],
    [""],
  ])("refuses %p", (p) => {
    expect(relPathProblem(p)).not.toBeNull();
  });
  test.each([["node_modules"], [".venv"], ["vendor/bundle"], ["packages/a/node_modules"]])(
    "allows %p",
    (p) => {
      expect(relPathProblem(p)).toBeNull();
    },
  );
});

describe("cache key material", () => {
  const recipe = (() => {
    const r = parseRecipe(JSON.stringify(minimal));
    if (!r.ok) throw new Error("fixture");
    return r.recipe;
  })();
  const base = {
    recipe,
    keyFiles: { "package-lock.json": "abc" },
    fingerprints: ["v20"],
    os: "darwin",
    arch: "arm64",
  };

  test("is independent of key order and of smoke, test and services", () => {
    const edited = { ...recipe, smoke: ["npm", "test"], test: ["npm", "test"], services: [] };
    expect(keyMaterial({ ...base, recipe: edited })).toBe(keyMaterial(base));
    expect(canonicalJson({ b: 1, a: [2, { d: 1, c: 2 }] })).toBe('{"a":[2,{"c":2,"d":1}],"b":1}');
  });

  test("changes with a lockfile, the toolchain, the platform or the setup", () => {
    const k = keyMaterial(base);
    expect(keyMaterial({ ...base, keyFiles: { "package-lock.json": "abd" } })).not.toBe(k);
    expect(keyMaterial({ ...base, fingerprints: ["v22"] })).not.toBe(k);
    expect(keyMaterial({ ...base, os: "linux" })).not.toBe(k);
    expect(keyMaterial({ ...base, recipe: { ...recipe, setup: [["npm", "install"]] } })).not.toBe(
      k,
    );
  });

  test("isCacheKey accepts 32 lowercase hex only", () => {
    expect(isCacheKey("a".repeat(32))).toBe(true);
    expect(isCacheKey("A".repeat(32))).toBe(false);
    expect(isCacheKey("../../etc")).toBe(false);
  });
});

describe("detectRecipe", () => {
  test("nothing recognisable gives null", () => {
    expect(detectRecipe(["README.md", "src"])).toBeNull();
  });

  test("lockfile picks the package manager", () => {
    expect(detectRecipe(["package.json", "package-lock.json"])?.setup).toEqual([["npm", "ci"]]);
    expect(detectRecipe(["package.json", "pnpm-lock.yaml"])?.setup).toEqual([
      ["pnpm", "install", "--frozen-lockfile"],
    ]);
    expect(detectRecipe(["package.json", "bun.lock"])?.fingerprint).toEqual([["bun", "--version"]]);
    expect(detectRecipe(["package.json", "yarn.lock", ".yarnrc.yml"])?.setup).toEqual([
      ["yarn", "install", "--immutable"],
    ]);
    expect(detectRecipe(["package.json"])?.keyFiles).toEqual(["package.json"]);
  });

  test("python venv keeps dependencies inside the repository", () => {
    const r = detectRecipe(["requirements.txt", "requirements-dev.txt"]);
    expect(r?.cache).toEqual([".venv"]);
    expect(r?.setup.length).toBe(3);
    expect(detectRecipe(["poetry.lock", "pyproject.toml"])?.env).toEqual({
      POETRY_VIRTUALENVS_IN_PROJECT: "true",
    });
  });

  test("ecosystems combine and every detected recipe parses", () => {
    const r = detectRecipe([
      "package.json",
      "package-lock.json",
      "go.mod",
      "go.sum",
      "Gemfile.lock",
      "Cargo.toml",
      "composer.lock",
      "uv.lock",
    ]);
    expect(r?.setup.map((a) => a[0])).toEqual(["npm", "uv", "bundle", "go", "cargo", "composer"]);
    expect(parseRecipe(JSON.stringify(r)).ok).toBe(true);
  });
});
