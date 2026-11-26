import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ProofBranchWriter, ProofUpload } from "../../contexts/integrations";
import { ok } from "../../shared/kernel/result";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { GitProofPublisher, labelSlug, readRegular } from "./git-proof-publisher";

let env: TestEnv;
let dir: string;
const sha = (text: string) => createHash("sha256").update(text).digest("hex");
const staged: { key: string; upload: ProofUpload; bytes: string[] }[] = [];
const writer: ProofBranchWriter = {
  publishProof: async (key, upload) => {
    const { readFileSync } = await import("node:fs");
    const bytes = upload.files.map((f) => readFileSync(join(upload.dir, f), "utf8"));
    staged.push({ key, upload, bytes });
    return ok({ commit: "c", baseUrl: `https://x/${upload.prefix}/`, action: "created" });
  },
};

beforeEach(() => {
  env = createTestEnv();
  staged.length = 0;
  dir = join(env.root, "out");
  mkdirSync(join(dir, "web"), { recursive: true });
  writeFileSync(join(dir, "web", "1-home.png"), "png");
  writeFileSync(join(dir, "cli-1.txt"), "out");
  writeFileSync(join(env.root, "secret"), "TOKEN");
});
afterEach(() => env.cleanup());

const files = () => [
  { path: "web/1-home.png", sha256: sha("png") },
  { path: "cli-1.txt", sha256: sha("out") },
];

test("labels become safe folder names", () => {
  expect(labelSlug("feat/login page")).toBe("feat-login-page");
  expect(labelSlug("../..")).toBe("run");
});

test("publishes verified copies under label/content-hash; a repeat has the same key", async () => {
  const p = new GitProofPublisher(writer, "/repo");
  const a = await p.publish(dir, "feat/x", files());
  await p.publish(dir, "feat/x", files());
  expect(a.ok && a.value).toMatch(/^https:\/\/x\/feat-x\/[0-9a-f]{12}\/$/);
  expect(staged[0]?.upload.files).toEqual(["cli-1.txt", "web/1-home.png"]);
  expect(staged[0]?.bytes).toEqual(["out", "png"]);
  expect(staged[0]?.upload.dir).not.toBe(dir);
  expect(staged[1]?.key).toBe(staged[0]?.key ?? "");
});

test("a file changed after the run wrote it stops the whole publish", async () => {
  writeFileSync(join(dir, "cli-1.txt"), "TOKEN");
  const r = await new GitProofPublisher(writer, "/repo").publish(dir, "x", files());
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error.message).toContain("cli-1.txt changed after the run wrote it");
  expect(staged).toEqual([]);
});

test("symlinks and odd paths are never followed or published", async () => {
  symlinkSync(join(env.root, "secret"), join(dir, "link.txt"));
  expect(readRegular(join(dir, "link.txt"))).toBeNull();
  const r = await new GitProofPublisher(writer, "/repo").publish(dir, "x", [
    { path: "link.txt", sha256: sha("TOKEN") },
    { path: "../secret", sha256: sha("TOKEN") },
    { path: ".env", sha256: sha("x") },
  ]);
  expect(r.ok).toBe(false);
  expect(staged).toEqual([]);
});
