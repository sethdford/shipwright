import { Glob } from "bun";
import { parse } from "yaml";

/**
 * Workflow fail-closed rule (ADR-0007). Retry counting and gating must stop on any read error:
 * - `bot-comments.sh` / `retry-state.sh` / `pipeline-active.sh` output is never piped, `||`-defaulted or stripped of
 *   stderr, including across the lines of a multi-line `$( … )`; capture it with
 *   `if ! X=$(…); then …; exit 1; fi`.
 * - `gates check` never runs with `--no-github`, `||`, a pipe or a discarded stderr.
 * - Neither is captured by `local|export|readonly|declare X=$(…)` (the exit status is lost).
 * - A step that invokes either runs under `shell: bash` (`-eo pipefail`) and never `set +e`.
 * - No `continue-on-error` on the safety-gates action, a job using it, or a step invoking either.
 * Workflow and action YAML is checked on the parsed `run:` text (folded `>` scalars joined);
 * other files under `.github/actions` line by line.
 */
const SCAN_GLOBS = [".github/workflows/**/*", ".github/actions/**/*"];
const INVOKE = /\b(?:bot-comments|retry-state|pipeline-active)\.sh\b|\bgates\s+check\b/g;
const SWALLOWED = /\||[2&]>\s*\/dev\/null/;
const NO_GITHUB = /--no-github/;
const MASKED = /\b(?:local|export|readonly|declare|typeset)\s+(?:-\w+\s+)*[A-Za-z_]\w*="?$/;
const ERREXIT_OFF = /\bset\s+(?:\+[A-Za-z]*e[A-Za-z]*\b|\+o\s+(?:errexit|pipefail)\b)/;
const SAFETY_GATES_ACTION = /(?:^|\/)\.github\/actions\/safety-gates\/?$/;

interface Step {
  name?: string;
  run?: unknown;
  shell?: unknown;
  uses?: unknown;
  "continue-on-error"?: unknown;
}
interface Defaults {
  defaults?: { run?: { shell?: unknown } };
}
interface Job extends Defaults {
  steps?: Step[];
  "continue-on-error"?: unknown;
}
interface Doc extends Defaults {
  jobs?: Record<string, Job | null>;
  runs?: { steps?: Step[] };
}

/** Continuations joined and full-line comments blanked; offsets stay line-aligned. */
function normalize(script: string): string {
  return script
    .replace(/\\\r?\n/g, "  ")
    .split("\n")
    .map((l) => (/^\s*#/.test(l) ? "" : l))
    .join("\n");
}

/** Start of the unmatched `$(` enclosing index `at`, or -1. */
function enclosingStart(s: string, at: number): number {
  let depth = 0;
  for (let i = at - 1; i >= 0; i--) {
    if (s[i] === ")") depth++;
    else if (s[i] === "(") {
      if (depth === 0) return s[i - 1] === "$" ? i - 1 : -1;
      depth--;
    }
  }
  return -1;
}

/** Index of the `)` closing the substitution that contains `from`, or the string end. */
function matchingClose(s: string, from: number): number {
  let depth = 0;
  for (let i = from; i < s.length; i++) {
    if (s[i] === "(") depth++;
    else if (s[i] === ")") {
      if (depth === 0) return i;
      depth--;
    }
  }
  return s.length;
}

const lineEnd = (s: string, from: number) => {
  const n = s.indexOf("\n", from);
  return n < 0 ? s.length : n;
};

/** Findings for every marker read or gate check in one script. */
export function scriptFindings(where: string, script: string): string[] {
  const s = normalize(script);
  const found: string[] = [];
  for (const m of s.matchAll(INVOKE)) {
    const at = m.index ?? 0;
    const what = m[0].endsWith(".sh") ? m[0] : "gates check";
    const start = enclosingStart(s, at);
    let tail: string;
    if (start >= 0) {
      const close = matchingClose(s, at);
      tail = s.slice(at, close) + s.slice(close + 1, lineEnd(s, close + 1));
      const prefix = s.slice(s.lastIndexOf("\n", start) + 1, start);
      if (MASKED.test(prefix)) found.push(`${where}: ${what} captured by local/export/readonly`);
    } else {
      tail = s.slice(at, lineEnd(s, at));
    }
    if (SWALLOWED.test(tail) || (what === "gates check" && NO_GITHUB.test(tail))) {
      found.push(`${where}: ${what} output piped, ||-defaulted, stderr discarded or --no-github`);
    }
  }
  if (found.length === 0 && s.match(INVOKE) && ERREXIT_OFF.test(s)) {
    found.push(`${where}: set +e in a step that reads markers or checks gates`);
  }
  return found;
}

const continues = (v: unknown) => v !== undefined && v !== false && v !== "false";
const usesGates = (st: Step) => typeof st.uses === "string" && SAFETY_GATES_ACTION.test(st.uses);
const invokes = (st: Step) => typeof st.run === "string" && new RegExp(INVOKE).test(st.run);

function stepFindings(where: string, st: Step, fallbackShell: unknown): string[] {
  const found: string[] = [];
  if (typeof st.run === "string") found.push(...scriptFindings(where, st.run));
  if (invokes(st) && (st.shell ?? fallbackShell) !== "bash") {
    found.push(
      `${where}: invokes gates check / bot-comments.sh / retry-state.sh without shell: bash`,
    );
  }
  if ((invokes(st) || usesGates(st)) && continues(st["continue-on-error"])) {
    found.push(`${where}: continue-on-error on a safety-gates / marker step`);
  }
  return found;
}

function docFindings(file: string, doc: Doc): string[] {
  const groups: [string, Job][] = Object.entries(doc.jobs ?? {}).map(([j, d]) => [j, d ?? {}]);
  if (Array.isArray(doc.runs?.steps)) groups.push(["action", { steps: doc.runs.steps }]);
  return groups.flatMap(([job, def]) => {
    const steps = Array.isArray(def.steps) ? def.steps : [];
    const shell = def.defaults?.run?.shell ?? doc.defaults?.run?.shell;
    const found = steps.flatMap((st, i) =>
      stepFindings(`${file}:${job}:${st?.name ?? `step-${i}`}`, st ?? {}, shell),
    );
    if (
      continues(def["continue-on-error"]) &&
      steps.some((st) => st && (usesGates(st) || invokes(st)))
    ) {
      found.push(`${file}:${job}: continue-on-error on a job that uses the safety gates`);
    }
    return found;
  });
}

export function findFailOpen(file: string, text: string): string[] {
  if (!/\.ya?ml$/.test(file)) {
    return text.split("\n").flatMap((line, i) => scriptFindings(`${file}:${i + 1}`, line));
  }
  let doc: unknown;
  try {
    doc = parse(text);
  } catch {
    return [`${file}: unparseable YAML`];
  }
  return docFindings(file, (doc !== null && typeof doc === "object" ? doc : {}) as Doc);
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
      `WF-FAIL-CLOSED ${f} — use: if ! X=$(scripts/ci/bot-comments.sh "$N"); then echo "::error::…"; exit 1; fi; never --no-github, set +e or continue-on-error on Actions (ADR-0007).`,
    );
  }
  process.exit(found.length ? 1 : 0);
}
