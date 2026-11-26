import {
  definitionText,
  dependenciesText,
  localizeText,
  outlineText,
  ownersText,
  referencesText,
  repoMapText,
  searchText,
  testsText,
} from "./queries";
import type { RepoSession, Snapshot } from "./session";

export interface ToolSpec {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: Readonly<Record<string, unknown>>;
}

type Args = Readonly<Record<string, unknown>>;
type Handler = (session: RepoSession, snap: Snapshot, args: Args) => string | Promise<string>;

const str = (description: string) => ({ type: "string", description });
const num = (description: string) => ({ type: "integer", description, minimum: 1, maximum: 100 });

function schema(props: Record<string, unknown>, required: string[]) {
  return { type: "object", properties: props, required, additionalProperties: false };
}

const PATH = str("Repository-relative file path, e.g. src/main.ts");

const TOOLS: readonly (ToolSpec & { readonly run: Handler })[] = [
  {
    name: "search",
    description:
      "Ranked search over files and definitions (names, signatures, doc comments) by words or identifiers.",
    inputSchema: schema(
      { query: str("Words or identifiers"), limit: num("Max results (default 15)") },
      ["query"],
    ),
    run: (_s, snap, a) => searchText(snap, String(a.query), intArg(a.limit, 15)),
  },
  {
    name: "definition",
    description: "Where a name is defined: file, line, kind, signature. Accepts Class.method.",
    inputSchema: schema({ name: str("Function, class, type or Class.method") }, ["name"]),
    run: (_s, snap, a) => definitionText(snap, String(a.name)),
  },
  {
    name: "references",
    description:
      "Every use of a name with file, line and the enclosing definition (callers of a function).",
    inputSchema: schema({ name: str("Identifier") }, ["name"]),
    run: (s, snap, a) => referencesText(s, snap, String(a.name)),
  },
  {
    name: "outline",
    description: "A file's definitions with line numbers, without reading the whole file.",
    inputSchema: schema({ path: PATH }, ["path"]),
    run: (_s, snap, a) => outlineText(snap, String(a.path)),
  },
  {
    name: "dependencies",
    description: "What a file imports, which files import it, and whose names it uses.",
    inputSchema: schema({ path: PATH }, ["path"]),
    run: (_s, snap, a) => dependenciesText(snap, String(a.path)),
  },
  {
    name: "tests_for",
    description: "Tests that exercise a source file (or, for a test file, the sources it covers).",
    inputSchema: schema({ path: PATH }, ["path"]),
    run: (_s, snap, a) => testsText(snap, String(a.path)),
  },
  {
    name: "owners",
    description: "CODEOWNERS entry and recent authors for a file.",
    inputSchema: schema({ path: PATH }, ["path"]),
    run: (_s, snap, a) => ownersText(snap, String(a.path)),
  },
  {
    name: "repo_map",
    description:
      "Ranked map of files with their public definitions, focused on a task when one is given.",
    inputSchema: schema(
      { focus: str("Optional task text to rank toward"), budget: num("Size in hundreds of chars") },
      [],
    ),
    run: (_s, snap, a) => repoMapText(snap, String(a.focus ?? ""), intArg(a.budget, 40) * 100),
  },
  {
    name: "localize",
    description: "Files and definitions most likely to need changes for a task, with the reasons.",
    inputSchema: schema({ task: str("Issue or task text"), limit: num("Max files (default 10)") }, [
      "task",
    ]),
    run: (_s, snap, a) => localizeText(snap, String(a.task), intArg(a.limit, 10)),
  },
];

function intArg(v: unknown, fallback: number): number {
  const n = typeof v === "number" ? v : Number.parseInt(String(v ?? ""), 10);
  return Number.isFinite(n) && n >= 1 ? Math.min(Math.floor(n), 100) : fallback;
}

export function toolSpecs(): readonly ToolSpec[] {
  return TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));
}

export interface ToolOutcome {
  readonly text: string;
  readonly isError: boolean;
}

function missingArg(name: string, args: Args): string | undefined {
  const spec = TOOLS.find((t) => t.name === name);
  const required = (spec?.inputSchema.required ?? []) as readonly string[];
  return required.find((r) => typeof args[r] !== "string" || String(args[r]).trim().length === 0);
}

/** Runs one tool against the current (freshly refreshed) model. Never throws: errors come back as text. */
export async function callTool(
  session: RepoSession,
  name: string,
  args: Args,
): Promise<ToolOutcome> {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) return { text: `Unknown tool: ${name}`, isError: true };
  const missing = missingArg(name, args);
  if (missing) return { text: `Missing argument: ${missing}`, isError: true };
  const snap = await session.current();
  if (!snap.ok)
    return { text: `Repository model unavailable: ${snap.error.message}`, isError: true };
  try {
    return { text: await tool.run(session, snap.value, args), isError: false };
  } catch (e) {
    return { text: `Tool failed: ${e instanceof Error ? e.message : String(e)}`, isError: true };
  }
}
