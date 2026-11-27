import type { CliRun, Flow, ProofConfig } from "./config";
import { type AppProfile, portArgs } from "./detect";
import { changedRoutes, routeFlows } from "./routes";

/**
 * What the proof stage will do for one change (ADR-0019): which app to start and how, which
 * flows to drive, which CLI runs to record. The repository's proof.json wins over detection,
 * field by field.
 */

export interface WebPlan {
  readonly start: readonly string[];
  readonly port: number;
  /** Fixed URL from proof.json, else null: the launcher reads it from the app's output or PORT. */
  readonly url: string | null;
  readonly readyPath: string;
  readonly readyTimeoutMs: number;
  readonly allowHosts: readonly string[];
  readonly flows: readonly Flow[];
  readonly source: "config" | "detected";
}

export interface ProofPlan {
  readonly web: WebPlan | null;
  readonly cli: readonly CliRun[];
  /** Why nothing (or less than expected) will run; shown in the PR section. */
  readonly notes: readonly string[];
  /** Problems that fail the proof whatever runs: a broken proof.json, or one this change turned off. */
  readonly problems: readonly string[];
}

export interface PlanInput {
  readonly config: ProofConfig;
  readonly profile: AppProfile;
  readonly changed: readonly string[];
  /** A free port the adapter picked. */
  readonly port: number;
  /** Why proof.json could not be used (it is then ignored and the app detected). */
  readonly configProblems?: readonly string[];
}

export const CONFIG_FILE = ".shipwright/proof.json";

const DEFAULT_READY_MS = 120_000;

function webPlan(input: PlanInput): WebPlan | null {
  const cfg = input.config.web;
  const detected = input.profile.web;
  if (cfg === undefined && detected === null) return null;
  const port = cfg?.port ?? input.port;
  const start =
    cfg?.start ??
    (detected
      ? [...detected.start, ...passThrough(detected.start, portArgs(detected.framework, port))]
      : null);
  if (start === null) return null;
  const framework = detected?.framework ?? "other";
  const flows = cfg?.flows?.length
    ? cfg.flows
    : routeFlows(changedRoutes(framework, input.changed));
  return {
    start,
    port,
    url: cfg?.url ?? null,
    readyPath: cfg?.readyPath ?? "/",
    readyTimeoutMs: (cfg?.readyTimeoutSec ?? 0) * 1000 || DEFAULT_READY_MS,
    allowHosts: cfg?.allowHosts ?? [],
    flows,
    source: cfg?.start ? "config" : "detected",
  };
}

/** npm needs `--` before flags meant for the script (`npm run dev -- --port N`); bun, pnpm and yarn pass them on as is. */
function passThrough(start: readonly string[], args: readonly string[]): readonly string[] {
  if (args.length === 0) return [];
  return start[0] === "npm" ? ["--", ...args] : args;
}

function cliRuns(input: PlanInput): readonly CliRun[] {
  if (input.config.cli !== undefined) return input.config.cli.runs;
  const cli = input.profile.cli;
  if (cli === null) return [];
  return [{ name: `${cli.name} --help`, argv: [...cli.argv, "--help"], expectExit: 0 }];
}

/**
 * The agent writes the change, so it could also write a proof.json that hides a broken app: a
 * proof.json this change made unreadable or turned off is a failure, not a skip.
 */
function configProblems(input: PlanInput): string[] {
  const broken = (input.configProblems ?? []).map((p) => `${CONFIG_FILE}: ${p}`);
  const turnedOff = !input.config.enabled && input.changed.includes(CONFIG_FILE);
  return turnedOff ? [...broken, `this change turned the proof off in ${CONFIG_FILE}`] : broken;
}

export function planProof(input: PlanInput): ProofPlan {
  const problems = configProblems(input);
  if (!input.config.enabled) {
    return { web: null, cli: [], notes: [`proof is turned off in ${CONFIG_FILE}`], problems };
  }
  const web = webPlan(input);
  const cli = cliRuns(input);
  const notes: string[] = [];
  if (web === null && cli.length === 0) {
    notes.push(
      "no web app or CLI was detected; add .shipwright/proof.json to say how to run this app",
    );
  }
  return { web, cli, notes, problems };
}
