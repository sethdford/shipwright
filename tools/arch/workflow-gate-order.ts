import { parse } from "yaml";

/**
 * Gate ordering and trigger rules for workflows (ADR-0007, the labeled entry point):
 * - A step that runs `.github/actions/safety-gates` with `on-refusal: notice` turns a closed gate
 *   into a successful run. Every step after it in the same job must be conditioned on
 *   `steps.<id>.outputs.allowed == 'true'`, so nothing else runs after a refusal.
 * - `.github/actions/dispatch-pipeline` may only be used in a job that also runs the gates first.
 * - shipwright-pipeline.yml is dispatched only: its `on:` is exactly `workflow_dispatch`. The
 *   ungated `issues` trigger cannot come back silently.
 */

const GATES = /(?:^|\/)\.github\/actions\/safety-gates\/?$/;
const DISPATCH = /(?:^|\/)\.github\/actions\/dispatch-pipeline\/?$/;
const PIPELINE_FILE = /(?:^|\/)shipwright-pipeline\.yml$/;

interface Step {
  id?: unknown;
  name?: unknown;
  if?: unknown;
  uses?: unknown;
  with?: Record<string, unknown> | null;
}
interface Doc {
  on?: unknown;
  jobs?: Record<string, { steps?: unknown } | null>;
}

const usesOf = (st: Step, re: RegExp) => typeof st.uses === "string" && re.test(st.uses);
const label = (st: Step, i: number) => (typeof st.name === "string" ? st.name : `step-${i}`);

function jobSteps(job: { steps?: unknown } | null): Step[] {
  return Array.isArray(job?.steps) ? (job.steps as Step[]).map((s) => s ?? {}) : [];
}

export function gateOrderFindings(file: string, doc: Doc): string[] {
  const found: string[] = [];
  for (const [job, def] of Object.entries(doc.jobs ?? {})) {
    const steps = jobSteps(def);
    steps.forEach((st, i) => {
      if (!usesOf(st, GATES) || st.with?.["on-refusal"] !== "notice") return;
      const where = `${file}:${job}:${label(st, i)}`;
      if (typeof st.id !== "string" || st.id === "") {
        found.push(`${where}: on-refusal: notice needs an id (its allowed output gates the rest)`);
        return;
      }
      const need = `steps.${st.id}.outputs.allowed == 'true'`;
      for (const [j, after] of steps.entries()) {
        if (j <= i) continue;
        const cond = typeof after.if === "string" ? after.if : "";
        if (!cond.includes(need)) {
          found.push(
            `${file}:${job}:${label(after, j)}: runs after a notice-mode gate without \`${need}\``,
          );
        }
      }
    });
    steps.forEach((st, i) => {
      if (!usesOf(st, DISPATCH)) return;
      const gated = steps.slice(0, i).some((s) => usesOf(s, GATES));
      if (!gated)
        found.push(
          `${file}:${job}:${label(st, i)}: dispatch-pipeline needs the gates earlier in the job`,
        );
    });
  }
  return found;
}

export function triggerFindings(file: string, doc: Doc): string[] {
  if (!PIPELINE_FILE.test(file)) return [];
  const on = doc.on;
  const keys = on !== null && typeof on === "object" && !Array.isArray(on) ? Object.keys(on) : null;
  const ok = keys !== null && keys.length === 1 && keys[0] === "workflow_dispatch";
  return ok
    ? []
    : [
        `${file}: on: must be exactly workflow_dispatch (the pipeline is dispatched, never a labeled entry point)`,
      ];
}

export function findGateOrder(file: string, text: string): string[] {
  let doc: unknown;
  try {
    doc = parse(text);
  } catch {
    return [`${file}: unparseable YAML`];
  }
  const d = (doc !== null && typeof doc === "object" ? doc : {}) as Doc;
  return [...gateOrderFindings(file, d), ...triggerFindings(file, d)];
}
