import type { LabelConfig, VerifierMode } from "../../contexts/quality";

export type Format = "text" | "json";

export interface ScoreFlags {
  base: string;
  title: string;
  bodyFile: string | null;
  tests: boolean | null;
  cross: number | null;
  rubric: number | null;
  mode: VerifierMode;
  critic: boolean;
  criticModel: string;
  criticBudget: number;
  format: Format;
}

export interface TrainFlags {
  days: number;
  labels: Partial<LabelConfig>;
  dryRun: boolean;
  format: Format;
}

const MODEL = /^[A-Za-z0-9._:[\]-]{1,80}$/;
const NUMBERS = /^[1-9][0-9]{0,6}(,[1-9][0-9]{0,6})*$/;

const unit = (v: string): number | null => (/^(0(\.\d+)?|1(\.0+)?)$/.test(v) ? Number(v) : null);

export function modeOf(v: string | undefined): VerifierMode | null {
  const m = (v ?? "").trim().toLowerCase();
  if (m === "") return "advisory";
  return m === "off" || m === "advisory" || m === "enforce" ? m : null;
}

const format = (v: string): Format | string =>
  v === "text" || v === "json" ? v : "--format must be text or json";

type Patch<T> = Partial<T> | string;

const SCORE: Record<string, (v: string) => Patch<ScoreFlags>> = {
  "--base": (v) => ({ base: v }),
  "--title": (v) => ({ title: v }),
  "--body-file": (v) => ({ bodyFile: v }),
  "--tests": (v) =>
    v === "pass"
      ? { tests: true }
      : v === "fail"
        ? { tests: false }
        : v === "unknown"
          ? { tests: null }
          : "--tests must be pass, fail or unknown",
  "--cross": (v) => (unit(v) === null ? "--cross must be between 0 and 1" : { cross: unit(v) }),
  "--rubric": (v) => (unit(v) === null ? "--rubric must be between 0 and 1" : { rubric: unit(v) }),
  "--mode": (v) => {
    const m = modeOf(v);
    return m === null ? "--mode must be off, advisory or enforce" : { mode: m };
  },
  "--critic-model": (v) =>
    MODEL.test(v) ? { criticModel: v, critic: true } : "--critic-model is not a model name",
  "--critic-budget": (v) =>
    /^\d{1,3}(\.\d{1,2})?$/.test(v) && Number(v) > 0
      ? { criticBudget: Number(v) }
      : "--critic-budget must be a positive amount in USD",
  "--format": (v) => {
    const f = format(v);
    return f === "text" || f === "json" ? { format: f } : f;
  },
};

function parse<T>(
  args: readonly string[],
  table: Record<string, (v: string) => Patch<T>>,
  bools: Record<string, Partial<T>>,
  start: T,
): T | string {
  let flags = start;
  for (let i = 0; i < args.length; i++) {
    const flag = args[i] as string;
    const b = bools[flag];
    if (b) {
      flags = { ...flags, ...b };
      continue;
    }
    const apply = table[flag];
    if (!apply) return `unknown option: ${flag}`;
    const value = args[++i];
    if (value === undefined) return `${flag} needs a value`;
    const patch = apply(value);
    if (typeof patch === "string") return patch;
    flags = { ...flags, ...patch };
  }
  return flags;
}

export function parseScoreFlags(
  args: readonly string[],
  envMode: string | undefined,
): ScoreFlags | string {
  const mode = modeOf(envMode);
  if (mode === null) return "SHIPWRIGHT_VERIFIER must be off, advisory or enforce";
  return parse<ScoreFlags>(
    args,
    SCORE,
    { "--critic": { critic: true } },
    {
      base: "origin/main",
      title: "",
      bodyFile: null,
      tests: null,
      cross: null,
      rubric: null,
      mode,
      critic: false,
      criticModel: "sonnet",
      criticBudget: 0.5,
      format: "text",
    },
  );
}

const numbers = (v: string, flag: string): number[] | string =>
  NUMBERS.test(v) ? v.split(",").map(Number) : `${flag} must be PR numbers separated by commas`;

function trainOption(flag: string, v: string, f: TrainFlags): string | null {
  if (flag === "--days") {
    if (!/^[1-9][0-9]{0,3}$/.test(v) || Number(v) > 3650) return "--days must be 1 to 3650";
    f.days = Number(v);
  } else if (flag === "--human-weight") {
    const w = unit(v);
    if (w === null) return "--human-weight must be between 0 and 1";
    f.labels = { ...f.labels, humanWeight: w };
  } else if (flag === "--agent" || flag === "--exclude") {
    const list = numbers(v, flag);
    if (typeof list === "string") return list;
    const key = flag === "--agent" ? "agentNumbers" : "excludeNumbers";
    f.labels = { ...f.labels, [key]: [...(f.labels[key] ?? []), ...list] };
  } else if (flag === "--format") {
    const out = format(v);
    if (out !== "text" && out !== "json") return out;
    f.format = out;
  } else {
    return `unknown option: ${flag}`;
  }
  return null;
}

export function parseTrainFlags(args: readonly string[]): TrainFlags | string {
  const f: TrainFlags = { days: 365, labels: {}, dryRun: false, format: "text" };
  for (let i = 0; i < args.length; i++) {
    const flag = args[i] as string;
    if (flag === "--dry-run") {
      f.dryRun = true;
      continue;
    }
    const value = args[++i];
    if (value === undefined) return `${flag} needs a value`;
    const problem = trainOption(flag, value, f);
    if (problem !== null) return problem;
  }
  return f;
}
