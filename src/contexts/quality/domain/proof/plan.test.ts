import { expect, test } from "bun:test";
import { NO_CONFIG, type ProofConfig } from "./config";
import type { AppProfile } from "./detect";
import { planProof } from "./plan";

const next: AppProfile = {
  web: { framework: "next", start: ["npm", "run", "dev"], defaultPort: 3000 },
  cli: null,
};

test("a detected app starts on the picked port and visits the changed pages", () => {
  const plan = planProof({
    config: NO_CONFIG,
    profile: next,
    changed: ["app/cart/page.tsx"],
    port: 41000,
  });
  expect(plan.web?.start).toEqual(["npm", "run", "dev", "--", "-p", "41000"]);
  expect(plan.web?.flows.map((f) => f.name)).toEqual(["page /", "page /cart"]);
  expect(plan.web?.source).toBe("detected");
  expect(plan.web?.readyTimeoutMs).toBe(120_000);
  expect(plan.notes).toEqual([]);
});

test("bun and pnpm take the port flags without --", () => {
  const profile: AppProfile = {
    web: { framework: "vite", start: ["bun", "run", "dev"], defaultPort: 5173 },
    cli: null,
  };
  const plan = planProof({ config: NO_CONFIG, profile, changed: [], port: 4100 });
  expect(plan.web?.start).toEqual(["bun", "run", "dev", "--port", "4100", "--host", "127.0.0.1"]);
});

test("proof.json wins field by field", () => {
  const config: ProofConfig = {
    enabled: true,
    web: {
      start: ["make", "serve"],
      port: 8080,
      readyTimeoutSec: 30,
      flows: [{ name: "x", steps: [{ goto: "/x" }] }],
    },
    cli: { runs: [] },
  };
  const plan = planProof({
    config,
    profile: { ...next, cli: { name: "t", argv: ["node", "t.js"] } },
    changed: [],
    port: 41000,
  });
  expect(plan.web).toMatchObject({
    start: ["make", "serve"],
    port: 8080,
    readyTimeoutMs: 30_000,
    source: "config",
  });
  expect(plan.web?.flows).toEqual([{ name: "x", steps: [{ goto: "/x" }] }]);
  expect(plan.cli).toEqual([]);
});

test("a detected CLI gets a --help run", () => {
  const plan = planProof({
    config: NO_CONFIG,
    profile: { web: null, cli: { name: "todo", argv: ["node", "bin/todo.js"] } },
    changed: [],
    port: 1,
  });
  expect(plan.web).toBeNull();
  expect(plan.cli).toEqual([
    { name: "todo --help", argv: ["node", "bin/todo.js", "--help"], expectExit: 0 },
  ]);
});

test("nothing to run, or turned off, says why", () => {
  const empty = planProof({
    config: NO_CONFIG,
    profile: { web: null, cli: null },
    changed: [],
    port: 1,
  });
  expect(empty.notes[0]).toContain("no web app or CLI was detected");
  const off = planProof({ config: { enabled: false }, profile: next, changed: [], port: 1 });
  expect(off.web).toBeNull();
  expect(off.notes[0]).toContain("turned off");
});
