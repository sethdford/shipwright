import { afterEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { NO_SIGNALS, type ScoreRecord } from "../../contexts/quality";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { JsonlScoreLog } from "./jsonl-score-log";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());

const rec: ScoreRecord = {
  atMs: 1,
  branch: "ci/issue-1",
  headSha: "abc1234",
  probability: 0.4,
  signals: { ...NO_SIGNALS, criticProbability: 0.3 },
};

test("appends records and reads them back; a missing log is empty", async () => {
  env = createTestEnv();
  const log = new JsonlScoreLog(join(env.stateDir, "verifier", "scores.jsonl"));
  expect(await log.all()).toEqual({ ok: true, value: [] });
  expect((await log.append(rec)).ok).toBe(true);
  expect((await log.append({ ...rec, atMs: 2 })).ok).toBe(true);
  const r = await log.all();
  expect(r.ok && r.value.map((x) => x.atMs)).toEqual([1, 2]);
});

test("a line that is not a score record fails the read, with its line number", async () => {
  env = createTestEnv();
  const path = join(env.stateDir, "scores.jsonl");
  writeFileSync(path, `${JSON.stringify(rec)}\n{"atMs":"x"}\n`);
  const r = await new JsonlScoreLog(path).all();
  expect(r.ok).toBe(false);
  expect(!r.ok && r.error.message).toContain(":2:");
});
