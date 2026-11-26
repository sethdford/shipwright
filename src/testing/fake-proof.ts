import type { FlowResult, ProofPorts, RepoFacts, StartOutcome } from "../contexts/quality";
import type { AdapterError, ProcessResult } from "../shared/kernel/ports";
import { ok, type Result } from "../shared/kernel/result";

export interface FakeProofOptions {
  readonly facts?: RepoFacts;
  readonly config?: string | null;
  readonly changed?: readonly string[];
  readonly start?: StartOutcome | "ok";
  readonly browserMissing?: string | null;
  readonly flows?: readonly FlowResult[];
  readonly cli?: ProcessResult;
  readonly publish?: Result<string, AdapterError>;
}

export interface FakeProof {
  readonly ports: ProofPorts;
  readonly written: Record<string, string>;
  readonly started: (readonly string[])[];
  readonly cliRuns: (readonly string[])[];
  readonly published: string[];
  stopped: number;
}

export const nodeApp: RepoFacts = {
  packageJson: JSON.stringify({
    scripts: { start: "node server.js" },
    bin: { todo: "bin/todo.js" },
  }),
  markers: [],
  cargoToml: null,
  goMains: [],
};

function fakeRuns(o: FakeProofOptions, state: FakeProof): Pick<ProofPorts, "launcher" | "cli"> {
  const app = {
    url: "http://127.0.0.1:4000",
    log: () => "ready token=ghp_abcdefghijklmnopqrstuvwxyz12",
    stop: async () => {
      state.stopped++;
    },
  };
  return {
    launcher: {
      freePort: async () => 4000,
      start: async (r) => {
        state.started.push(r.argv);
        const s = o.start ?? "ok";
        return s === "ok" ? { ok: true, app } : s;
      },
    },
    cli: {
      run: async (argv) => {
        state.cliRuns.push(argv);
        return o.cli ?? { exitCode: 0, stdout: "usage: todo", stderr: "", timedOut: false };
      },
    },
  };
}

/** In-memory proof ports: nothing starts, nothing is pushed, every call is recorded. */
export function fakeProof(o: FakeProofOptions = {}): FakeProof {
  const state = { written: {}, started: [], cliRuns: [], published: [], stopped: 0 } as Omit<
    FakeProof,
    "ports"
  > as FakeProof;
  const ports: ProofPorts = {
    repo: {
      facts: async () => ok(o.facts ?? nodeApp),
      config: async () => ok(o.config ?? null),
      changedFiles: async () => ok(o.changed ?? []),
    },
    ...fakeRuns(o, state),
    browser: { unavailable: async () => o.browserMissing ?? null, run: async () => o.flows ?? [] },
    artifacts: {
      dir: "/out",
      write: async (path, text) => {
        state.written[path] = text;
        return ok(undefined);
      },
    },
    publisher: {
      publish: async (_dir, label) => {
        state.published.push(label);
        return o.publish ?? ok(`https://github.com/o/r/raw/abc/${label}/`);
      },
    },
  };
  Object.assign(state, { ports });
  return state;
}
