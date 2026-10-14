import { Glob } from "bun";
import { parse } from "yaml";

const SCAN_GLOBS = [".github/workflows/*.{yml,yaml}", ".github/actions/**/action.{yml,yaml}"];
// Any expression in a script is interpolated before the shell/JS parses it, so none are allowed.
const EXPRESSION = /\$\{\{[\s\S]*?\}\}/g;

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
      [...executable(step).matchAll(EXPRESSION)].map(
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
  for (const f of found) {
    console.error(
      `WF ${f} — pass it via the step's env: block (or a $GITHUB_* built-in) and use "$VAR".`,
    );
  }
  process.exit(found.length ? 1 : 0);
}
