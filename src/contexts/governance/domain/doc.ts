import { metaList, metaString, parseFrontmatter } from "./frontmatter";

export type DocKind = "adr" | "policy" | "standard" | "lesson";

/** Where each kind of governance document lives, relative to the repository root. First match wins. */
export const DOC_ROOTS: Readonly<Record<DocKind, readonly string[]>> = {
  adr: ["docs/adr/", "docs/adrs/", "docs/decisions/", "docs/architecture/decisions/", "adr/"],
  policy: ["docs/policies/", ".shipwright/policies/"],
  standard: ["docs/standards/", ".shipwright/standards/"],
  lesson: [".shipwright/lessons/"],
};

export const DOC_KINDS: readonly DocKind[] = ["policy", "standard", "adr", "lesson"];

const SKIPPED_NAMES = /^(readme|index|template|_template|0000-template|adr-template)\.md$/i;

/** Statuses that take a document out of force. Anything else (accepted, active, unknown) is in force. */
const NOT_IN_FORCE = new Set([
  "proposed",
  "draft",
  "superseded",
  "deprecated",
  "rejected",
  "retired",
  "withdrawn",
]);

export interface GovernanceDoc {
  readonly kind: DocKind;
  readonly path: string;
  readonly id: string;
  readonly title: string;
  readonly status: string;
  /** Path globs this document governs. Empty means the whole repository. */
  readonly appliesTo: readonly string[];
  /** The part an agent needs: an ADR's Decision section, or a policy's or standard's body. */
  readonly text: string;
}

export function docKindOf(path: string): DocKind | null {
  if (!path.toLowerCase().endsWith(".md")) return null;
  const name = path.slice(path.lastIndexOf("/") + 1);
  if (SKIPPED_NAMES.test(name)) return null;
  for (const kind of DOC_KINDS) {
    if (DOC_ROOTS[kind].some((root) => path.startsWith(root))) return kind;
  }
  return null;
}

function baseName(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1).replace(/\.md$/i, "");
}

function defaultId(kind: DocKind, path: string): string {
  const name = baseName(path);
  if (kind !== "adr") return name;
  const digits = /^(?:adr[-_]?)?(\d+)/i.exec(name)?.[1];
  return digits === undefined ? name : `ADR-${digits.padStart(4, "0")}`;
}

function firstHeading(body: string): string | undefined {
  const m = /^#\s+(.+)$/m.exec(body);
  // "0009. Closed-loop learning" and "ADR-0009: Closed-loop learning" both become "Closed-loop learning".
  return m?.[1]?.trim().replace(/^(?:adr[-_ ]?)?\d+[.:)]?\s+/i, "");
}

function bodyStatus(body: string): string | undefined {
  const inline = /^\s*[*_]*status[*_]*\s*[:|]\s*[*_]*([A-Za-z-]+)/im.exec(body);
  if (inline?.[1]) return inline[1];
  const section = /^##+\s*status\s*\n+\s*[*_]*([A-Za-z-]+)/im.exec(body);
  return section?.[1];
}

/** The text of a `## <name>` section, up to the next heading of the same or a higher level. */
export function sectionText(body: string, name: string): string | undefined {
  const re = new RegExp(`^##\\s+${name}\\b[^\\n]*\\n`, "im");
  const m = re.exec(body);
  if (!m) return undefined;
  const rest = body.slice(m.index + m[0].length);
  const next = /^#{1,2}\s/m.exec(rest);
  return (next ? rest.slice(0, next.index) : rest).trim();
}

export function parseDoc(kind: DocKind, path: string, raw: string): GovernanceDoc {
  const { meta, body } = parseFrontmatter(raw);
  const status = (metaString(meta, "status") ?? bodyStatus(body) ?? "unknown").toLowerCase();
  const text = kind === "adr" ? (sectionText(body, "Decision") ?? body) : body;
  return {
    kind,
    path,
    id: metaString(meta, "id") ?? defaultId(kind, path),
    title: metaString(meta, "title") ?? firstHeading(body) ?? baseName(path),
    status,
    appliesTo: metaList(meta, "applies_to"),
    text: text.trim(),
  };
}

export function inForce(doc: Pick<GovernanceDoc, "status">): boolean {
  return !NOT_IN_FORCE.has(doc.status);
}

/** A lesson's or policy's rule: the body before its first `## ` section, without the `# ` title line. */
export function ruleText(body: string): string {
  const cut = body.search(/^##\s/m);
  return (cut === -1 ? body : body.slice(0, cut)).replace(/^#\s[^\n]*\n?/m, "").trim();
}
