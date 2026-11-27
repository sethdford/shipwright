import { strategyFor } from "../domain/budget";
import type { AdaptiveMode } from "../domain/early-stop";
import type { CommandOutcome, DeliveryPorts, Snapshot, Workspace } from "../ports";
import { BUILDER_TOOLS, builderPrompt } from "./prompts";

export interface TournamentRequest {
  /** The task (issue text and pipeline context). Untrusted: passed to agents only as data. */
  readonly goal: string;
  readonly attempts: number;
  readonly budgetUsd: number;
  readonly model: string;
  readonly judgeModel: string;
  /** Operator-configured commands (pipeline config), run with bash in each workspace. */
  readonly testCommand: string;
  readonly setupCommand: string | null;
  readonly maxTurns: number;
  readonly buildTimeoutMs: number;
  readonly testTimeoutMs: number;
  /** Fast-forward the current branch to the winner. */
  readonly adopt: boolean;
  /** Early stopping: off, shadow (decide and report only) or enforce (needs a trusted verifier). */
  readonly adaptive: AdaptiveMode;
  /** The verifier probability at which an eligible attempt stops the tournament (0.5 to 0.99). */
  readonly stopAt: number;
}

export interface AttemptResult {
  readonly id: string;
  readonly strategy: string;
  readonly workspace: Workspace | null;
  readonly snapshot: Snapshot | null;
  readonly ownTests: CommandOutcome | null;
  readonly costUsd: number;
  readonly turns: number;
  /** Why the attempt has no usable patch, or a note on how the agent stopped. */
  readonly note: string | null;
}

interface Draft {
  id: string;
  strategy: string;
  workspace: Workspace | null;
  snapshot: Snapshot | null;
  ownTests: CommandOutcome | null;
  costUsd: number;
  turns: number;
  note: string | null;
}

async function build(ports: DeliveryPorts, req: TournamentRequest, d: Draft, budgetUsd: number) {
  const ws = d.workspace as Workspace;
  const run = await ports.agent.runTask({
    prompt: builderPrompt(d.strategy, req.testCommand),
    data: req.goal,
    cwd: ws.path,
    model: req.model,
    effort: "high",
    allowedTools: BUILDER_TOOLS,
    maxTurns: req.maxTurns,
    maxBudgetUsd: budgetUsd,
    timeoutMs: req.buildTimeoutMs,
  });
  if (run.ok) {
    d.costUsd += run.value.usage.costUsd;
    d.turns = run.value.turns;
  } else {
    // Partial work after max_turns or budget can still pass the gate, so it is kept and tested.
    d.costUsd += run.error.usage.costUsd;
    d.note = `agent stopped: ${run.error.kind}`;
  }
}

async function prepare(ports: DeliveryPorts, req: TournamentRequest, d: Draft, base: string) {
  const ws = await ports.workspaces.create(d.id, base);
  if (!ws.ok) {
    d.note = `no workspace: ${ws.error.message}`;
    return false;
  }
  d.workspace = ws.value;
  if (req.setupCommand === null) return true;
  const setup = await ports.commands.run(req.setupCommand, ws.value.path, req.testTimeoutMs);
  if (setup.ok && setup.value.passed) return true;
  d.note = `setup failed: ${setup.ok ? setup.value.tail : setup.error.message}`;
  return false;
}

async function finish(ports: DeliveryPorts, req: TournamentRequest, d: Draft, base: string) {
  const ws = d.workspace as Workspace;
  const snap = await ports.workspaces.snapshot(ws, base);
  if (!snap.ok) {
    d.note = `no snapshot: ${snap.error.message}`;
    return;
  }
  d.snapshot = snap.value;
  if (snap.value.patch.trim() === "") {
    d.note = d.note ?? "no changes";
    return;
  }
  const tests = await ports.commands.run(req.testCommand, ws.path, req.testTimeoutMs);
  d.ownTests = tests.ok
    ? tests.value
    : { passed: false, timedOut: false, tail: `test command did not run: ${tests.error.message}` };
}

/** One attempt in its own worktree: setup, build, commit locally, run the repository's tests. */
export async function runAttempt(
  ports: DeliveryPorts,
  req: TournamentRequest,
  base: string,
  index: number,
  budgetUsd: number,
): Promise<AttemptResult> {
  const d: Draft = {
    id: `a${index + 1}`,
    strategy: strategyFor(index),
    workspace: null,
    snapshot: null,
    ownTests: null,
    costUsd: 0,
    turns: 0,
    note: null,
  };
  if (await prepare(ports, req, d, base)) {
    await build(ports, req, d, budgetUsd);
    await finish(ports, req, d, base);
  }
  return { ...d };
}

export const hasPatch = (a: AttemptResult): a is AttemptResult & { snapshot: Snapshot } =>
  a.snapshot !== null && a.snapshot.patch.trim() !== "";
