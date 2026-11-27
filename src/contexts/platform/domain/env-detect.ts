import type { EnvRecipe } from "./env-recipe";

type Part = Pick<EnvRecipe, "setup" | "cache" | "keyFiles" | "fingerprint" | "env">;
type Rule = (has: (f: string) => boolean) => Part | null;

const part = (p: Partial<Part>): Part => ({
  setup: p.setup ?? [],
  cache: p.cache ?? [],
  keyFiles: p.keyFiles ?? [],
  fingerprint: p.fingerprint ?? [],
  env: p.env ?? {},
});

const NODE = ["node", "--version"];

type NodeLock = { lock: string; install: string[]; tool: string[] | null };
const NODE_LOCKS: readonly NodeLock[] = [
  { lock: "bun.lock", install: ["bun", "install", "--frozen-lockfile"], tool: null },
  { lock: "bun.lockb", install: ["bun", "install", "--frozen-lockfile"], tool: null },
  {
    lock: "pnpm-lock.yaml",
    install: ["pnpm", "install", "--frozen-lockfile"],
    tool: ["pnpm", "--version"],
  },
  {
    lock: "yarn.lock",
    install: ["yarn", "install", "--frozen-lockfile"],
    tool: ["yarn", "--version"],
  },
  { lock: "package-lock.json", install: ["npm", "ci"], tool: null },
];

/** One rule per ecosystem, first match wins inside an ecosystem (lockfile before manifest). */
const node: Rule = (has) => {
  if (!has("package.json")) return null;
  const hit = NODE_LOCKS.find((l) => has(l.lock));
  if (!hit) {
    return part({
      setup: [["npm", "install"]],
      cache: ["node_modules"],
      keyFiles: ["package.json"],
      fingerprint: [NODE],
    });
  }
  // Yarn Berry (a .yarnrc.yml) spells a frozen install --immutable.
  const install =
    hit.lock === "yarn.lock" && has(".yarnrc.yml")
      ? ["yarn", "install", "--immutable"]
      : hit.install;
  const fingerprint = hit.lock.startsWith("bun.")
    ? [["bun", "--version"]]
    : [NODE, ...(hit.tool ? [hit.tool] : [])];
  return part({
    setup: [install],
    cache: ["node_modules"],
    keyFiles: [hit.lock, "package.json"],
    fingerprint,
  });
};

const PY = ["python3", "--version"];
const python: Rule = (has) => {
  if (has("uv.lock")) {
    return part({
      setup: [["uv", "sync", "--frozen"]],
      cache: [".venv"],
      keyFiles: ["uv.lock", "pyproject.toml"],
      fingerprint: [["uv", "--version"]],
    });
  }
  if (has("poetry.lock")) {
    return part({
      setup: [["poetry", "install", "--no-interaction"]],
      cache: [".venv"],
      keyFiles: ["poetry.lock", "pyproject.toml"],
      fingerprint: [PY],
      env: { POETRY_VIRTUALENVS_IN_PROJECT: "true" },
    });
  }
  const reqs = ["requirements.txt", "requirements-dev.txt"].filter(has);
  if (reqs.length === 0) return null;
  return part({
    setup: [
      ["python3", "-m", "venv", ".venv"],
      ...reqs.map((r) => [".venv/bin/pip", "install", "-r", r]),
    ],
    cache: [".venv"],
    keyFiles: reqs,
    fingerprint: [PY],
  });
};

const ruby: Rule = (has) =>
  has("Gemfile.lock")
    ? part({
        setup: [["bundle", "install"]],
        cache: ["vendor/bundle"],
        keyFiles: ["Gemfile.lock"],
        fingerprint: [["ruby", "--version"]],
        env: { BUNDLE_PATH: "vendor/bundle" },
      })
    : null;
const go: Rule = (has) =>
  has("go.mod")
    ? part({
        setup: [["go", "mod", "download"]],
        keyFiles: ["go.mod", ...(has("go.sum") ? ["go.sum"] : [])],
        fingerprint: [["go", "version"]],
      })
    : null;
const rust: Rule = (has) =>
  has("Cargo.toml")
    ? part({
        setup: [["cargo", "fetch"]],
        keyFiles: has("Cargo.lock") ? ["Cargo.lock"] : ["Cargo.toml"],
        fingerprint: [["cargo", "--version"]],
      })
    : null;
const php: Rule = (has) =>
  has("composer.lock")
    ? part({
        setup: [["composer", "install", "--no-interaction"]],
        cache: ["vendor"],
        keyFiles: ["composer.lock"],
        fingerprint: [["php", "--version"]],
      })
    : null;

const RULES: readonly Rule[] = [node, python, ruby, go, rust, php];

const uniq = <T>(xs: readonly T[], key: (x: T) => string = String): T[] => {
  const seen = new Set<string>();
  return xs.filter((x) => {
    const k = key(x);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
};

/**
 * A recipe from the files at the repository root alone, with no agent and no network: the seed
 * for `env init` and the fallback for repositories that have no recipe yet. Null when nothing
 * recognisable is there.
 */
export function detectRecipe(rootFiles: readonly string[]): EnvRecipe | null {
  const files = new Set(rootFiles);
  const parts = RULES.map((r) => r((f) => files.has(f))).filter((p): p is Part => p !== null);
  if (parts.length === 0) return null;
  const flat = <K extends keyof Part>(k: K) => parts.flatMap((p) => p[k] as unknown[]);
  return {
    version: 1,
    setup: flat("setup") as string[][],
    cache: uniq(flat("cache") as string[]),
    keyFiles: uniq(flat("keyFiles") as string[]),
    fingerprint: uniq(flat("fingerprint") as string[][], (a) => a.join("\u0000")),
    env: Object.assign({}, ...parts.map((p) => p.env)),
    services: [],
    setupTimeoutSec: 1800,
  };
}
