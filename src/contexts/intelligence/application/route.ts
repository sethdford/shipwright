import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import { decideRoute } from "../domain/decide";
import { extractFeatures, type IssueText } from "../domain/features";
import {
  joinRuns,
  type OutcomeResult,
  type RoutedRun,
  type RouteOverrides,
  type RouterMode,
  type RoutingDecision,
  type RoutingOutcome,
} from "../domain/records";
import { type RoutingStats, routingStats } from "../domain/stats";
import type { RoutingPorts } from "../ports";

export interface RouteRequest {
  readonly issueText: IssueText;
  readonly mode: RouterMode;
  readonly issue?: number;
  readonly repo?: string;
  readonly remainingUsd?: number;
  readonly previousFailure?: string;
  readonly overrides: RouteOverrides;
}

/**
 * The failure class of this issue's latest routed run, when that run failed. A retry of an issue
 * whose last run ran out of budget or turns then moves up a tier without the caller passing it.
 */
export function lastFailureOf(
  runs: readonly RoutedRun[],
  issue: number | undefined,
): string | undefined {
  if (issue === undefined) return undefined;
  const mine = runs.filter((r) => r.decision.issue === issue);
  const last = mine.reduce<RoutedRun | undefined>(
    (a, r) => (a === undefined || r.outcome.at > a.outcome.at ? r : a),
    undefined,
  );
  return last?.outcome.result === "failure" ? last.outcome.failureClass : undefined;
}

let decisionSeq = 0;
/** Unique within a process (a sequence number), and across processes in practice (time). */
const decisionId = (now: number, issue: number | undefined): string =>
  `rt-${now.toString(36)}-${(decisionSeq++).toString(36)}-${issue === undefined ? "goal" : String(issue)}`;

/** Decides a route from the issue and the log's history, and appends the decision to the log. */
export async function routeIssue(
  ports: RoutingPorts,
  req: RouteRequest,
): Promise<Result<RoutingDecision, AdapterError>> {
  const records = await ports.log.read();
  if (!records.ok) return records;
  const now = ports.now();
  const runs = joinRuns(records.value);
  const previousFailure = req.previousFailure ?? lastFailureOf(runs, req.issue);
  const decision = decideRoute(
    {
      id: decisionId(now, req.issue),
      at: new Date(now).toISOString(),
      mode: req.mode,
      ...(req.issue === undefined ? {} : { issue: req.issue }),
      ...(req.repo === undefined ? {} : { repo: req.repo }),
      inputs: {
        features: extractFeatures(req.issueText),
        ...(req.remainingUsd === undefined ? {} : { remainingUsd: req.remainingUsd }),
        ...(previousFailure === undefined ? {} : { previousFailure }),
        overrides: req.overrides,
      },
    },
    runs,
  );
  const written = await ports.log.append(decision);
  return written.ok ? ok(decision) : written;
}

export interface OutcomeRequest {
  readonly decisionId: string;
  readonly result: OutcomeResult;
  readonly failureClass?: string;
  readonly costUsd?: number;
  readonly pr?: number;
}

/** Records how a routed run ended. The decision must be in the log. */
export async function recordOutcome(
  ports: RoutingPorts,
  req: OutcomeRequest,
): Promise<Result<RoutingOutcome, AdapterError>> {
  const records = await ports.log.read();
  if (!records.ok) return records;
  if (!records.value.some((r) => r.kind === "decision" && r.id === req.decisionId)) {
    return err({ kind: "not_found", message: `no routing decision ${req.decisionId}` });
  }
  const outcome: RoutingOutcome = {
    kind: "outcome",
    schema: 1,
    decisionId: req.decisionId,
    at: new Date(ports.now()).toISOString(),
    result: req.result,
    ...(req.failureClass === undefined ? {} : { failureClass: req.failureClass }),
    ...(req.costUsd === undefined ? {} : { costUsd: req.costUsd }),
    ...(req.pr === undefined ? {} : { pr: req.pr }),
  };
  const written = await ports.log.append(outcome);
  return written.ok ? ok(outcome) : written;
}

export async function loadRoutingStats(
  ports: RoutingPorts,
): Promise<Result<RoutingStats, AdapterError>> {
  const records = await ports.log.read();
  if (!records.ok) return records;
  const decisions = records.value.filter((r) => r.kind === "decision").length;
  return ok(routingStats(joinRuns(records.value), decisions));
}
