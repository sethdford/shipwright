/** Everything a lesson file holds. `renderLesson` writes it in the format `parseLesson` reads. */
export interface LessonFields {
  readonly id: string;
  readonly status: "proposed" | "active" | "retired";
  readonly failureClass?: string;
  readonly fingerprint?: string;
  readonly appliesTo: readonly string[];
  readonly keywords: readonly string[];
  readonly source?: string;
  readonly hypothesis: string;
  readonly title: string;
  readonly rule: string;
  /** Extra `## ` sections after the rule, in order: Evidence, Evaluation. Bodies are written as given. */
  readonly sections: readonly { readonly heading: string; readonly body: string }[];
}

/** One line, no double quotes: front-matter scalars are written inside "…" and read without escapes. */
export function oneLine(text: string): string {
  return text
    .replace(/[\r\n]+/g, " ")
    .replace(/"/g, "'")
    .trim();
}

function listItem(text: string): string {
  // Inline lists are split on commas and unquoted, so an item can hold neither.
  return oneLine(text).replace(/,/g, " ").replace(/'/g, "").trim();
}

function list(items: readonly string[]): string {
  const clean = items.map(listItem).filter((i) => i.length > 0);
  return clean.length === 0 ? "[]" : `[${clean.map((i) => `"${i}"`).join(", ")}]`;
}

function optional(key: string, value: string | undefined): string[] {
  return value === undefined ? [] : [`${key}: "${oneLine(value)}"`];
}

export function renderLesson(f: LessonFields): string {
  const head = [
    "---",
    `id: ${f.id}`,
    `status: ${f.status}`,
    ...optional("failure_class", f.failureClass),
    ...optional("fingerprint", f.fingerprint),
    `applies_to: ${list(f.appliesTo)}`,
    `keywords: ${list(f.keywords)}`,
    ...optional("source", f.source),
    `hypothesis: "${oneLine(f.hypothesis)}"`,
    "---",
    `# ${oneLine(f.title)}`,
    "",
    f.rule.trim(),
    "",
  ];
  const tail = f.sections.flatMap((s) => [`## ${s.heading}`, "", s.body.trim(), ""]);
  return [...head, ...tail].join("\n");
}

/** A fenced block that the text inside cannot close early. */
export function fenced(text: string): string {
  return ["```text", text.replace(/```/g, "'''"), "```"].join("\n");
}
