import { parse } from "yaml";

/**
 * Gate ordering and trigger rules for workflows (ADR-0007, the labeled entry point):
 * - A step that runs `.github/actions/safety-gates` with `on-refusal: notice` turns a closed gate
 *   into a successful run. Every step after it in the same job must be gated (below).
 * - `.github/actions/dispatch-pipeline` may only be used in a job that runs the gates first, and
 *   the step itself is gated on the gates' allowed output.
 * - shipwright-pipeline.yml is dispatched only: its `on:` is exactly `workflow_dispatch`.
 *
 * "Gated" is strict. The step's `if:` must contain the gate's exact term
 * `steps.<id>.outputs.allowed == 'true'` as one of its `&&`-joined terms, and nothing else may
 * weaken it: no `||`, no negation (`!` other than `!=`), and no `always()`, `failure()` or
 * `cancelled()`. A step with no `if:` is not gated.
 */

const GATES = /(?:^|\/)\.github\/actions\/safety-gates\/?$/;
const DISPATCH = /(?:^|\/)\.github\/actions\/dispatch-pipeline\/?$/;
const PIPELINE_FILE = /(?:^|\/)shipwright-pipeline\.yml$/;
const WEAKENERS = /\|\||always\(\)|failure\(\)|cancelled\(\)|!(?!=)/;

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
const condOf = (st: Step) => (typeof st.if === "string" ? st.if.replace(/\s+/g, " ").trim() : "");

/** True only when `if:` is the gate's exact term, joined to the rest with `&&` alone. */
export function isGatedBy(cond: string, gateId: string): boolean {
  if (WEAKENERS.test(cond)) return false;
  const need = `steps.${gateId}.outputs.allowed == 'true'`;
  return cond
    .split("&&")
    .map((t) => t.trim())
    .includes(need);
}

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
      for (const [j, after] of steps.entries()) {
        if (j <= i) continue;
        if (!isGatedBy(condOf(after), st.id)) {
          found.push(
            `${file}:${job}:${label(after, j)}: runs after a notice-mode gate without a strict \`steps.${st.id}.outputs.allowed == 'true'\` term in its if:`,
          );
        }
      }
    });
    steps.forEach((st, i) => {
      if (!usesOf(st, DISPATCH)) return;
      const gate = steps
        .slice(0, i)
        .filter((s) => usesOf(s, GATES))
        .pop();
      if (typeof gate?.id !== "string" || gate.id === "") {
        found.push(
          `${file}:${job}:${label(st, i)}: dispatch-pipeline needs a gates step with an id earlier in the job`,
        );
        return;
      }
      if (!isGatedBy(condOf(st), gate.id)) {
        found.push(
          `${file}:${job}:${label(st, i)}: dispatch-pipeline must be gated by a strict \`steps.${gate.id}.outputs.allowed == 'true'\` term in its if:`,
        );
      }
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
