import { afterEach, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { decideRoute, extractFeatures, type RoutingOutcome } from "../../contexts/intelligence";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { JsonlRoutingLog } from "./jsonl-routing-log";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());

const decision = decideRoute(
  {
    id: "rt-a-1",
    at: "2026-11-26T00:00:00.000Z",
    mode: "shadow",
    issue: 1,
    inputs: {
      features: extractFeatures({ title: "docs: typo", body: "", labels: [] }),
      overrides: {},
    },
  },
  [],
);
const outcome: RoutingOutcome = {
  kind: "outcome",
  schema: 1,
  decisionId: "rt-a-1",
  at: "2026-11-26T01:00:00.000Z",
  result: "success",
  costUsd: 1.25,
  pr: 7,
};

test("a missing log reads as empty; appends create the directory and round-trip", async () => {
  env = createTestEnv();
  const path = join(env.stateDir, "routing", "decisions.jsonl");
  const log = new JsonlRoutingLog(path);
  expect(await log.read()).toEqual({ ok: true, value: [] });
  expect((await log.append(decision)).ok).toBe(true);
  expect((await log.append(outcome)).ok).toBe(true);
  expect(readFileSync(path, "utf8").split("\n").filter(Boolean)).toHaveLength(2);
  const back = await log.read();
  expect(back.ok && back.value).toEqual([decision, outcome]);
});

test("a malformed line fails the read and names the line", async () => {
  env = createTestEnv();
  const path = join(env.stateDir, "decisions.jsonl");
  writeFileSync(path, `${JSON.stringify(decision)}\n{"kind":"outcome","schema":1}\n`);
  const r = await new JsonlRoutingLog(path).read();
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error.message).toContain("decisions.jsonl:2");
});

test("text that is not JSON fails the read", async () => {
  env = createTestEnv();
  const path = join(env.stateDir, "decisions.jsonl");
  writeFileSync(path, "not json\n");
  expect((await new JsonlRoutingLog(path).read()).ok).toBe(false);
});
