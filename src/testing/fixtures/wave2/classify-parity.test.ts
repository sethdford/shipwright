import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { classifyAndDecide, type FailureClass } from "../../../contexts/learning";

// Pins the TypeScript classes against bash classify_failure for the three classes W2-04 maps.
// The bash column was recorded from scripts/lib/daemon-failure.sh (see _about in the fixture).
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

describe("TS classes pinned against bash classify_failure (W2-04 mapping)", () => {
  test("the mapping covers exactly auth, transient and invalid_input", () => {
    expect(Object.values(corpus.mapping).sort()).toEqual(["auth", "invalid_input", "transient"]);
  });

  test("every case's TS class is the pinned class", () => {
    for (const c of corpus.cases) {
      expect({
        text: c.text,
        class: classifyAndDecide({ text: c.text, attempts: [] }).class,
      }).toEqual({ text: c.text, class: c.ts });
    }
  });

  test("a mapped bash label agrees with TS unless the case documents why not", () => {
    for (const c of corpus.cases) {
      const mapped = corpus.mapping[c.bash];
      if (mapped === undefined) continue;
      if (c.differs !== undefined) {
        expect(c.ts).not.toBe(mapped);
      } else {
        expect({ text: c.text, ts: c.ts }).toEqual({ text: c.text, ts: mapped });
      }
    }
  });

  test("every documented difference really differs", () => {
    for (const c of corpus.cases.filter((x) => x.differs !== undefined)) {
      expect(corpus.mapping[c.bash]).toBeDefined();
      expect(c.ts).not.toBe(corpus.mapping[c.bash]);
    }
  });
});
