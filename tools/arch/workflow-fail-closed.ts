import { Glob } from "bun";
import { parse } from "yaml";

/**
 * Workflow fail-closed rule (ADR-0007). Retry counting and gating must stop on any read error:
 * - `bot-comments.sh` / `retry-state.sh` output is never piped, `||`-defaulted or stripped of
 *   stderr on the same (logical) line; capture it with `if ! X=$(…); then …; exit 1; fi`.
 * - `gates check` never runs with `--no-github`, `||` or a discarded stderr.
 * - A step that invokes either runs under `shell: bash` (`-eo pipefail`).
 */
const SCAN_GLOBS = [".github/workflows/**/*", ".github/actions/**/*"];
const MARKER_READ = /\b(?:bot-comments|retry-state)\.sh\b(.*)$/;
const READ_SWALLOWED = /\||[2&]>\s*\/dev\/null/;
const GATES = /\bgates\s+check\b/;
const GATES_OPEN = /--no-github|\|\||[2&]>\s*\/dev\/null/;
const INVOKES = /\b(?:bot-comments|retry-state)\.sh\b|\bgates\s+check\b/;

interface Step {
  name?: string;
  run?: unknown;
  shell?: unknown;
}
interface Defaults {
  defaults?: { run?: { shell?: unknown } };
}
interface Doc extends Defaults {
  jobs?: Record<string, (Defaults & { steps?: Step[] }) | null>;
  runs?: { steps?: Step[] };
}

/** Lines with backslash continuations joined, each tagged with its first line number. */
function logicalLines(text: string): [number, string][] {
  const out: [number, string][] = [];
  let start = 0;
  let buf = "";
  text.split("\n").forEach((line, i) => {
    if (buf === "") start = i + 1;
    buf += line;
    if (line.endsWith("\\")) buf = `${buf.slice(0, -1)} `;
    else {
      out.push([start, buf]);
      buf = "";
    }
  });
  if (buf !== "") out.push([start, buf]);
  return out;
}

function lineFindings(file: string, text: string): string[] {
  const found: string[] = [];
  for (const [n, line] of logicalLines(text)) {
    const after = line.match(MARKER_READ)?.[1];
    if (after !== undefined && READ_SWALLOWED.test(after)) {
      found.push(
        `${file}:${n}: bot-comments.sh/retry-state.sh output piped, ||-defaulted or stderr discarded`,
      );
    }
    if (GATES.test(line) && GATES_OPEN.test(line)) {
      found.push(`${file}:${n}: gates check with --no-github, || or 2>/dev/null`);
    }
  }
  return found;
}

function shellFindings(file: string, doc: Doc): string[] {
  const groups: [string, Step[], unknown][] = Object.entries(doc.jobs ?? {}).map(([job, def]) => [
    job,
    def?.steps ?? [],
    def?.defaults?.run?.shell ?? doc.defaults?.run?.shell,
  ]);
  if (Array.isArray(doc.runs?.steps)) groups.push(["action", doc.runs.steps, undefined]);
  return groups.flatMap(([job, steps, fallback]) =>
    steps.flatMap((step, i) => {
      if (typeof step?.run !== "string" || !INVOKES.test(step.run)) return [];
      if ((step.shell ?? fallback) === "bash") return [];
      return [
        `${file}:${job}:${step.name ?? `step-${i}`}: invokes gates check / bot-comments.sh / retry-state.sh without shell: bash`,
      ];
    }),
  );
}

export function findFailOpen(file: string, text: string): string[] {
  const found = lineFindings(file, text);
  if (!/\.ya?ml$/.test(file)) return found;
  let doc: unknown;
  try {
    doc = parse(text);
  } catch {
    return [...found, `${file}: unparseable YAML`];
  }
  const typed = (doc !== null && typeof doc === "object" ? doc : {}) as Doc;
  return [...found, ...shellFindings(file, typed)];
}

/** Scan every file under `.github/workflows` and `.github/actions` (dot-dir: `dot: true`). */
export async function scan(cwd = "."): Promise<string[]> {
  const found: string[] = [];
  for (const pattern of SCAN_GLOBS) {
    for await (const file of new Glob(pattern).scan({ cwd, dot: true })) {
      found.push(...findFailOpen(file, await Bun.file(`${cwd}/${file}`).text()));
    }
  }
  return found;
}

if (import.meta.main) {
  const found = await scan();
  for (const f of found) {
    console.error(
      `WF-FAIL-CLOSED ${f} — use: if ! X=$(scripts/ci/bot-comments.sh "$N"); then echo "::error::…"; exit 1; fi; never --no-github on Actions (ADR-0007).`,
    );
  }
  process.exit(found.length ? 1 : 0);
}
