import { describe, expect, test } from "bun:test";
import { parseLesson } from "./lesson";
import { decidePromotion, parseTrialVerdict, type TrialVerdict } from "./promote";

const lesson = parseLesson(
  ".shipwright/lessons/L-0003.md",
  '---\nid: L-0003\nstatus: proposed\nfingerprint: fp\napplies_to: ["src/**"]\nkeywords: ["auth"]\nhypothesis: "fewer reruns"\n---\n# Title\n\nDo X.\n\n## Evidence\n\nlog\n',
);
const verdict: TrialVerdict = {
  accept: true,
  reason: "superior: sign test p=0.0313",
  cases: 12,
  wins: 5,
  losses: 0,
  ties: 7,
  signTestP: 0.03125,
  medianCostRatio: 0.97,
};

describe("parseTrialVerdict", () => {
  test("reads the full ratchet report and the bare verdict", () => {
    expect(parseTrialVerdict({ incumbent: "a", candidate: "b", verdict })).toEqual({
      ok: true,
      value: verdict,
    });
    expect(parseTrialVerdict(verdict)).toEqual({ ok: true, value: verdict });
  });

  test("fails closed on a missing or odd field", () => {
    expect(parseTrialVerdict({ ...verdict, accept: "yes" }).ok).toBe(false);
    expect(parseTrialVerdict({ ...verdict, wins: -1 }).ok).toBe(false);
    expect(parseTrialVerdict({ ...verdict, medianCostRatio: "1" }).ok).toBe(false);
    expect(parseTrialVerdict(null).ok).toBe(false);
  });
});

describe("decidePromotion", () => {
  test("an accepted trial on enough cases becomes active, with the rule, triggers and an Evaluation", () => {
    const p = decidePromotion(lesson, "log", verdict, "eval 2026-11-26");
    expect(p.outcome).toBe("promote");
    const back = parseLesson(lesson.path, p.markdown);
    expect(back).toMatchObject({
      status: "active",
      fingerprint: "fp",
      appliesTo: ["src/**"],
      text: "Do X.",
    });
    expect(p.markdown).toContain("12 cases, 5 wins, 0 losses, 7 ties");
    expect(p.markdown).toContain("## Evidence\n\nlog");
  });

  test("a rejected trial is retired, so it is not mined or trialled again", () => {
    const p = decidePromotion(
      lesson,
      undefined,
      { ...verdict, accept: false, reason: "inferior" },
      "t",
    );
    expect([p.outcome, parseLesson(lesson.path, p.markdown).status]).toEqual(["retire", "retired"]);
  });

  test("an accepted trial on fewer than 12 cases is retired, not promoted", () => {
    const p = decidePromotion(lesson, undefined, { ...verdict, cases: 6 }, "t");
    expect(p.outcome).toBe("retire");
    expect(p.why).toContain("at least 12");
  });
});
