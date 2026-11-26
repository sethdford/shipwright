import type { Lang, SymbolKind } from "./model";

/**
 * Line rules for definitions, one table per language. These are deliberately tag-level (the facts ctags or
 * tree-sitter tag queries give: name, kind, line, container), not a full parse: enough for search, a repo map and
 * a reference graph, with no native dependency. A tree-sitter extractor can replace a table without changing the
 * model (ADR-0016).
 */
export interface DefRule {
  readonly re: RegExp;
  readonly kind: SymbolKind;
  /** Capture group holding the name. */
  readonly group: number;
  /** A definition that encloses methods (a class, impl or struct body). */
  readonly container?: boolean;
  /** Matches only inside a container (a method rule). */
  readonly inside?: boolean;
  /** Capture group holding the receiver type (Go methods, Rust impl targets). */
  readonly receiver?: number;
}

const ID = "[A-Za-z_$][\\w$]*";

const TS: readonly DefRule[] = [
  {
    re: new RegExp(`^\\s*(export\\s+)?(default\\s+)?(async\\s+)?function\\*?\\s+(${ID})`),
    kind: "function",
    group: 4,
  },
  {
    re: new RegExp(`^\\s*(export\\s+)?(default\\s+)?(abstract\\s+)?class\\s+(${ID})`),
    kind: "class",
    group: 4,
    container: true,
  },
  {
    re: new RegExp(`^\\s*(export\\s+)?interface\\s+(${ID})`),
    kind: "interface",
    group: 2,
    container: true,
  },
  {
    re: new RegExp(`^\\s*(export\\s+)?type\\s+(${ID})\\s*(<[^=]*>)?\\s*=`),
    kind: "type",
    group: 2,
  },
  {
    re: new RegExp(`^\\s*(export\\s+)?(declare\\s+)?(const\\s+)?enum\\s+(${ID})`),
    kind: "enum",
    group: 4,
  },
  {
    re: new RegExp(
      `^\\s*(export\\s+)?(const|let|var)\\s+(${ID})\\s*(:[^=]+)?=\\s*(async\\s+)?(\\([^)]*\\)|${ID})\\s*(:[^=]+)?=>`,
    ),
    kind: "function",
    group: 3,
  },
  { re: new RegExp(`^(export\\s+)?(const|let|var)\\s+(${ID})\\s*[:=]`), kind: "const", group: 3 },
  {
    re: new RegExp(
      `^\\s+(?:(?:public|private|protected|static|async|readonly|override|abstract|get|set)\\s+)*(${ID})\\s*(<[^>]*>)?\\([^;=]*\\)\\s*(:\\s*[^=;{]+)?\\{\\s*$`,
    ),
    kind: "method",
    group: 1,
    inside: true,
  },
];

const PY: readonly DefRule[] = [
  { re: /^\s*(async\s+)?def\s+(\w+)/, kind: "function", group: 2 },
  { re: /^\s*class\s+(\w+)/, kind: "class", group: 1, container: true },
  { re: /^([A-Z][A-Z0-9_]+)\s*(:[^=]+)?=/, kind: "const", group: 1 },
];

const GO: readonly DefRule[] = [
  {
    re: /^func\s+\(\s*\w*\s*\*?(\w+)(\[[^\]]*\])?\s*\)\s*(\w+)/,
    kind: "method",
    group: 3,
    receiver: 1,
  },
  { re: /^func\s+(\w+)/, kind: "function", group: 1 },
  { re: /^type\s+(\w+)(\[[^\]]*\])?\s+struct\b/, kind: "struct", group: 1 },
  { re: /^type\s+(\w+)(\[[^\]]*\])?\s+interface\b/, kind: "interface", group: 1 },
  { re: /^type\s+(\w+)/, kind: "type", group: 1 },
  { re: /^(?:const|var)\s+([A-Z]\w*)/, kind: "const", group: 1 },
];

