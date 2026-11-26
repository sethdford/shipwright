import { accept, isArgv, isRecord, type Parsed, reject } from "./parsed";

export const ARM_KINDS = ["claude-code", "shipwright", "command"] as const;
export type ArmKind = (typeof ARM_KINDS)[number];

/**
 * One contestant. `claude-code` is bare `claude -p` with the same model and the same permission
 * policy Shipwright's agents get; `shipwright` is the full local pipeline with `attempts`
 * parallel tries (tournament mode when > 1); `command` runs any other agent from an argv
 * template whose tokens may contain {workdir}, {problem_file} and {model}.
 */
export interface BenchArm {
  readonly id: string;
  readonly label: string;
  readonly kind: ArmKind;
  readonly model: string;
  readonly attempts: number;
  readonly timeoutMin: number;
  /** Expected spend per run, used only by `bench plan` and the budget stop. */
  readonly estimateUsd: number;
  readonly argv: readonly string[] | null;
  /** Extra environment for the arm (SHIPWRIGHT_* and PIPELINE_* names only), e.g. a lesson trial. */
  readonly env: Readonly<Record<string, string>>;
}

const ARM_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._:/[\]-]{0,79}$/;
export const PLACEHOLDERS = ["{workdir}", "{problem_file}", "{model}"] as const;

function int(v: unknown, fallback: number, lo: number, hi: number): number | null {
  if (v === undefined) return fallback;
  return typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi ? v : null;
}

type Numbers = Pick<BenchArm, "attempts" | "timeoutMin" | "estimateUsd">;

function parseNumbers(a: Record<string, unknown>, kind: ArmKind, at: string): Parsed<Numbers> {
  const attempts = int(a.attempts, 1, 1, 5);
  if (attempts === null) return reject(`${at}: attempts must be 1 to 5`);
  if (attempts > 1 && kind !== "shipwright") return reject(`${at}: only shipwright takes attempts`);
  const timeoutMin = int(a.timeoutMin, 60, 1, 600);
  if (timeoutMin === null) return reject(`${at}: timeoutMin must be 1 to 600`);
  const est = a.estimateUsd;
  if (typeof est !== "number" || !Number.isFinite(est) || est < 0)
    return reject(`${at}: estimateUsd must be a non-negative number`);
  return accept({ attempts, timeoutMin, estimateUsd: est });
}

function parseArgv(
  a: Record<string, unknown>,
  kind: ArmKind,
  at: string,
): Parsed<readonly string[] | null> {
  if (kind !== "command") {
    return a.argv === undefined ? accept(null) : reject(`${at}: only command arms take argv`);
  }
  if (!isArgv(a.argv)) return reject(`${at}: a command arm needs an argv array`);
  return accept(a.argv);
}

const ENV_NAME = /^(SHIPWRIGHT|PIPELINE)_[A-Z0-9_]{1,60}$/;

function parseEnv(
  a: Record<string, unknown>,
  at: string,
): Parsed<Readonly<Record<string, string>>> {
  if (a.env === undefined) return accept({});
  if (!isRecord(a.env)) return reject(`${at}: env must be an object`);
  const env: Record<string, string> = {};
  for (const [name, value] of Object.entries(a.env)) {
    if (!ENV_NAME.test(name))
      return reject(`${at}: env ${name} must be SHIPWRIGHT_* or PIPELINE_*`);
    if (typeof value !== "string" || value.length > 1000)
      return reject(`${at}: env ${name} must be a string`);
    env[name] = value;
  }
  return accept(env);
}

function parseArm(item: unknown, i: number): Parsed<BenchArm> {
  if (!isRecord(item)) return reject(`arm ${i} is not an object`);
  const id = item.id;
  if (typeof id !== "string" || !ARM_ID.test(id))
    return reject(`arm ${i}: id must match ${ARM_ID}`);
  const at = `arm ${id}`;
  const kind = item.kind as ArmKind;
  if (!ARM_KINDS.includes(kind))
    return reject(`${at}: kind must be one of ${ARM_KINDS.join(", ")}`);
  const model = item.model;
  if (typeof model !== "string" || !MODEL.test(model)) return reject(`${at}: model is required`);
  const label = typeof item.label === "string" && item.label.length > 0 ? item.label : id;
  const nums = parseNumbers(item, kind, at);
  if (!nums.ok) return nums;
  const argv = parseArgv(item, kind, at);
  if (!argv.ok) return argv;
  const env = parseEnv(item, at);
  if (!env.ok) return env;
  return accept({ id, label, kind, model, ...nums.value, argv: argv.value, env: env.value });
}

/** Validates an arms file `{ baseline, arms: [...] }`; `baseline` names the arm others are compared to. */
export function parseArms(
  value: unknown,
): Parsed<{ readonly baseline: string; readonly arms: readonly BenchArm[] }> {
  if (!isRecord(value) || !Array.isArray(value.arms) || value.arms.length === 0)
    return reject("arms file must be { baseline, arms: [...] }");
  const arms: BenchArm[] = [];
  for (const [i, item] of value.arms.entries()) {
    const a = parseArm(item, i);
    if (!a.ok) return a;
    if (arms.some((b) => b.id === a.value.id)) return reject(`arm ${a.value.id} appears twice`);
    arms.push(a.value);
  }
  const baseline = value.baseline;
  if (typeof baseline !== "string" || !arms.some((a) => a.id === baseline))
    return reject("baseline must name one of the arms");
  return accept({ baseline, arms });
}

/** Fills placeholders token by token. Never joins tokens, so no token is ever re-parsed by a shell. */
export function expandArgv(
  template: readonly string[],
  vars: { readonly workdir: string; readonly problemFile: string; readonly model: string },
): readonly string[] {
  return template.map((token) =>
    token
      .replaceAll("{workdir}", vars.workdir)
      .replaceAll("{problem_file}", vars.problemFile)
      .replaceAll("{model}", vars.model),
  );
}
