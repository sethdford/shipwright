import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ProofBranchWriter, ProofUpload } from "../../contexts/integrations";
import { ok } from "../../shared/kernel/result";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { GitProofPublisher, labelSlug, listFiles } from "./git-proof-publisher";

let env: TestEnv;
let dir: string;
beforeEach(() => {
  env = createTestEnv();
  dir = join(env.root, "out");
  mkdirSync(join(dir, "web", ".video"), { recursive: true });
  writeFileSync(join(dir, "web", "1-home.png"), "png");
  writeFileSync(join(dir, "web", ".video", "raw.webm"), "x");
  writeFileSync(join(dir, ".env"), "SECRET=1");
  writeFileSync(join(dir, "cli-1.txt"), "out");
});
afterEach(() => env.cleanup());

test("lists plain files only: dot-files and dot-dirs never leave the machine", () => {
  expect(listFiles(dir)).toEqual(["cli-1.txt", "web/1-home.png"]);
});

test("labels become safe folder names", () => {
  expect(labelSlug("feat/login page")).toBe("feat-login-page");
  expect(labelSlug("../..")).toBe("run");
});

test("publishes under label/content-hash with a matching key, so a repeat is idempotent", async () => {
  const calls: { key: string; upload: ProofUpload }[] = [];
  const writer: ProofBranchWriter = {
    publishProof: async (key, upload) => {
      calls.push({ key, upload });
      return ok({ commit: "c", baseUrl: `https://x/${upload.prefix}/`, action: "created" });
    },
  };
  const p = new GitProofPublisher(writer, "/repo");
  const a = await p.publish(dir, "feat/x");
  const b = await p.publish(dir, "feat/x");
  expect(a.ok && a.value).toMatch(/^https:\/\/x\/feat-x\/[0-9a-f]{12}\/$/);
  expect(calls[0]?.key).toBe(calls[1]?.key ?? "");
  expect(calls[0]?.upload.files).toEqual(["cli-1.txt", "web/1-home.png"]);
  writeFileSync(join(dir, "cli-1.txt"), "changed");
  await p.publish(dir, "feat/x");
  expect(calls[2]?.key).not.toBe(calls[0]?.key ?? "");
});
