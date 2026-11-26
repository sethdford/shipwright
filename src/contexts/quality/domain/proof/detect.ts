/**
 * What kind of app a repository is, and how to start it, from files at its root (ADR-0019).
 * Detection only proposes argv arrays built from fixed words and names the repository declares;
 * nothing is ever run through a shell.
 */

/** Root-level facts the adapter reads. Missing files are null or absent. */
export interface RepoFacts {
  readonly packageJson: string | null;
  /** Root file names present among MARKER_FILES. */
  readonly markers: readonly string[];
  readonly cargoToml: string | null;
  /** Directories under cmd/ that hold a main.go (Go layout), plus "." when the root does. */
  readonly goMains: readonly string[];
}

export const MARKER_FILES = [
  "bun.lock",
  "bun.lockb",
  "pnpm-lock.yaml",
  "yarn.lock",
  "package-lock.json",
  "go.mod",
  "Cargo.toml",
] as const;

export type WebFramework = "next" | "vite" | "astro" | "sveltekit" | "remix" | "nuxt" | "other";

export interface WebApp {
  readonly framework: WebFramework;
  readonly start: readonly string[];
  /** Default port the framework listens on when PORT is ignored. */
  readonly defaultPort: number;
}

export interface CliApp {
  readonly name: string;
  /** argv prefix that runs the CLI; arguments follow. */
  readonly argv: readonly string[];
}

export interface AppProfile {
  readonly web: WebApp | null;
  readonly cli: CliApp | null;
}

interface PackageJson {
  readonly name?: unknown;
  readonly scripts?: Record<string, unknown>;
  readonly bin?: unknown;
  readonly dependencies?: Record<string, unknown>;
  readonly devDependencies?: Record<string, unknown>;
}

const SAFE_NAME = /^[A-Za-z0-9@][A-Za-z0-9@._/-]{0,100}$/;
const SAFE_PATH = /^(\.\/)?[A-Za-z0-9_][A-Za-z0-9._/-]{0,200}$/;

function parsePackage(text: string | null): PackageJson | null {
  if (text === null) return null;
  try {
    const value: unknown = JSON.parse(text);
    return typeof value === "object" && value !== null ? (value as PackageJson) : null;
  } catch {
    return null;
  }
}

/** `bun run`, `pnpm run`, `yarn` or `npm run`, from the lockfile present. */
export function packageRunner(markers: readonly string[]): readonly string[] {
  if (markers.includes("bun.lock") || markers.includes("bun.lockb")) return ["bun", "run"];
  if (markers.includes("pnpm-lock.yaml")) return ["pnpm", "run"];
  if (markers.includes("yarn.lock")) return ["yarn", "run"];
  return ["npm", "run"];
}

const FRAMEWORKS: readonly [string, WebFramework, number][] = [
  ["next", "next", 3000],
  ["@sveltejs/kit", "sveltekit", 5173],
  ["@remix-run/dev", "remix", 3000],
  ["nuxt", "nuxt", 3000],
  ["astro", "astro", 4321],
  ["vite", "vite", 5173],
];

function frameworkOf(pkg: PackageJson): [WebFramework, number] {
  const deps = { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) };
  for (const [dep, framework, port] of FRAMEWORKS) if (dep in deps) return [framework, port];
  return ["other", 3000];
}

/** Flags that pin the port, per framework. PORT is also set in the environment. */
export function portArgs(framework: WebFramework, port: number): readonly string[] {
  switch (framework) {
    case "next":
      return ["-p", String(port)];
    case "vite":
    case "sveltekit":
    case "astro":
      return ["--port", String(port), "--host", "127.0.0.1"];
    case "nuxt":
      return ["--port", String(port)];
    default:
      return [];
  }
}

function detectWeb(pkg: PackageJson, markers: readonly string[]): WebApp | null {
  const scripts = pkg.scripts ?? {};
  const script = ["dev", "start", "preview", "serve"].find((s) => typeof scripts[s] === "string");
  if (script === undefined) return null;
  const [framework, defaultPort] = frameworkOf(pkg);
  if (framework === "other" && script !== "dev" && script !== "start") return null;
  return { framework, start: [...packageRunner(markers), script], defaultPort };
}

function binEntry(pkg: PackageJson): [string, string] | null {
  if (typeof pkg.bin === "string" && typeof pkg.name === "string")
    return [pkg.name.replace(/^@[^/]+\//, ""), pkg.bin];
  if (typeof pkg.bin !== "object" || pkg.bin === null) return null;
  const entries = Object.entries(pkg.bin as Record<string, unknown>);
  const first = entries.find(([, v]) => typeof v === "string");
  return first ? [first[0], first[1] as string] : null;
}

function detectNodeCli(pkg: PackageJson, markers: readonly string[]): CliApp | null {
  const entry = binEntry(pkg);
  if (entry === null || !SAFE_NAME.test(entry[0]) || !SAFE_PATH.test(entry[1])) return null;
  const node = markers.includes("bun.lock") || markers.includes("bun.lockb") ? "bun" : "node";
  return { name: entry[0], argv: [node, entry[1]] };
}

function detectCargoCli(cargo: string | null): CliApp | null {
  if (cargo === null || (/^\[lib\]/m.test(cargo) && !/^\[\[bin\]\]/m.test(cargo))) return null;
  const name = /^\s*name\s*=\s*"([A-Za-z0-9_-]{1,64})"/m.exec(cargo)?.[1];
  return name ? { name, argv: ["cargo", "run", "--quiet", "--"] } : null;
}

function detectGoCli(goMains: readonly string[]): CliApp | null {
  const dir = goMains.find((d) => d === ".") ?? goMains.find((d) => SAFE_PATH.test(d));
  if (dir === undefined) return null;
  const target = dir === "." ? "." : `./cmd/${dir}`;
  return { name: dir === "." ? "main" : dir, argv: ["go", "run", target] };
}

/** The web app and CLI a repository offers, if any. A repository can be both. */
export function detectApp(facts: RepoFacts): AppProfile {
  const pkg = parsePackage(facts.packageJson);
  const web = pkg ? detectWeb(pkg, facts.markers) : null;
  const cli =
    (pkg ? detectNodeCli(pkg, facts.markers) : null) ??
    detectCargoCli(facts.cargoToml) ??
    detectGoCli(facts.goMains);
  return { web, cli };
}
