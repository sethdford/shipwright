import { DEF_RULES, type DefRule, exportedBy, NOT_METHODS } from "./extract-rules";
import { importsOf } from "./imports";
import { type FileFacts, type Lang, langOf, type SymbolDef } from "./model";

const MAX_REFS = 3000;
const MAX_SIGNATURE = 160;

const KEYWORDS: ReadonlySet<string> = new Set(
  (
    "abstract and any as assert async await boolean break case catch class const constructor continue def default " +
    "defer del delete do done elif else enum esac except export extends false fi final finally fn for from func " +
    "function global go if impl implements import in instanceof interface is lambda let local loop match mod module " +
    "mut new nil none not null number object of or package pass private protected pub public raise readonly return " +
    "self static string struct super switch then this throw throws trait true try type typeof undefined unsafe use " +
    "var void where while with yield echo printf local readonly declare export unset shift exit"
  ).split(" "),
);

interface Open {
  readonly name: string;
  readonly indent: number;
}

function indentOf(line: string): number {
  const m = /^[ \t]*/.exec(line);
  return m ? m[0].replace(/\t/g, "    ").length : 0;
}

/** The first line of a comment right above `index`, without its comment markers. */
function docAbove(lines: readonly string[], index: number): string | undefined {
  const prev = (lines[index - 1] ?? "").trim();
  if (!/^(\/\/|#(?!!)|\*|\/\*\*?|--)/.test(prev)) return undefined;
  let i = index - 1;
  while (i > 0 && /^(\*|\/\/|#)/.test((lines[i - 1] ?? "").trim())) i -= 1;
  for (let j = i; j < index; j += 1) {
    const text = (lines[j] ?? "")
      .trim()
      .replace(/^(\/\*\*?|\*\/?|\/\/+|#+|--)\s?/, "")
      .replace(/\*\/$/, "")
      .trim();
    if (text.length > 0) return text.slice(0, MAX_SIGNATURE);
  }
  return undefined;
}

function matchRule(rules: readonly DefRule[], line: string, inside: boolean) {
  for (const rule of rules) {
    if (rule.inside && !inside) continue;
    const m = rule.re.exec(line);
    const name = m?.[rule.group];
    if (m && name && !(rule.inside && NOT_METHODS.has(name))) return { rule, m, name };
  }
  return undefined;
}

function toSymbol(
  lang: Lang,
  lines: readonly string[],
  i: number,
  stack: Open[],
): SymbolDef | undefined {
  const line = lines[i] ?? "";
  const indent = indentOf(line);
  while (stack.length > 0 && (stack[stack.length - 1]?.indent ?? 0) >= indent) stack.pop();
  const hit = matchRule(DEF_RULES[lang], line, stack.length > 0);
  if (!hit) return undefined;
  const { rule, m, name } = hit;
  const receiver = rule.receiver === undefined ? undefined : m[rule.receiver];
  const container = receiver ?? stack[stack.length - 1]?.name;
  if (rule.container) stack.push({ name, indent });
  const isMethod =
    rule.kind === "method" ||
    (rule.kind === "function" && container !== undefined && lang !== "sh");
  const doc = docAbove(lines, i);
  const sym: SymbolDef = {
    name,
    kind: rule.container && rule.kind === "module" ? "module" : isMethod ? "method" : rule.kind,
    line: i + 1,
    signature: line.trim().slice(0, MAX_SIGNATURE),
    exported: exportedBy(lang, name, line),
    ...(isMethod && container !== undefined && container !== name ? { container } : {}),
    ...(doc === undefined ? {} : { doc }),
  };
  return sym;
}

/** Definitions in source order. Impl blocks are containers, not symbols. */
export function symbolsOf(lang: Lang, text: string): readonly SymbolDef[] {
  const lines = text.split("\n");
  const stack: Open[] = [];
  const out: SymbolDef[] = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (line.trim().length === 0) continue;
    const sym = toSymbol(lang, lines, i, stack);
    if (sym && !(sym.kind === "module" && lang === "rs" && /^\s*impl\b/.test(line))) out.push(sym);
  }
  return out;
}

/** Distinct identifiers used in the text, minus keywords and the names it defines itself. */
export function refsOf(text: string, own: ReadonlySet<string>): readonly string[] {
  const seen = new Set<string>();
  for (const m of text.matchAll(/[A-Za-z_][A-Za-z0-9_]*/g)) {
    const id = m[0];
    if (id.length < 3 || KEYWORDS.has(id) || own.has(id)) continue;
    seen.add(id);
    if (seen.size >= MAX_REFS) break;
  }
  return [...seen].sort();
}

export function extractFacts(path: string, text: string): FileFacts {
  const lang = langOf(path);
  const symbols = symbolsOf(lang, text);
  const own = new Set(symbols.map((s) => s.name));
  return {
    lang,
    lines: text.length === 0 ? 0 : text.split("\n").length,
    symbols,
    imports: importsOf(lang, text),
    refs: refsOf(text, own),
  };
}
