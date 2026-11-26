import type { Lang } from "./model";

const MAX_IMPORTS = 400;

const PATTERNS: Readonly<Record<Lang, readonly RegExp[]>> = {
  ts: [
    /\bfrom\s+["']([^"']+)["']/g,
    /^\s*import\s+["']([^"']+)["']/gm,
    /\brequire\(\s*["']([^"']+)["']\s*\)/g,
    /\bimport\(\s*["']([^"']+)["']\s*\)/g,
  ],
  js: [],
  py: [/^\s*from\s+(\.*[\w.]*)\s+import\b/gm, /^\s*import\s+([\w.]+)/gm],
  go: [/^\s*import\s+(?:\w+\s+)?"([^"]+)"/gm, /^\s+(?:[\w.]+\s+)?"([^"]+)"\s*$/gm],
  rs: [/^\s*(?:pub\s+)?mod\s+(\w+)\s*;/gm, /^\s*(?:pub\s+)?use\s+((?:crate|super|self)::[\w:]+)/gm],
  sh: [/(?:^|&&|\|\||;|\bthen)\s*(?:source\s+|\.\s+(?=["'$]))["']?([^"'\s;|&)]+)/gm],
  java: [/^\s*import\s+(?:static\s+)?([\w.]+)/gm],
  rb: [/^\s*require\s+["']([^"']+)["']/gm, /^\s*require_relative\s+["']([^"']+)["']/gm],
  other: [],
};

/** Import specifiers as written, in first-seen order. `require_relative` paths get a `./` prefix. */
export function importsOf(lang: Lang, text: string): readonly string[] {
  const patterns = PATTERNS[lang === "js" ? "ts" : lang];
  const seen = new Set<string>();
  for (const re of patterns) {
    for (const m of text.matchAll(re)) {
      let spec = m[1] ?? "";
      if (re.source.includes("require_relative") && !spec.startsWith(".")) spec = `./${spec}`;
      if (spec.length > 0) seen.add(spec);
      if (seen.size >= MAX_IMPORTS) return [...seen];
    }
  }
  return [...seen];
}

function dirOf(path: string): string {
  const i = path.lastIndexOf("/");
  return i === -1 ? "" : path.slice(0, i);
}

/** Joins and normalizes `a/b` + `../c` without touching the file system. */
export function joinPath(base: string, rel: string): string | undefined {
  const parts = base.length > 0 ? base.split("/") : [];
  for (const part of rel.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return undefined;
      parts.pop();
    } else parts.push(part);
  }
  return parts.join("/");
}

const TS_EXT = [
  "",
  ".ts",
  ".tsx",
  ".js",
  ".jsx",
  ".mjs",
  ".cjs",
  "/index.ts",
  "/index.tsx",
  "/index.js",
];

function firstKnown(candidates: readonly string[], files: ReadonlySet<string>): string | undefined {
  return candidates.find((c) => files.has(c));
}

function resolveTs(from: string, spec: string, files: ReadonlySet<string>): string | undefined {
  if (!spec.startsWith(".")) return undefined;
  const base = joinPath(dirOf(from), spec);
  if (base === undefined) return undefined;
  const noJs = base.replace(/\.(m|c)?js$/, "");
  return firstKnown([...TS_EXT.map((e) => base + e), ...TS_EXT.map((e) => noJs + e)], files);
}

function resolvePy(from: string, spec: string, files: ReadonlySet<string>): string | undefined {
  const dots = /^\.*/.exec(spec)?.[0].length ?? 0;
  const mod = spec.slice(dots).replace(/\./g, "/");
  let base = dots === 0 ? "" : dirOf(from);
  for (let i = 1; i < dots; i += 1) base = dirOf(base);
  const rel = [base, mod].filter((p) => p.length > 0).join("/");
  const direct = firstKnown([`${rel}.py`, `${rel}/__init__.py`], files);
  if (direct !== undefined || dots > 0) return direct;
  // An absolute import may be rooted at src/ or at any package directory: match by suffix.
  return suffixMatch([`/${mod}.py`, `/${mod}/__init__.py`], files);
}

function suffixMatch(suffixes: readonly string[], files: ReadonlySet<string>): string | undefined {
  for (const f of files) if (suffixes.some((s) => `/${f}`.endsWith(s))) return f;
  return undefined;
}

function resolveSh(from: string, spec: string, files: ReadonlySet<string>): string | undefined {
  // `"$SCRIPT_DIR/lib/x.sh"`, `"$(dirname "$0")/x.sh"`: drop the variable part and match the rest by suffix.
  const tail = spec.replace(/\$\([^)]*\)|\$\{[^}]*\}|\$\w+/g, "").replace(/^\.?\/+/, "");
  if (tail.length === 0) return undefined;
  const local = joinPath(dirOf(from), tail);
  if (local !== undefined && files.has(local)) return local;
  return suffixMatch([`/${tail}`], files);
}

function resolveRs(from: string, spec: string, files: ReadonlySet<string>): string | undefined {
  if (spec.includes("::")) {
    const parts = spec.split("::").slice(1, -1);
    if (parts.length === 0) return undefined;
    return suffixMatch([`/src/${parts.join("/")}.rs`, `/src/${parts.join("/")}/mod.rs`], files);
  }
  const dir = dirOf(from);
  return firstKnown(
    [joinPath(dir, `${spec}.rs`) ?? "", joinPath(dir, `${spec}/mod.rs`) ?? ""],
    files,
  );
}

/** The repository file an import specifier names, or undefined for a package or an unresolved name. */
export function resolveImport(
  lang: Lang,
  from: string,
  spec: string,
  files: ReadonlySet<string>,
): string | undefined {
  switch (lang) {
    case "ts":
    case "js":
      return resolveTs(from, spec, files);
    case "py":
      return resolvePy(from, spec, files);
    case "sh":
      return resolveSh(from, spec, files);
    case "rs":
      return resolveRs(from, spec, files);
    case "rb":
      return spec.startsWith(".")
        ? firstKnown([`${joinPath(dirOf(from), spec)}.rb`], files)
        : undefined;
    case "java":
      return suffixMatch(
        [`/${spec.replace(/\./g, "/")}.java`, `/${spec.replace(/\./g, "/")}.kt`],
        files,
      );
    case "go":
      return undefined; // package imports name directories; refs connect Go files instead
    default:
      return undefined;
  }
}
