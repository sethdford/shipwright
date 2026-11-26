import { afterEach, describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { modelOf } from "../../testing/repo-model-fixture";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { JsonModelStore } from "./json-model-store";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());

describe("JsonModelStore", () => {
  test("round-trips a model keyed by its root", async () => {
    env = createTestEnv();
    const store = new JsonModelStore(join(env.stateDir, "repo-model"));
    const model = modelOf({ "src/a.ts": "export function a() {}\n" });
    expect(await store.load("/repo")).toBeUndefined();
    expect((await store.save(model)).ok).toBe(true);
    expect(await store.load("/repo")).toEqual(model);
    expect(await store.load("/other")).toBeUndefined();
  });

  test("a corrupt or foreign file reads as no model", async () => {
    env = createTestEnv();
    const store = new JsonModelStore(env.stateDir);
    await store.save(modelOf({}));
    writeFileSync(store.fileFor("/repo"), "{not json");
    expect(await store.load("/repo")).toBeUndefined();
    writeFileSync(store.fileFor("/repo"), JSON.stringify({ schema: 99 }));
    expect(await store.load("/repo")).toBeUndefined();
  });
});
