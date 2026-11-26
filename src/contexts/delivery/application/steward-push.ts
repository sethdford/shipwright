/**
 * Pushing a steward fix round (ADR-0017). The push is the last gate before the agent's work is on
 * the remote, so it checks everything again, fail closed: the branch is the PR's own head branch in
 * this repository, the round started from the PR's current head, and the round's change passes the
 * scan (no secret, and no focused test or conflict marker that would game CI). Then a fast-forward.
 */
import { idempotencyKey } from "../../../shared/kernel/durability";
import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import { scanDiff } from "../domain/steward-scan";
import type { StewardPorts } from "../ports";

export interface PushRequest {
  readonly pr: number;
  readonly repoDir: string;
  readonly branch: string;
  /** The round's commit. */
  readonly sha: string;
  /** The PR head the round started from. */
  readonly from: string;
}

const BRANCH = /^(?!-)(?!.*\.\.)[A-Za-z0-9._/-]{1,200}$/;
const SHA = /^[0-9a-f]{40}$/;
const fail = (message: string) => err<AdapterError>({ kind: "failed", message });

export async function pushFix(
  ports: StewardPorts,
  req: PushRequest,
): Promise<Result<"done" | "unchanged", AdapterError>> {
  if (!BRANCH.test(req.branch)) return fail(`not a usable branch: ${req.branch}`);
  if (!SHA.test(req.sha) || !SHA.test(req.from)) return fail("--sha and --from must be full shas");
  const target = await checkTarget(ports, req);
  if (!target.ok) return target;
  const scanned = await scanRound(ports, req);
  if (!scanned.ok) return scanned;
  const key = idempotencyKey("steward", `pr${req.pr}`, "push", req.sha);
  return ports.writer.pushCommit(key, req.repoDir, req.branch, req.sha);
}

async function checkTarget(
  ports: StewardPorts,
  req: PushRequest,
): Promise<Result<void, AdapterError>> {
  const pull = await ports.reader.pull(req.pr);
  if (!pull.ok) return pull;
  const p = pull.value;
  if (p.state !== "open") return fail(`PR #${req.pr} is ${p.state}`);
  if (p.crossRepository) return fail(`PR #${req.pr} comes from a fork`);
  if (p.headRef !== req.branch) return fail(`PR #${req.pr} is on ${p.headRef}, not ${req.branch}`);
  if (p.headSha === req.sha) return ok(undefined);
  if (p.headSha !== req.from)
    return fail(`PR #${req.pr} moved to ${p.headSha.slice(0, 12)} during the round`);
  return ok(undefined);
}

async function scanRound(
  ports: StewardPorts,
  req: PushRequest,
): Promise<Result<void, AdapterError>> {
  const d = await ports.change.diff(req.from, req.sha);
  if (!d.ok) return d;
  const bad = scanDiff(d.value.patch).filter((f) => f.severity !== "note");
  if (bad.length === 0) return ok(undefined);
  const list = bad.map((f) => `${f.path}:${f.line} ${f.rule}`).join(", ");
  return fail(`the round's change has scan findings, not pushing: ${list}`);
}
