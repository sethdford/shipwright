import {
  type CommandOutcome,
  type DeliveryPorts,
  GRADER_INSTRUCTIONS,
  JUDGE_INSTRUCTIONS,
  RUBRIC_INSTRUCTIONS,
  type Snapshot,
  type Workspace,
} from "../contexts/delivery";
import type {
  AgentFailure,
  AgentRunner,
  DecideRequest,
  Decision,
  TaskOutcome,
  TaskSpec,
} from "../shared/kernel/ports";
import { err, ok, type Result } from "../shared/kernel/result";

const usage = (costUsd: number) => ({ costUsd, inputTokens: 0, outputTokens: 0, durationMs: 0 });

export interface FakeScript {
  /** Per attempt label: the patch it produces and the files it touches. Missing = empty patch. */
  readonly patches: Readonly<Record<string, { patch: string; files: string[] }>>;
  /** Whether the repository tests pass for a patch, given the test files overlaid from another. */
  readonly tests: (patch: string, overlaidFrom: string | null) => boolean;
  /** Grader verdicts per patch (criterion id → met). */
  readonly grades?: Readonly<Record<string, Record<string, boolean>>>;
  /** The judge's answer, as a function of the label → patch it was shown. */
  readonly judge?: (shown: Readonly<Record<string, string>>) => string;
  readonly rubricFails?: boolean;
  readonly baseFails?: boolean;
}

export const RUBRIC = {
  criteria: [
    { id: "fixes-bug", text: "fixes it", weight: 3, axis: "correctness" },
    { id: "adds-test", text: "tests it", weight: 2, axis: "tests" },
    { id: "small", text: "small", weight: 1, axis: "scope" },
  ],
};

/** Records what the tournament asked for, and answers from a script. */
export class FakeDelivery {
  readonly tasks: TaskSpec[] = [];
  readonly decisions: DecideRequest<unknown>[] = [];
  readonly removed: string[] = [];
  readonly adopted: string[] = [];
  readonly commandsRun: { command: string; cwd: string }[] = [];
  private readonly overlays = new Map<string, string | null>();

  constructor(private readonly s: FakeScript) {}

  ports(random: () => number = () => 0.99): DeliveryPorts {
    return {
      agent: this.agent(),
      workspaces: this.workspaces(),
      commands: this.commands(),
      random,
    };
  }

  private patchAt(path: string): string {
    const label = path.split("/").pop() ?? "";
    return this.s.patches[label]?.patch ?? "";
  }

  private agent(): AgentRunner {
    const self = this;
    return {
      async decide<T>(req: DecideRequest<T>): Promise<Result<Decision<T>, AgentFailure>> {
        self.decisions.push(req as DecideRequest<unknown>);
        const value = self.answer(req);
        if (value === null)
          return err({ kind: "execution", message: "scripted failure", usage: usage(0.1) });
        return ok({ value: req.schema.parse(value), usage: usage(0.1) });
      },
      async runTask(spec: TaskSpec): Promise<Result<TaskOutcome, AgentFailure>> {
        self.tasks.push(spec);
        return ok({ summary: "done", usage: usage(1), turns: 7, sessionId: "s" });
      },
    };
  }

  private answer(req: DecideRequest<unknown>): unknown {
    if (req.instructions === RUBRIC_INSTRUCTIONS) return this.s.rubricFails ? null : RUBRIC;
    if (req.instructions === GRADER_INSTRUCTIONS) {
      const patch =
        Object.values(this.s.patches).find((p) => req.data.includes(p.patch))?.patch ?? "";
      const met = this.s.grades?.[patch] ?? {};
      return { verdicts: Object.entries(met).map(([id, m]) => ({ id, met: m, evidence: "x" })) };
    }
    if (req.instructions === JUDGE_INSTRUCTIONS) {
      const shown: Record<string, string> = {};
      for (const m of req.data.matchAll(/## Candidate ([A-Z])\n(.*)/g))
        shown[m[1] as string] = m[2] as string;
      return {
        consensus: [{ claim: "all edit parse()", defect: false, note: "" }],
        choice: this.s.judge?.(shown) ?? "A",
        reasons: "best",
      };
    }
    throw new Error("unexpected decide call");
  }

  private workspaces(): DeliveryPorts["workspaces"] {
    const snap = (label: string): Snapshot => {
      const p = this.s.patches[label];
      return { sha: `${label}`.padEnd(40, "0"), patch: p?.patch ?? "", files: p?.files ?? [] };
    };
    return {
      baseSha: async () =>
        this.s.baseFails ? err({ kind: "not_found", message: "no repo" }) : ok("b".repeat(40)),
      create: async (label: string): Promise<Result<Workspace, never>> =>
        ok({ label, path: `/wt/${label}` }),
      snapshot: async (ws: Workspace) => ok(snap(ws.label)),
      overlay: async (ws: Workspace, sha: string) => {
        this.overlays.set(ws.path, this.patchAt(`/wt/${sha.replace(/0+$/, "")}`));
        return ok(undefined);
      },
      reset: async (ws: Workspace) => {
        this.overlays.set(ws.path, null);
        return ok(undefined);
      },
      remove: async (ws: Workspace) => {
        this.removed.push(ws.label);
        return ok(undefined);
      },
      adopt: async (sha: string) => {
        this.adopted.push(sha);
        return ok(undefined);
      },
    };
  }

  private commands(): DeliveryPorts["commands"] {
    const self = this;
    return {
      async run(command: string, cwd: string): Promise<Result<CommandOutcome, never>> {
        self.commandsRun.push({ command, cwd });
        const passed = self.s.tests(self.patchAt(cwd), self.overlays.get(cwd) ?? null);
        return ok({ passed, timedOut: false, tail: passed ? "ok" : "1 failed" });
      },
    };
  }
}
