// Dashboard bundle budget (spec section 7). Builds dashboard/src/main.ts into a
// temp outdir, gzips the JS and CSS, and fails when either exceeds budget.json.
// Also runs the no-CDN scan over the sources and the built output.
//
// Usage: bun tools/web/budget.ts [--outdir <dir>]
//   --outdir  build here instead of a fresh temp dir. Must be outside the repo.
//   Prints the measured sizes, so run it to record a new baseline.

import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve, sep } from "node:path";
import { gzipSync } from "node:zlib";
import { scanDirs } from "./no-cdn";

export const REPO_ROOT = resolve(import.meta.dir, "..", "..");
const BUDGET_PATH = join(REPO_ROOT, "tools/web/budget.json");
const ENTRY = join(REPO_ROOT, "dashboard/src/main.ts");
// Every stylesheet the dashboard ships. tokens.css and fonts.css are not linked yet (T2).
const DASHBOARD_CSS = [
  join(REPO_ROOT, "dashboard/public/styles.css"),
  join(REPO_ROOT, "dashboard/public/tokens.css"),
  join(REPO_ROOT, "dashboard/public/fonts/fonts.css"),
];

export interface BudgetFile {
  js: { maxGzipBytes: number };
  css: { maxGzipBytes: number };
}

export interface Measured {
  name: string;
  gzipBytes: number;
}

export function gzipSize(bytes: Uint8Array): number {
  return gzipSync(bytes, { level: 9 }).length;
}

export function loadBudget(path: string = BUDGET_PATH): BudgetFile {
  return JSON.parse(readFileSync(path, "utf8")) as BudgetFile;
}

/** Returns one line per budget violation. Empty when every measure is within budget. */
export function evaluate(js: Measured[], css: Measured[], budget: BudgetFile): string[] {
  const violations: string[] = [];
  const jsTotal = js.reduce((sum, m) => sum + m.gzipBytes, 0);
  const cssTotal = css.reduce((sum, m) => sum + m.gzipBytes, 0);
  if (jsTotal > budget.js.maxGzipBytes) {
    violations.push(`JS gzip ${jsTotal} B exceeds budget ${budget.js.maxGzipBytes} B`);
  }
  if (cssTotal > budget.css.maxGzipBytes) {
    violations.push(`CSS gzip ${cssTotal} B exceeds budget ${budget.css.maxGzipBytes} B`);
  }
  return violations;
}

function listFiles(dir: string, ext: string): string[] {
  return readdirSync(dir)
    .filter((name) => name.endsWith(ext))
    .map((name) => join(dir, name));
}

function measureFiles(paths: string[]): Measured[] {
  return paths.map((path) => ({
    name: relative(REPO_ROOT, path),
    gzipBytes: gzipSize(readFileSync(path)),
  }));
}

async function buildDashboard(outdir: string): Promise<void> {
  const result = await Bun.build({
    entrypoints: [ENTRY],
    outdir,
    target: "browser",
    minify: true,
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    throw new Error("dashboard build failed");
  }
}

function assertOutsideRepo(dir: string): void {
  const abs = resolve(dir);
  if (abs === REPO_ROOT || abs.startsWith(REPO_ROOT + sep)) {
    throw new Error(`--outdir must be outside the repo: ${abs}`);
  }
}

function parseOutdir(argv: string[]): string | undefined {
  const i = argv.indexOf("--outdir");
  if (i === -1) return undefined;
  const value = argv[i + 1];
  if (!value) throw new Error("--outdir needs a path");
  return value;
}

export async function main(argv: string[]): Promise<number> {
  const given = parseOutdir(argv);
  if (given) assertOutsideRepo(given);
  const outdir = given ? resolve(given) : mkdtempSync(join(tmpdir(), "sw-web-budget-"));
  try {
    await buildDashboard(outdir);
    const js = measureFiles(listFiles(outdir, ".js"));
    const css = measureFiles([...listFiles(outdir, ".css"), ...DASHBOARD_CSS]);
    const budget = loadBudget();
    for (const m of [...js, ...css])
      console.log(`${m.gzipBytes.toString().padStart(8)} B gzip  ${m.name}`);
    console.log(
      `JS total ${js.reduce((s, m) => s + m.gzipBytes, 0)} B (budget ${budget.js.maxGzipBytes} B)`,
    );
    console.log(
      `CSS total ${css.reduce((s, m) => s + m.gzipBytes, 0)} B (budget ${budget.css.maxGzipBytes} B)`,
    );

    const cdn = scanDirs([
      resolve(REPO_ROOT, "dashboard/public"),
      resolve(REPO_ROOT, "dashboard/src"),
      outdir,
    ]);
    for (const f of cdn) console.error(`${f.file}:${f.line}: external load: ${f.text}`);

    const violations = evaluate(js, css, budget);
    for (const v of violations) console.error(`budget: ${v}`);
    return violations.length + cdn.length > 0 ? 1 : 0;
  } finally {
    if (!given) rmSync(outdir, { recursive: true, force: true });
  }
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)));
