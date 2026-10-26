import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { classifyAndDecide, type FailureClass } from "../../../contexts/learning";
import { type BashLocale, bashCharsIn, bashClassifyAll } from "../../bash-classify";
import { createTestEnv } from "../../test-env";

// Pins the TypeScript classes against the REAL bash classify_failure for the three classes W2-04 maps.
// Bash runs live in an isolated env on every test run, so drift in scripts/lib/daemon-failure.sh fails here.
interface Case {
  readonly text: string;
  readonly bash: string;
  readonly ts: FailureClass;
  readonly differs?: string;
  /** A row from the #8696 reviewer corpus. */
  readonly name?: string;
  /** Its expected escalation: "noesc", or "esc:<class>". */
  readonly expect?: string;
  /** A documented limit: the row is known not to meet `expect`, in both classifiers. */
  readonly limit?: string;
}
interface Corpus {
  readonly mapping: Readonly<Record<string, FailureClass>>;
  readonly cases: readonly Case[];
}
const corpus = JSON.parse(
  readFileSync(new URL("classify-parity.json", import.meta.url), "utf8"),
) as Corpus;

const liveBashIn = (locale: BashLocale, texts: readonly string[]) => {
  const env = createTestEnv();
  try {
    return bashClassifyAll(env, texts, locale);
  } finally {
    env.cleanup();
  }
};
const liveBash = liveBashIn(
  "C",
  corpus.cases.map((c) => c.text),
);

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

// Live bash over every row (840+) takes tens of seconds under a parallel load; the default 5 s timeout is too tight.
const ESCALATIONS: Readonly<Record<string, FailureClass>> = {
  auth_error: "auth",
  invalid_issue: "invalid_input",
  contamination: "contamination",
};
const tsEscalation = (cls: FailureClass) =>
  cls === "auth" || cls === "invalid_input" || cls === "contamination" ? cls : "-";
const bashEscalation = (label: string) => ESCALATIONS[label] ?? "-";
const meets = (expect: string, escalation: string) =>
  expect === "noesc" ? escalation === "-" : escalation === expect.slice("esc:".length);

describe("#8696 reviewer corpus: escalations only from structured lines, in both classifiers and both locales", () => {
  const rows = corpus.cases.filter((c) => c.expect !== undefined);

  test("the corpus is present", () => {
    expect(rows.length).toBeGreaterThanOrEqual(94);
  });

  test("bash labels every case the same under LC_ALL=C and a UTF-8 locale", () => {
    // The UTF-8 run must really be multibyte, or it proves nothing.
    expect(bashCharsIn("en_US.UTF-8", "✗")).toBe(1);
    const utf8 = liveBashIn(
      "en_US.UTF-8",
      corpus.cases.map((c) => c.text),
    );
    const diverging = corpus.cases
      .map((c, i) => ({ text: c.text, c: liveBash[i], utf8: utf8[i] }))
      .filter((row) => row.c !== row.utf8);
    expect(diverging).toEqual([]);
  }, 300_000);

  test("every case escalates the same way in TS and bash", () => {
    const diverging = corpus.cases
      .map((c, i) => ({
        text: c.text,
        ts: tsEscalation(classifyAndDecide({ text: c.text, attempts: [] }).class),
        bash: bashEscalation(liveBash[i] ?? ""),
      }))
      .filter((row) => row.ts !== row.bash);
    expect(diverging).toEqual([]);
  });

  test("every corpus row meets its expectation, and every documented limit really misses it", () => {
    const wrong = rows
      .map((c) => ({
        name: c.name,
        expect: c.expect ?? "",
        limit: c.limit !== undefined,
        got: tsEscalation(classifyAndDecide({ text: c.text, attempts: [] }).class),
      }))
      .filter((row) => meets(row.expect, row.got) === row.limit);
    expect(wrong).toEqual([]);
  });

  test("a structured line deep in a 10k-line log: only the last 200 lines count", () => {
    const filler = Array.from({ length: 9990 }, (_, i) => `ok ${i} test passes`).join("\n");
    const big: ReadonlyArray<readonly [string, string]> = [
      [
        `${filler}\nnote: printed CONTAMINATION: pipeline-state-missing in docs\nlog: the gate said Skipping integration tests: refusing to run inside a build-loop test gate (expected)\nError: build failed`,
        "noesc",
      ],
      [`CONTAMINATION: pipeline-state-missing\n${filler}\nError: build failed`, "noesc"],
      [
        `${filler}\nCONTAMINATION: pipeline-state-missing\nError: build failed`,
        "esc:contamination",
      ],
    ];
    const bash = liveBashIn(
      "C",
      big.map(([text]) => text),
    );
    big.forEach(([text, expectation], i) => {
      const ts = tsEscalation(classifyAndDecide({ text, attempts: [] }).class);
      expect({ i, ts, bash: bashEscalation(bash[i] ?? "") }).toEqual({ i, ts, bash: ts });
      expect({ i, ok: meets(expectation, ts) }).toEqual({ i, ok: true });
    });
  }, 300_000);
});
