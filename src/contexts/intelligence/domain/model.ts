/**
 * The repository world model (ADR-0012): what each source file defines, imports and refers to, kept per file
 * and keyed by a content hash so a refresh re-reads only the files that changed.
 */

export const MODEL_SCHEMA = 1;
/** Bumped whenever extraction rules change, so a stored model is rebuilt instead of reused. */
export const EXTRACTOR_VERSION = 1;

export type Lang = "ts" | "js" | "py" | "go" | "rs" | "sh" | "java" | "rb" | "other";

export type SymbolKind =
  | "function"
  | "class"
  | "method"
  | "interface"
  | "type"
  | "const"
  | "enum"
  | "struct"
  | "trait"
  | "module";

export interface SymbolDef {
  readonly name: string;
  readonly kind: SymbolKind;
  /** 1-based line of the definition. */
  readonly line: number;
  /** The definition line, trimmed and cut to 160 characters. */
  readonly signature: string;
  readonly exported: boolean;
  /** The enclosing class, impl or struct, for methods. */
  readonly container?: string;
  /** The first line of the comment right above the definition, when there is one. */
  readonly doc?: string;
}

/** What one file says, as read from its text. Pure function of (path, text). */
export interface FileFacts {
  readonly lang: Lang;
  readonly lines: number;
  readonly symbols: readonly SymbolDef[];
  /** Import specifiers as written (`./x`, `node:fs`, `os.path`, `$SCRIPT_DIR/lib/x.sh`). */
  readonly imports: readonly string[];
  /** Distinct identifiers the file uses that are not its own definitions or keywords. */
  readonly refs: readonly string[];
}

export interface FileEntry extends FileFacts {
  readonly path: string;
  readonly hash: string;
  readonly size: number;
  readonly mtimeMs: number;
  readonly test: boolean;
}

export interface AuthorStat {
  readonly name: string;
  readonly commits: number;
  /** ISO date of the author's latest commit to the file. */
  readonly last: string;
}

export interface RepoModel {
  readonly schema: number;
  readonly extractor: number;
  readonly root: string;
  readonly builtAt: string;
  /** The commit checked out when the model was built (authorship is re-read when it moves). */
  readonly head: string;
  /** Sorted by path. */
  readonly files: readonly FileEntry[];
  /** CODEOWNERS text, when the repository has one. */
  readonly codeowners: string;
  /** Recent authorship per path, from git history. */
  readonly authors: Readonly<Record<string, readonly AuthorStat[]>>;
}

const EXT: Readonly<Record<string, Lang>> = {
  ts: "ts",
  tsx: "ts",
  mts: "ts",
  cts: "ts",
  js: "js",
  jsx: "js",
  mjs: "js",
  cjs: "js",
  py: "py",
  go: "go",
  rs: "rs",
  sh: "sh",
  bash: "sh",
  java: "java",
  kt: "java",
  rb: "rb",
};

export function langOf(path: string): Lang {
  const base = path.slice(path.lastIndexOf("/") + 1);
  const dot = base.lastIndexOf(".");
  if (dot <= 0) return "other";
  return EXT[base.slice(dot + 1).toLowerCase()] ?? "other";
}

const TEST_PATTERNS: readonly RegExp[] = [
  /(^|\/)(tests?|__tests__|spec|specs)\//,
  /\.(test|spec)\.[a-z]+$/,
  /(^|\/)test_[^/]+\.py$/,
  /_test\.(py|go)$/,
  /-test\.sh$/,
  /Test\.(java|kt)$/,
  /_spec\.rb$/,
];

export function isTestPath(path: string): boolean {
  return TEST_PATTERNS.some((re) => re.test(path));
}

/** Source files the model indexes: a known language and not vendored or generated. */
export function indexable(path: string): boolean {
  if (langOf(path) === "other") return false;
  return (
    !/(^|\/)(node_modules|vendor|dist|build|\.git|third_party)\//.test(path) &&
    !/\.min\.js$/.test(path)
  );
}
