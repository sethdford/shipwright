import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { classifyAndDecide, type FailureClass } from "../../../contexts/learning";
import { bashClassifyAll } from "../../bash-classify";
import { createTestEnv } from "../../test-env";

// Pins the TypeScript classes against the REAL bash classify_failure for the three classes W2-04 maps.
// Bash runs live in an isolated env on every test run, so drift in scripts/lib/daemon-failure.sh fails here.
interface Case {
  readonly text: string;
  readonly bash: string;
  readonly ts: FailureClass;
  readonly differs?: string;
}
interface Corpus {
  readonly mapping: Readonly<Record<string, FailureClass>>;
  readonly cases: readonly Case[];
}
const corpus = JSON.parse(
  readFileSync(new URL("classify-parity.json", import.meta.url), "utf8"),
) as Corpus;

const liveBash = (() => {
  const env = createTestEnv();
  try {
    return bashClassifyAll(
      env,
      corpus.cases.map((c) => c.text),
    );
  } finally {
    env.cleanup();
  }
})();

describe("TS classes pinned against live bash classify_failure (W2-04 mapping)", () => {
  test("the mapping covers exactly auth, transient and invalid_input", () => {
    expect(Object.values(corpus.mapping).sort()).toEqual(["auth", "invalid_input", "transient"]);
  });

  test("live bash agrees with the recorded bash label for every case (drift check)", () => {
    const drift = corpus.cases
      .map((c, i) => ({ text: c.text, recorded: c.bash, live: liveBash[i] }))
      .filter((row) => row.recorded !== row.live);
    expect(drift).toEqual([]);
  });

  test("every case's TS class is the pinned class", () => {
    for (const c of corpus.cases) {
      const got = classifyAndDecide({ text: c.text, attempts: [] }).class;
      expect({ text: c.text, class: got }).toEqual({ text: c.text, class: c.ts });
    }
  });

  test("a mapped live bash label agrees with TS unless the case documents why not", () => {
    corpus.cases.forEach((c, i) => {
      const mapped = corpus.mapping[liveBash[i] ?? ""];
      if (mapped === undefined) return;
      if (c.differs !== undefined) {
        expect(c.ts).not.toBe(mapped);
      } else {
        expect({ text: c.text, ts: c.ts }).toEqual({ text: c.text, ts: mapped });
      }
    });
  });

  test("every documented difference really differs", () => {
    for (const c of corpus.cases.filter((x) => x.differs !== undefined)) {
      const mapped = corpus.mapping[c.bash];
      expect(mapped).toBeDefined();
      expect(c.ts).not.toBe(mapped);
    }
  });
});

// #8696 self-triggers: text a failing test or a tool prints about escalations. Neither classifier may escalate on it.
const SELF_TRIGGERS: readonly string[] = [
  '(fail) classifies gh error "GraphQL: Could not resolve to an issue or pull request with the number of 1." as "not_found" [0.4ms]\nerror: expect(received).toEqual(expected)',
  '(fail) classifies gh error "HTTP 401: Bad credentials" as "auth" [0.2ms]',
  "(fail) maps 401 Unauthorized to auth [1ms]",
  '    Expected: "issue not found"\n    Received: "ok"\nerror: expect(received).toBe(expected)',
  "(fail) client > maps HTTP 404 on GET /repos/o/r/issues/12 to NotFound\nerror: expected 1 to be 2",
  "SyntaxError: Invalid or unexpected token\n    at file.js:3",
  "(fail) jwt > rejects invalid token\nerror: expected",
  "(fail) gate test\nCONTAMINATION: x\nerror: boom",
  "  CONTAMINATION: pipeline-state-missing (echoed by test)\nerror",
  "✗ prints refusing to run inside a build-loop test gate when gated\nerror: assertion failed",
  "Issue #42 has no body; nothing to plan",
];

describe("#8696 self-triggers never escalate (both classifiers)", () => {
  for (const text of SELF_TRIGGERS) {
    test(`does not escalate: ${JSON.stringify(text).slice(0, 70)}`, () => {
      const ts = classifyAndDecide({ text, attempts: [] }).class;
      expect(["auth", "invalid_input", "contamination"]).not.toContain(ts);
      const i = corpus.cases.findIndex((c) => c.text === text);
      expect(i).toBeGreaterThanOrEqual(0);
      expect(["auth_error", "invalid_issue", "contamination"]).not.toContain(liveBash[i] ?? "");
    });
  }
});
