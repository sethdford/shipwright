import { TOURNAMENT_LIMITS, type TournamentRequest } from "../../contexts/delivery";

export interface TournamentFlags {
  readonly goalFile: string;
  readonly format: "text" | "json" | "markdown";
  readonly request: Omit<TournamentRequest, "goal">;
}

type Mutable = {
  goalFile: string | null;
  format: "text" | "json" | "markdown";
  attempts: number;
  budgetUsd: number;
  model: string;
  judgeModel: string | null;
  testCommand: string | null;
  setupCommand: string | null;
  maxTurns: number;
  buildTimeoutMs: number;
  testTimeoutMs: number;
  adopt: boolean;
};

const MODEL = /^[A-Za-z0-9._:[\]-]{1,80}$/;
const MINUTE = 60_000;

function int(value: string, lo: number, hi: number): number | null {
  if (!/^[0-9]{1,4}$/.test(value)) return null;
  const n = Number(value);
  return n >= lo && n <= hi ? n : null;
}

function usd(value: string): number | null {
  if (!/^[0-9]{1,3}(\.[0-9]{1,2})?$/.test(value)) return null;
  const n = Number(value);
  return n >= 1 && n <= TOURNAMENT_LIMITS.maxBudgetUsd ? n : null;
}

const command = (v: string): string | null => (v.trim() === "" || v.length > 2000 ? null : v);
const model = (v: string): string | null => (MODEL.test(v) ? v : null);

type Patch = Partial<Mutable> | string;

const bounded = (
  v: string,
  lo: number,
  hi: number,
  flag: string,
  set: (n: number) => Partial<Mutable>,
): Patch => {
  const n = int(v, lo, hi);
  return n === null ? `${flag} must be ${lo} to ${hi}` : set(n);
};

function asCommand(v: string, flag: string, key: "testCommand" | "setupCommand"): Patch {
  const c = command(v);
  return c === null ? `${flag} must be a non-empty command` : { [key]: c };
}

function asModel(v: string, flag: string, key: "model" | "judgeModel"): Patch {
  const m = model(v);
  return m === null ? `${flag} is not a model name` : { [key]: m };
}

function asFormat(v: string): Patch {
  if (v === "text" || v === "json" || v === "markdown") return { format: v };
  return "--format must be text, json or markdown";
}

/** Each option: the fields its value sets, or a usage message. */
const OPTIONS: Record<string, (v: string) => Patch> = {
  "--goal-file": (v) => ({ goalFile: v }),
  "--test-cmd": (v) => asCommand(v, "--test-cmd", "testCommand"),
  "--setup-cmd": (v) => asCommand(v, "--setup-cmd", "setupCommand"),
  "--attempts": (v) =>
    bounded(v, TOURNAMENT_LIMITS.minAttempts, TOURNAMENT_LIMITS.maxAttempts, "--attempts", (n) => ({
      attempts: n,
    })),
  "--budget-usd": (v) => {
    const n = usd(v);
    return n === null
      ? `--budget-usd must be 1 to ${TOURNAMENT_LIMITS.maxBudgetUsd}`
      : { budgetUsd: n };
  },
  "--model": (v) => asModel(v, "--model", "model"),
  "--judge-model": (v) => asModel(v, "--judge-model", "judgeModel"),
  "--max-turns": (v) => bounded(v, 5, 500, "--max-turns", (n) => ({ maxTurns: n })),
  "--build-timeout-min": (v) =>
    bounded(v, 1, 240, "--build-timeout-min", (n) => ({ buildTimeoutMs: n * MINUTE })),
  "--test-timeout-min": (v) =>
    bounded(v, 1, 120, "--test-timeout-min", (n) => ({ testTimeoutMs: n * MINUTE })),
  "--format": asFormat,
};

const DEFAULTS = (): Mutable => ({
  goalFile: null,
  format: "text",
  attempts: 3,
  budgetUsd: 15,
  model: "opus",
  judgeModel: null,
  testCommand: null,
  setupCommand: null,
  maxTurns: 60,
  buildTimeoutMs: 45 * MINUTE,
  testTimeoutMs: 15 * MINUTE,
  adopt: true,
});

function read(args: readonly string[]): Mutable | string {
  let f = DEFAULTS();
  for (let i = 0; i < args.length; i++) {
    const flag = args[i] as string;
    if (flag === "--no-adopt") {
      f = { ...f, adopt: false };
      continue;
    }
    const apply = OPTIONS[flag];
    if (!apply) return `unknown option: ${flag}`;
    const value = args[++i];
    if (value === undefined) return `${flag} needs a value`;
    const patch = apply(value);
    if (typeof patch === "string") return patch;
    f = { ...f, ...patch };
  }
  return f;
}

export function parseTournamentFlags(args: readonly string[]): TournamentFlags | string {
  const f = read(args);
  if (typeof f === "string") return f;
  if (f.goalFile === null) return "--goal-file is required";
  if (f.testCommand === null) return "--test-cmd is required";
  const { goalFile, format, judgeModel, testCommand, ...rest } = f;
  return {
    goalFile,
    format,
    request: { ...rest, testCommand, judgeModel: judgeModel ?? rest.model },
  };
}
