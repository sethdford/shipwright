/** A value in a front-matter block: a scalar or a flat list of scalars. */
export type MetaValue = string | readonly string[];

export interface Parsed {
  readonly meta: Readonly<Record<string, MetaValue>>;
  readonly body: string;
}

const KEY_LINE = /^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/;

function unquote(text: string): string {
  const t = text.trim();
  if (t.length >= 2 && (t[0] === '"' || t[0] === "'") && t[t.length - 1] === t[0]) {
    return t.slice(1, -1);
  }
  return t;
}

function stripComment(text: string): string {
  // A " #" starts a comment, as in YAML; a "#" inside a word (an issue number like #8644) does not.
  const at = text.search(/\s#/);
  return at === -1 ? text : text.slice(0, at);
}

function inlineList(text: string): readonly string[] | null {
  const t = text.trim();
  if (!t.startsWith("[") || !t.endsWith("]")) return null;
  return t
    .slice(1, -1)
    .split(",")
    .map(unquote)
    .filter((v) => v.length > 0);
}

function parseBlock(lines: readonly string[]): Record<string, MetaValue> {
  const meta: Record<string, MetaValue> = {};
  let listKey: string | null = null;
  for (const line of lines) {
    const item = /^\s+-\s+(.*)$/.exec(line);
    if (item && listKey !== null) {
      const prev = meta[listKey];
      meta[listKey] = [...(Array.isArray(prev) ? prev : []), unquote(stripComment(item[1] ?? ""))];
      continue;
    }
    const kv = KEY_LINE.exec(line);
    if (!kv) continue;
    const key = (kv[1] ?? "").toLowerCase();
    const raw = stripComment(kv[2] ?? "").trim();
    listKey = raw === "" ? key : null;
    meta[key] = raw === "" ? [] : (inlineList(raw) ?? unquote(raw));
  }
  return meta;
}

/**
 * Splits a Markdown file into its front matter and body. Only the YAML subset these files need is read:
 * `key: value`, `key: [a, b]` and `key:` followed by `- item` lines. Anything else in the block is ignored.
 * A file without a leading `---` block has empty meta and the whole text as its body.
 */
export function parseFrontmatter(text: string): Parsed {
  const normalized = text.replace(/\r\n/g, "\n");
  if (!normalized.startsWith("---\n")) return { meta: {}, body: normalized };
  const end = normalized.indexOf("\n---", 4);
  if (end === -1) return { meta: {}, body: normalized };
  const block = normalized.slice(4, end).split("\n");
  const rest = normalized.slice(end + 4);
  return { meta: parseBlock(block), body: rest.replace(/^[^\n]*\n/, "") };
}

export function metaString(
  meta: Readonly<Record<string, MetaValue>>,
  key: string,
): string | undefined {
  const v = meta[key];
  if (typeof v === "string") return v.length > 0 ? v : undefined;
  return undefined;
}

export function metaList(
  meta: Readonly<Record<string, MetaValue>>,
  key: string,
): readonly string[] {
  const v = meta[key];
  if (v === undefined) return [];
  return typeof v === "string" ? [v] : v;
}