const RS: readonly DefRule[] = [
  {
    re: /^\s*impl(?:<[^>]*>)?\s+(?:[\w:]+(?:<[^>]*>)?\s+for\s+)?(\w+)/,
    kind: "module",
    group: 1,
    container: true,
    receiver: 1,
  },
  {
    re: /^\s*(pub(\([^)]*\))?\s+)?(const\s+)?(async\s+)?(unsafe\s+)?(extern\s+"\w+"\s+)?fn\s+(\w+)/,
    kind: "function",
    group: 7,
  },
  { re: /^\s*(pub(\([^)]*\))?\s+)?struct\s+(\w+)/, kind: "struct", group: 3 },
  { re: /^\s*(pub(\([^)]*\))?\s+)?enum\s+(\w+)/, kind: "enum", group: 3 },
  { re: /^\s*(pub(\([^)]*\))?\s+)?trait\s+(\w+)/, kind: "trait", group: 3, container: true },
  { re: /^\s*(pub(\([^)]*\))?\s+)?type\s+(\w+)/, kind: "type", group: 3 },
  { re: /^\s*(pub(\([^)]*\))?\s+)?(const|static)\s+([A-Z_][A-Z0-9_]*)/, kind: "const", group: 4 },
  { re: /^\s*(pub(\([^)]*\))?\s+)?mod\s+(\w+)\s*\{/, kind: "module", group: 3 },
];

const SH: readonly DefRule[] = [
  { re: /^\s*function\s+([A-Za-z_][\w:.-]*)\s*(\(\s*\))?\s*\{?/, kind: "function", group: 1 },
  { re: /^\s*([A-Za-z_][\w:.-]*)\s*\(\s*\)\s*\{?/, kind: "function", group: 1 },
];

const JAVA: readonly DefRule[] = [
  {
    re: /^\s*(?:(?:public|private|protected|static|final|abstract|sealed|data|open|internal)\s+)*(class|interface|enum|record|object)\s+(\w+)/,
    kind: "class",
    group: 2,
    container: true,
  },
  {
    re: /^\s*(?:(?:public|private|protected|internal|override|suspend|open)\s+)*fun\s+(?:<[^>]*>\s*)?(?:\w+\.)?(\w+)/,
    kind: "function",
    group: 1,
  },
  {
    re: /^\s+(?:(?:public|private|protected|static|final|abstract|synchronized|native|default)\s+)+[\w<>[\],.?\s]+\s+(\w+)\s*\(/,
    kind: "method",
    group: 1,
    inside: true,
  },
];

const RB: readonly DefRule[] = [
  { re: /^\s*(class|module)\s+([A-Z]\w*(::[A-Z]\w*)*)/, kind: "class", group: 2, container: true },
  { re: /^\s*def\s+(self\.)?(\w+[?!=]?)/, kind: "function", group: 2 },
];

export const DEF_RULES: Readonly<Record<Lang, readonly DefRule[]>> = {
  ts: TS,
  js: TS,
  py: PY,
  go: GO,
  rs: RS,
  sh: SH,
  java: JAVA,
  rb: RB,
  other: [],
};

/** Words that look like a method name to the TS method rule but are statements. */
export const NOT_METHODS: ReadonlySet<string> = new Set([
  "if",
  "for",
  "while",
  "switch",
  "catch",
  "function",
  "return",
  "constructor",
  "super",
  "new",
  "await",
  "typeof",
  "else",
  "do",
  "with",
]);

/** Whether a definition is part of the file's public surface, by each language's convention. */
export function exportedBy(lang: Lang, name: string, line: string): boolean {
  switch (lang) {
    case "ts":
    case "js":
      return /^\s*export\b/.test(line);
    case "go":
      return /^[A-Z]/.test(name);
    case "rs":
      return /^\s*pub\b/.test(line);
    case "java":
      return !/\bprivate\b/.test(line);
    default:
      return !name.startsWith("_");
  }
}
