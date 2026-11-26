import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import {
  type ChangeSignals,
  extractFeatures,
  type FeatureVector,
  type FileChange,
  NO_SIGNALS,
} from "../domain/change-features";
import {
  type Contribution,
  explain,
  PRIOR_MODEL,
  predict,
  type VerifierModel,
} from "../domain/verifier-model";
import {
  type Decision,
  decide,
  type Evidence,
  NO_EVIDENCE,
  type VerifierMode,
} from "../domain/verifier-policy";
import type { VerifierPorts } from "../ports";
import { runCritic } from "./critic";

export interface ScoreRequest {
  readonly baseRef: string;
  readonly title: string;
  readonly body: string;
  readonly mode: VerifierMode;
  /** Signals the run measured (tests, cross-tests, rubric); the critic's is filled in here. */
  readonly signals: Omit<ChangeSignals, "criticProbability">;
  /** Run the prompted critic with this model and budget; null skips it (no model spend). */
  readonly critic: {
    readonly model: string;
    readonly budgetUsd: number;
    /** The repository model's change-impact section, given to the critic as more data. */
    readonly impact?: string;
  } | null;
}

export interface ScoreReport {
  readonly probability: number;
  readonly model: VerifierModel["source"];
  readonly examples: number;
  readonly features: FeatureVector;
  readonly drivers: readonly Contribution[];
  readonly decision: Decision;
  readonly critic: {
    readonly probability: number | null;
    readonly concerns: readonly string[];
  } | null;
  readonly costUsd: number;
  readonly notes: readonly string[];
}

async function loadModel(ports: Pick<VerifierPorts, "store">, notes: string[]) {
  const stored = await ports.store.load();
  if (stored.ok && stored.value) return stored.value;
  if (!stored.ok)
    notes.push(`could not read the trained verifier (${stored.error.message}); using the prior`);
  return { model: PRIOR_MODEL, evidence: NO_EVIDENCE as Evidence };
}

/** A candidate change already in hand (a tournament attempt's snapshot, say). */
export type CandidateRequest = Omit<ScoreRequest, "baseRef"> & {
  readonly files: readonly FileChange[];
  readonly patch: string;
};

/**
 * Scores one candidate: optionally the prompted critic, then the trained model (or the prior) and
 * the gate. Never fails: an unreadable model or a failed critic is a note, and the verifier
 * scores without it. The build tournament calls this for each finalist.
 */
export async function scoreCandidate(
  ports: Pick<VerifierPorts, "store" | "agent">,
  req: CandidateRequest,
): Promise<ScoreReport> {
  const notes: string[] = [];
  const { model, evidence } = await loadModel(ports, notes);
  const critic = req.critic ? await runCritic(ports.agent, { ...req, ...req.critic }) : null;
  if (critic?.note) notes.push(critic.note);
  const signals = { ...NO_SIGNALS, ...req.signals, criticProbability: critic?.probability ?? null };
  const features = extractFeatures({ ...req, signals, factory: true });
  const probability = predict(model, features);
  return {
    probability,
    model: model.source,
    examples: model.examples,
    features,
    drivers: explain(model, features),
    decision: decide(req.mode, probability, features, evidence),
    critic: critic ? { probability: critic.probability, concerns: critic.concerns } : null,
    costUsd: critic?.costUsd ?? 0,
    notes,
  };
}

/**
 * Records the score with the run's signals under the current branch, so training can learn the
 * critic's weight from this PR's outcome later. A failure to record is a note, never an error.
 */
async function record(ports: VerifierPorts, req: ScoreRequest, report: ScoreReport) {
  const head = await ports.change.head();
  if (!head.ok) return `score not logged: ${head.error.message}`;
  if (head.value.branch === "") return "score not logged: detached HEAD";
  const r = await ports.scores.append({
    atMs: ports.now(),
    branch: head.value.branch,
    headSha: head.value.sha,
    probability: report.probability,
    signals: {
      ...NO_SIGNALS,
      ...req.signals,
      criticProbability: report.critic?.probability ?? null,
    },
  });
  return r.ok ? null : `score not logged: ${r.error.message}`;
}

/** Scores the current branch's change before a PR exists (`git diff base...HEAD`), and logs it. */
export async function scoreChange(
  ports: VerifierPorts,
  req: ScoreRequest,
): Promise<Result<ScoreReport, AdapterError>> {
  const diff = await ports.change.diff(req.baseRef);
  if (!diff.ok) return diff;
  const report = await scoreCandidate(ports, { ...req, ...diff.value });
  const note = await record(ports, req, report);
  return ok(note ? { ...report, notes: [...report.notes, note] } : report);
}
