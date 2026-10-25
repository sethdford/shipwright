// Fails when shipped dashboard source or built output references an external origin.
//
// How it works: decode HTML entities and JS escapes first, then take every candidate
// URL (scheme://, scheme:/, or a protocol-relative //host) and judge it with the
// WHATWG URL parser, the same parser browsers use. A candidate is allowed only when
// it parses, is http(s) with no userinfo, and its hostname is on the allowlist.
// Anything that fails to parse is flagged (fail closed).
//
// Covered: dashboard/public, dashboard/src (non-test files) and any extra dirs given.
// The website is not scanned yet.
// Usage: bun tools/web/no-cdn.ts [extra-dir ...]

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

export const REPO_ROOT = resolve(import.meta.dir, "..", "..");

const SCANNED_DIRS = ["dashboard/public", "dashboard/src"];
const SCANNED_EXT = /\.(html|css|svg|ts|js)$/;

// Hosts that are never a remote load. github.com is allowed only in prose and <a href>.
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1"]);
const PROJECT_HOSTS = new Set(["github.com"]);

// A scheme with an authority (or single slash), e.g. https://, HTTP:\\, https:/, ws://.
const ABSOLUTE = /(?<![a-z0-9+.-])[a-z][a-z0-9+.-]+:\/{1,2}[^\s"'`<>()[\]{},;]*/gi;
// A protocol-relative host, only after a URL-like boundary: quote, backtick, '=', ',', ';',
// whitespace, start of line, url( or import(. A bare '(' is excluded so that a regex literal
// such as /\/\/n?/ is not read as a URL.
const PROTOCOL_RELATIVE =
  /(^|[\s"'`=,;]|(?<=\burl\()|(?<=\bimport\())(\/\/[a-z0-9][^\s"'`<>()[\]{},;]*)/gim;

export interface CdnFinding {
  file: string;
  line: number;
  text: string;
}

interface Candidate {
  raw: string;
  index: number;
}

interface Attr {
  name: string;
  value: string;
  valueStart: number;
  valueEnd: number;
}

interface Tag {
  name: string;
  start: number;
  end: number;
  attrs: Attr[];
}

const codePoint = (n: number): string => (n > 0x10ffff ? "�" : String.fromCodePoint(n));

/** Undo the encodings a browser would undo before it reads a URL. */
export function decode(text: string): string {
  return text
    .replace(/&#x([0-9a-f]+);?/gi, (_, hex: string) => codePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);?/g, (_, dec: string) => codePoint(Number(dec)))
    .replace(/&colon;/gi, ":")
    .replace(/&sol;/gi, "/")
    .replace(/&bsol;/gi, "\\")
    .replace(/\\u([0-9a-f]{4})/gi, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\x([0-9a-f]{2})/gi, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\\//g, "/")
    .replace(/\\/g, "/");
}

function findCandidates(text: string): Candidate[] {
  const out: Candidate[] = [];
  for (const m of text.matchAll(ABSOLUTE)) out.push({ raw: m[0], index: m.index ?? 0 });
  for (const m of text.matchAll(PROTOCOL_RELATIVE)) {
    out.push({ raw: m[2] ?? "", index: (m.index ?? 0) + (m[1] ?? "").length });
  }
  return out;
}

// Attribute tokenizer for well-formed tags only. A malformed tag yields no exemption.
const TAG =
  /<([a-z][a-z0-9-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*\/?>/gi;
const ATTR = /([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;

function parseTags(text: string): Tag[] {
  const tags: Tag[] = [];
  for (const m of text.matchAll(TAG)) {
    const start = m.index ?? 0;
    const name = (m[1] ?? "").toLowerCase();
    const attrsBase = start + 1 + (m[1] ?? "").length;
    const attrs: Attr[] = [];
    for (const a of (m[2] ?? "").matchAll(ATTR)) {
      const quoted = a[2] !== undefined || a[3] !== undefined;
      const value = a[2] ?? a[3] ?? a[4] ?? "";
      const valueEnd = attrsBase + (a.index ?? 0) + a[0].length - (quoted ? 1 : 0);
      attrs.push({
        name: (a[1] ?? "").toLowerCase(),
        value,
        valueStart: valueEnd - value.length,
        valueEnd,
      });
    }
    tags.push({ name, start, end: start + m[0].length, attrs });
  }
  return tags;
}

function attrAt(tags: Tag[], index: number): { tag: Tag; attr: Attr } | undefined {
  for (const tag of tags) {
    if (index < tag.start || index >= tag.end) continue;
    for (const attr of tag.attrs) {
      if (index >= attr.valueStart && index < attr.valueEnd) return { tag, attr };
    }
  }
  return undefined;
}

// Canonical links and named meta tags are not loads. The rel list must be exactly "canonical",
// with a single rel attribute, so a second rel cannot widen it.
function isCanonicalOnly(tag: Tag): boolean {
  const rels = tag.attrs.filter((a) => a.name === "rel");
  if (rels.length !== 1) return false;
  const tokens = (rels[0]?.value ?? "").trim().toLowerCase().split(/\s+/);
  return tokens.length === 1 && tokens[0] === "canonical";
}

function isNamedMeta(tag: Tag): boolean {
  if (tag.attrs.some((a) => a.name === "http-equiv")) return false;
  return tag.attrs.some((a) => a.name === "name" || a.name === "property");
}

function exemptByAttribute(tags: Tag[], index: number, host: string): boolean {
  const hit = attrAt(tags, index);
  if (!hit) return false;
  const { tag, attr } = hit;
  if (attr.name === "placeholder") return true;
  if (attr.name === "xmlns" || attr.name.startsWith("xmlns:")) return host === "www.w3.org";
  if (tag.name === "link") return attr.name === "href" && isCanonicalOnly(tag);
  if (tag.name === "meta") return attr.name === "content" && isNamedMeta(tag);
  return false;
}

// True when the candidate at `index` is fetched (script, style, font, image, import).
function isLoadContext(text: string, index: number): boolean {
  const before = text.slice(Math.max(0, index - 120), index);
  if (/\b(src|srcset|data|poster)\s*=\s*["']?$/i.test(before)) return true;
  if (/\burl\(\s*["']?$/i.test(before)) return true;
  if (/@import\s*(url\(\s*)?["']?$/i.test(before)) return true;
  if (/\bimport\s*\(\s*[`"']?$/.test(before)) return true;
  if (/\b(from|import)\s*[`"']$/.test(before)) return true;
  if (/\bhref\s*=\s*["']?$/i.test(before)) {
    const tagName = /<([a-z][a-z0-9-]*)\b[^<>]*$/i.exec(before)?.[1]?.toLowerCase();
    return tagName !== "a";
  }
  return false;
}

function isAllowed(text: string, tags: Tag[], c: Candidate): boolean {
  let url: URL;
  try {
    url = new URL(c.raw, "https://base.invalid/");
  } catch {
    return false;
  }
  if (url.username !== "" || url.password !== "") return false;
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  const host = url.hostname;
  if (LOCAL_HOSTS.has(host)) return true;
  if (exemptByAttribute(tags, c.index, host)) return true;
  const before = text.slice(Math.max(0, c.index - 40), c.index);
  if (host === "www.w3.org" && /xmlns\s*=\s*["']?$/i.test(before)) return true;
  if (PROJECT_HOSTS.has(host) && !isLoadContext(text, c.index)) return true;
  return false;
}

export function scanText(file: string, text: string): CdnFinding[] {
  const decoded = decode(text);
  const tags = /\.html$/.test(file) ? parseTags(decoded) : [];
  const lines = decoded.split("\n");
  const findings: CdnFinding[] = [];
  for (const c of findCandidates(decoded)) {
    if (isAllowed(decoded, tags, c)) continue;
    const line = decoded.slice(0, c.index).split("\n").length;
    findings.push({ file, line, text: (lines[line - 1] ?? "").trim().slice(0, 160) });
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
