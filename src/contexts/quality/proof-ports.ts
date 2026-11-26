import type { AdapterError, ProcessResult } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { Flow } from "./domain/proof/config";
import type { RepoFacts } from "./domain/proof/detect";
import type { FlowResult } from "./domain/proof/result";

/** The repository under test: root files, its proof.json and the files the change touched. */
export interface ProofRepo {
  facts(): Promise<Result<RepoFacts, AdapterError>>;
  /** The text of .shipwright/proof.json, or null when there is none. */
  config(): Promise<Result<string | null, AdapterError>>;
  /** Paths changed since the merge base with `baseRef` (committed or not). */
  changedFiles(baseRef: string): Promise<Result<readonly string[], AdapterError>>;
}

export interface StartRequest {
  readonly argv: readonly string[];
  readonly port: number;
  /** A fixed URL to wait on; null reads it from the app's output, else uses PORT. */
  readonly url: string | null;
  readonly readyPath: string;
  readonly readyTimeoutMs: number;
}

export interface RunningApp {
  readonly url: string;
  /** Everything the app printed so far (stdout and stderr interleaved). */
  log(): string;
  stop(): Promise<void>;
}

export type StartOutcome =
  | { readonly ok: true; readonly app: RunningApp }
  | { readonly ok: false; readonly reason: string; readonly log: string };

/**
 * Starts the app inside the trust boundary: no GitHub, git or Claude credentials (the same
 * environment as the test gate), its own process group, killed on stop.
 */
export interface AppLauncher {
  freePort(): Promise<number>;
  start(request: StartRequest): Promise<StartOutcome>;
}

export interface BrowseRequest {
  readonly baseUrl: string;
  readonly flows: readonly Flow[];
  /** Directory screenshots and videos are written to; results name files relative to it. */
  readonly outDir: string;
  /** Hosts besides the app's own that pages may load from. Everything else is blocked. */
  readonly allowHosts: readonly string[];
  readonly video: boolean;
}

/** Drives a headless browser through flows. Never throws: problems come back in the results. */
export interface BrowserDriver {
  /** null when a browser can run here, else why not (with the fix). */
  unavailable(): Promise<string | null>;
  run(request: BrowseRequest): Promise<readonly FlowResult[]>;
}

/** Runs one CLI argv without credentials, the way the test gate does. */
export interface CliExecutor {
  run(argv: readonly string[], timeoutMs: number): Promise<ProcessResult>;
}

/** The run's output directory. */
export interface ProofArtifacts {
  readonly dir: string;
  write(relPath: string, text: string): Promise<Result<void, AdapterError>>;
}

/**
 * Puts a run's artifacts where a PR can show them; returns their base URL (ending in "/").
 * `files` are the run's own artifacts, relative to `dir`.
 */
export interface ProofPublisher {
  publish(
    dir: string,
    label: string,
    files: readonly string[],
  ): Promise<Result<string, AdapterError>>;
}

export interface ProofPorts {
  readonly repo: ProofRepo;
  readonly launcher: AppLauncher;
  readonly browser: BrowserDriver;
  readonly cli: CliExecutor;
  readonly artifacts: ProofArtifacts;
  readonly publisher: ProofPublisher;
}
