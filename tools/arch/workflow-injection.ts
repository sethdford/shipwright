import { Glob } from "bun";
import { parse } from "yaml";

const BASELINE = "tools/arch/workflow-injection-baseline.json";
const SCAN_GLOBS = [".github/workflows/*.{yml,yaml}", ".github/actions/**/action.{yml,yaml}"];
// Known gap: `inputs.*` is deliberately not flagged (callers may be trusted).
const UNTRUSTED =
  /\$\{\{\s*(?:github\.event\.(?:issue|pull_request|comment|review|discussion|head_commit|commits|pages)\b[^}]*|github\.event\.workflow_run\.(?:head_branch|head_commit|display_title)\b[^}]*|github\.head_ref|(?:steps|needs)\.[\w-]+\.outputs\.[\w-]+)\s*\}\}/g;

interface Step {
  name?: string;
  uses?: string;
  run?: string;
  with?: { script?: unknown };
}
interface Workflow {
  jobs?: Record<string, { steps?: Step[] }>;
  runs?: { steps?: Step[] };
}

/** Text of a step that is executed as shell (`run`) or JS (`github-script`). */
function executable(step: Step): string {
  const parts: unknown[] = [step.run];
  if (typeof step.uses === "string" && step.uses.startsWith("actions/github-script")) {
    parts.push(step.with?.script);
  }
  return parts.filter((p): p is string => typeof p === "string").join("\n");
}

export function findInjections(file: string, text: string): string[] {
  let doc: unknown;
  try {
    doc = parse(text);
  } catch {
    return [`${file}: unparseable YAML`];
  }
  const wf = (doc !== null && typeof doc === "object" ? doc : {}) as Workflow;
  const groups: [string, Step[]][] = Object.entries(wf.jobs ?? {}).map(([job, def]) => [
    job,
    def?.steps ?? [],
  ]);
  if (Array.isArray(wf.runs?.steps)) groups.push(["action", wf.runs.steps]);
  return groups.flatMap(([job, steps]) =>
    steps.flatMap((step, i) =>
      [...executable(step).matchAll(UNTRUSTED)].map(
        (m) => `${file}:${job}:${step.name ?? `step-${i}`}:${m[0]}`,
      ),
    ),
  );
}

/** Scan workflows and composite actions under `cwd`. `dot: true` is required: `.github` is a dot-dir. */
export async function scan(cwd = "."): Promise<string[]> {
  const found: string[] = [];
  for (const pattern of SCAN_GLOBS) {
    for await (const file of new Glob(pattern).scan({ cwd, dot: true })) {
      found.push(...findInjections(file, await Bun.file(`${cwd}/${file}`).text()));
    }
  }
  return found;
}

if (import.meta.main) {
  const found = await scan();
  if (Bun.argv.includes("--write-baseline")) {
    await Bun.write(BASELINE, `${JSON.stringify([...new Set(found)].sort(), null, 2)}\n`);
    process.exit(0);
  }
  const allowed = new Set((await Bun.file(BASELINE).json()) as string[]);
  const fresh = found.filter((f) => !allowed.has(f));
  for (const f of fresh) {
    console.error(
      `WF ${f} — pass this value through the step's env: block and use "$VAR" in the script.`,
    );
  }
  process.exit(fresh.length ? 1 : 0);
}
