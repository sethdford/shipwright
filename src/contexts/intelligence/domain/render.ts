import type { RepoGraph } from "./graph";
import type { LocalizedFile } from "./localize";
import type { SymbolDef } from "./model";
import type { TestLink } from "./tests-map";

export const MAP_BUDGET_CHARS = 6000;

function symbolLine(s: SymbolDef): string {
  const where = s.container ? `${s.container}.` : "";
  return `  ${String(s.line).padStart(5)}  ${s.kind} ${where}${s.name}: ${s.signature}`;
}

/**
 * Aider-style repo map: the ranked files, each with its public definitions, cut at a character budget (about a
 * quarter as many tokens). Files that do not fit are counted, not dropped silently.
 */
export function renderMap(
  graph: RepoGraph,
  ranked: readonly (readonly [string, number])[],
  budget = MAP_BUDGET_CHARS,
): string {
  const lines: string[] = [];
  let used = 0;
  let shown = 0;
  for (const [path] of ranked) {
    const f = graph.byPath.get(path);
    if (!f) continue;
    const syms = f.symbols.filter((s) => s.exported || s.kind === "class").slice(0, 12);
    const block = [`${path}`, ...syms.map(symbolLine)];
    const size = block.reduce((a, l) => a + l.length + 1, 0);
    if (used + size > budget && shown > 0) break;
    lines.push(...block);
    used += size;
    shown += 1;
  }
  const rest = ranked.length - shown;
  if (rest > 0) lines.push(`… ${rest} more files ranked lower`);
  return lines.join("\n");
}

export interface BriefInput {
  readonly located: readonly LocalizedFile[];
  readonly tests: ReadonlyMap<string, readonly TestLink[]>;
  readonly owners: ReadonlyMap<string, readonly string[]>;
  readonly toolsAvailable: boolean;
  readonly stats: { readonly files: number; readonly symbols: number };
}

function locatedBlock(f: LocalizedFile, input: BriefInput): string[] {
  const why = f.why.length > 0 ? ` (${f.why.join("; ")})` : "";
  const lines = [`- ${f.path}${why}`];
  for (const s of f.symbols.slice(0, 4)) {
    lines.push(`    ${s.line}: ${s.container ? `${s.container}.` : ""}${s.name} — ${s.signature}`);
  }
  const tests = input.tests.get(f.path) ?? [];
  if (tests.length > 0)
    lines.push(
      `    tests: ${tests
        .slice(0, 3)
        .map((t) => t.path)
        .join(", ")}`,
    );
  const owners = input.owners.get(f.path) ?? [];
  if (owners.length > 0) lines.push(`    owners: ${owners.join(" ")}`);
  return lines;
}

const TOOL_HELP = [
  "The `repomodel` tools answer from an index of this repository that stays current as you edit:",
  "`search` (code by meaning-words), `definition` (where a name is defined), `references` (who uses it, by",
  "enclosing function), `outline` (a file's definitions), `dependencies` (imports and importers), `tests_for`",
  "(tests to run for a file), `owners`, `repo_map`, and `localize` (files and definitions for a task).",
  "Prefer them to repeated grep: one call returns ranked, located results.",
].join("\n");

/** The prompt section: where the task most likely lives, with tests and owners, then how to ask for more. */
export function renderBrief(input: BriefInput): string {
  if (input.located.length === 0 && !input.toolsAvailable) return "";
  const out = [
    "## Repository model",
    "",
    `Indexed ${input.stats.files} source files and ${input.stats.symbols} definitions. Most likely relevant to`,
    "this task, best first (a starting point from static analysis, not a verdict; check before you edit):",
    "",
  ];
  const src = input.located.filter((f) => !f.test);
  for (const f of src.slice(0, 8)) out.push(...locatedBlock(f, input));
  if (src.length === 0) out.push("- (nothing matched; use the tools below to search)");
  if (input.toolsAvailable) out.push("", TOOL_HELP);
  return out.join("\n");
}
