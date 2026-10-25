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
