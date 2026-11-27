import { filesFromPatch } from "../domain/patch-files";
import { untrustedReason } from "../domain/verifier-policy";
import type { VerifierPorts } from "../ports";
import { scoreCandidate } from "./verifier-score";

/** One tournament candidate as the verifier sees it (structurally the delivery port's input). */
export interface CandidateInput {
  readonly goal: string;
  readonly patch: string;
  readonly ownTestsPass: boolean;
  readonly cross: number | null;
  readonly rubric: number | null;
}

/**
 * Title every candidate is scored under. The goal is issue text, not a PR title: run through the
 * chatter and title features it would misfire ("I have…"), so candidates get the conventional
 * title the PR stage will give the winner, and only their diffs and signals differ.
 */
export const CANDIDATE_TITLE = "feat: tournament candidate";

/**
 * The merge verifier for the build tournament: scores a candidate from its patch with the trained
 * model (no critic: tournaments already pay for a rubric and a judge), and says whether the model
 * has earned the right to stop a tournament early. Never throws.
 */
export function candidateVerifier(ports: Pick<VerifierPorts, "store" | "agent">) {
  return {
    async score(input: CandidateInput): Promise<number | null> {
      try {
        const r = await scoreCandidate(ports, {
          title: CANDIDATE_TITLE,
          body: "",
          mode: "advisory",
          signals: {
            ownTestsPass: input.ownTestsPass,
            crossPassRate: input.cross,
            rubricScore: input.rubric,
          },
          critic: null,
          files: filesFromPatch(input.patch),
          patch: input.patch,
        });
        return r.probability;
      } catch {
        return null;
      }
    },
    /** null when trusted to stop early (the same evidence bar as blocking a PR), else why not. */
    async readiness(): Promise<string | null> {
      const s = await ports.store.load();
      if (!s.ok) return `cannot read the trained verifier: ${s.error.message}`;
      if (s.value === null) return "the verifier was never trained";
      return untrustedReason(s.value.evidence);
    },
  };
}
