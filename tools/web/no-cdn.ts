// Fails when shipped dashboard source or built output references an external
// origin. The scan covers whole files, so tags and template strings that span
// lines are caught. Any absolute (https?://host) or protocol-relative (//host)
// origin is flagged unless it falls in the allowlist below. Covered directories:
// dashboard/public, dashboard/src (non-test files) and any extra dirs passed in.
// The website is not scanned here yet.
// Usage: bun tools/web/no-cdn.ts [extra-dir ...]

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

export const REPO_ROOT = resolve(import.meta.dir, "..", "..");

const SCANNED_DIRS = ["dashboard/public", "dashboard/src"];
const SCANNED_EXT = /\.(html|css|svg|ts|js)$/;

// Absolute origin: https://host or http://host (any case).
const ABSOLUTE = /\bhttps?:\/\/([a-z0-9-]+(?:\.[a-z0-9-]+)*)/gi;
// Protocol-relative origin: //host.tld, only after a boundary so that comments
// like "// note" and ws:// URLs are not matched.
const PROTOCOL_RELATIVE = /(^|[\s"'(=,;])\/\/([a-z0-9-]+(?:\.[a-z0-9-]+)+)/gi;

// Hosts that are never a remote load: local development and this project's own GitHub.
const ALLOWED_HOSTS = new Set(["localhost", "127.0.0.1", "github.com", "www.github.com"]);

export interface CdnFinding {
  file: string;
  line: number;
  text: string;
}

interface Origin {
  host: string;
  index: number;
}

function findOrigins(text: string): Origin[] {
  const found: Origin[] = [];
  for (const m of text.matchAll(ABSOLUTE))
    found.push({ host: (m[1] ?? "").toLowerCase(), index: m.index ?? 0 });
  for (const m of text.matchAll(PROTOCOL_RELATIVE)) {
    found.push({ host: (m[2] ?? "").toLowerCase(), index: (m.index ?? 0) + (m[1] ?? "").length });
  }
  return found;
}

// Namespace URIs, placeholder text and canonical or meta tags are not fetched.
function isAllowedContext(text: string, { host, index }: Origin): boolean {
  if (ALLOWED_HOSTS.has(host)) return true;
  const before = text.slice(Math.max(0, index - 80), index);
  if (host === "www.w3.org" && /xmlns\s*=\s*["']?$/i.test(before)) return true;
  if (/placeholder\s*=\s*["'][^"']*$/i.test(before)) return true;
  const tagStart = text.lastIndexOf("<", index);
  const tagEnd = text.indexOf(">", index);
  if (tagStart !== -1 && tagEnd !== -1) {
    const tag = text.slice(tagStart, tagEnd + 1);
    if (/^<meta\b/i.test(tag)) return true;
    if (/^<link\b/i.test(tag) && /\brel\s*=\s*["']?canonical\b/i.test(tag)) return true;
  }
  return false;
}

export function scanText(file: string, text: string): CdnFinding[] {
  const findings: CdnFinding[] = [];
  for (const origin of findOrigins(text)) {
    if (isAllowedContext(text, origin)) continue;
    const line = text.slice(0, origin.index).split("\n").length;
    const lineText = text.split("\n")[line - 1] ?? "";
    findings.push({ file, line, text: lineText.trim().slice(0, 160) });
  }
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
  const existing = dirs.filter((d) => statSync(d, { throwIfNoEntry: false })?.isDirectory());
  const findings = scanDirs(existing);
  for (const f of findings) console.error(`${f.file}:${f.line}: external origin: ${f.text}`);
  if (findings.length > 0) return 1;
  console.log("no-cdn: no external origin outside the allowlist");
  return 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
