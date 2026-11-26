import { describe, expect, test } from "bun:test";
import { expandArgv, parseArms } from "./arm";

const cc = { id: "claude-code", kind: "claude-code", model: "claude-opus-5-5", estimateUsd: 2 };
const sw = {
  id: "shipwright-k3",
  kind: "shipwright",
  model: "claude-opus-5-5",
  attempts: 3,
  estimateUsd: 9,
};

describe("parseArms", () => {
  test("accepts arms with defaults and a baseline", () => {
    const r = parseArms({ baseline: "claude-code", arms: [cc, sw] });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.arms[0]).toMatchObject({
      label: "claude-code",
      attempts: 1,
      timeoutMin: 60,
      argv: null,
      env: {},
    });
    expect(r.value.arms[1]?.attempts).toBe(3);
  });

  test.each([
    [{ ...cc, attempts: 3 }, "only shipwright takes attempts"],
    [{ ...sw, attempts: 9 }, "attempts must be 1 to 5"],
    [{ ...cc, kind: "command" }, "needs an argv array"],
    [{ ...cc, argv: ["x"] }, "only command arms take argv"],
    [{ ...cc, estimateUsd: -1 }, "estimateUsd"],
    [{ ...cc, env: { GH_TOKEN: "x" } }, "SHIPWRIGHT_* or PIPELINE_*"],
    [{ ...cc, env: { SHIPWRIGHT_LESSONS: 1 } }, "must be a string"],
  ])("rejects %p", (arm, reason) => {
    const r = parseArms({ baseline: arm.id, arms: [arm] });
    expect(r.ok ? "" : r.reason).toContain(reason);
  });

  test("lesson-trial env passes through", () => {
    const arm = { ...sw, env: { SHIPWRIGHT_LESSONS_TRIAL: "L-0007,L-0008" } };
    const r = parseArms({ baseline: sw.id, arms: [arm] });
    expect(r.ok && r.value.arms[0]?.env).toEqual({ SHIPWRIGHT_LESSONS_TRIAL: "L-0007,L-0008" });
  });

  test("the baseline must be one of the arms", () => {
    expect(parseArms({ baseline: "nope", arms: [cc] }).ok).toBe(false);
  });
});

test("expandArgv fills placeholders inside tokens and never splits them", () => {
  const template = ["aider", "--message-file", "{problem_file}", "--model={model}", "{workdir} x"];
  const argv = expandArgv(template, { workdir: "/w; rm -rf /", problemFile: "/p.md", model: "m" });
  expect(argv).toEqual(["aider", "--message-file", "/p.md", "--model=m", "/w; rm -rf / x"]);
});
