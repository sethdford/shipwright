// Fails when shipped dashboard or website source loads a script, stylesheet, or
// font from an external origin. Allowlist: none. Plain links and xmlns namespace
// URIs are not loads, so they are not matched.
// Usage: bun tools/web/no-cdn.ts [extra-dir ...]

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

export const REPO_ROOT = resolve(import.meta.dir, "..", "..");

const SCANNED_DIRS = ["dashboard/public", "dashboard/src"];
const SCANNED_EXT = /\.(html|css|svg|ts|js)$/;

const LOAD_PATTERNS: RegExp[] = [
  /<script\b[^>]*\bsrc\s*=\s*["']?https?:\/\//i,
  /<link\b[^>]*\bhref\s*=\s*["']?https?:\/\//i,
  /@import\s+(?:url\(\s*)?["']?https?:\/\//i,
  /url\(\s*["']?https?:\/\//i,
  /\bimport\s*\(\s*["']https?:\/\//,
  /\bfrom\s+["']https?:\/\//,
  /\bimport\s+["']https?:\/\//,
];

export interface CdnFinding {
  file: string;
  line: number;
  text: string;
}

export function scanText(file: string, text: string): CdnFinding[] {
  const findings: CdnFinding[] = [];
  text.split("\n").forEach((line, index) => {
    if (LOAD_PATTERNS.some((pattern) => pattern.test(line))) {
      findings.push({ file, line: index + 1, text: line.trim().slice(0, 160) });
    }
  });
  return findings;
}

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const abs = join(dir, entry);
    if (statSync(abs).isDirectory()) {
      out.push(...walk(abs));
    } else if (SCANNED_EXT.test(entry) && !/\.test\.ts$/.test(entry)) {
      out.push(abs);
    }
  }
  return out;
}

export function scanDirs(dirs: string[]): CdnFinding[] {
  const findings: CdnFinding[] = [];
  for (const dir of dirs) {
    for (const file of walk(dir)) {
      findings.push(...scanText(relative(REPO_ROOT, file), readFileSync(file, "utf8")));
    }
  }
  return findings;
}

export function main(extraDirs: string[]): number {
  const dirs = [
    ...SCANNED_DIRS.map((d) => resolve(REPO_ROOT, d)),
    ...extraDirs.map((d) => resolve(d)),
  ];
  const findings = scanDirs(
    dirs.filter((d) => statSync(d, { throwIfNoEntry: false })?.isDirectory()),
  );
  for (const f of findings) console.error(`${f.file}:${f.line}: external load: ${f.text}`);
  if (findings.length > 0) return 1;
  console.log("no-cdn: no external script, style or font loads");
  return 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
