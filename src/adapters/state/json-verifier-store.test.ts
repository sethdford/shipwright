import { expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { NO_EVIDENCE, PRIOR_MODEL } from "../../contexts/quality";
import { createTestEnv } from "../../testing/test-env";
import { JsonVerifierStore } from "./json-verifier-store";

test("missing file is null; save then load round-trips", async () => {
  const env = createTestEnv();
  try {
    const store = new JsonVerifierStore(join(env.stateDir, "verifier", "model.json"));
    expect(await store.load()).toEqual({ ok: true, value: null });
    const v = { model: PRIOR_MODEL, evidence: NO_EVIDENCE };
    expect((await store.save(v)).ok).toBe(true);
    expect(await store.load()).toEqual({ ok: true, value: v });
  } finally {
    env.cleanup();
  }
});

test("a file that is not a verifier model is an error, not the prior", async () => {
  const env = createTestEnv();
  try {
    const dir = join(env.stateDir, "verifier");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "model.json"), JSON.stringify({ model: { version: 2 } }));
    const r = await new JsonVerifierStore(join(dir, "model.json")).load();
    expect(r.ok).toBe(false);
    writeFileSync(join(dir, "model.json"), "{");
    expect((await new JsonVerifierStore(join(dir, "model.json")).load()).ok).toBe(false);
  } finally {
    env.cleanup();
  }
});
