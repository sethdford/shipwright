import { afterEach, beforeEach, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import type { CacheEntry } from "../../contexts/platform";
import { isolatedRunner } from "../../testing/git-fixture";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { copyCommands } from "./cow-copy";
import { FsEnvCache } from "./fs-env-cache";

let env: TestEnv;
let work: string;
const runner = isolatedRunner(() => env);
const REPO = "my-repo-0123456789abcdef";
const KEY = "0123456789abcdef0123456789abcdef";

function cache(platform = "test-fallback"): FsEnvCache {
  return new FsEnvCache(runner, join(env.stateDir, "env-cache"), { platform });
}

beforeEach(() => {
  env = createTestEnv();
  work = join(env.root, "work");
  mkdirSync(join(work, "node_modules", "pkg", "lib"), { recursive: true });
  mkdirSync(join(work, "node_modules", ".bin"), { recursive: true });
  writeFileSync(join(work, "node_modules", "pkg", "lib", "index.js"), "module.exports = 1;\n");
  symlinkSync("../pkg/lib/index.js", join(work, "node_modules", ".bin", "pkg"));
  mkdirSync(join(work, "tools", "venv"), { recursive: true });
  writeFileSync(join(work, "tools", "venv", "cfg"), "x\n");
});
afterEach(() => env.cleanup());

async function savedEntry(c: FsEnvCache): Promise<CacheEntry> {
  const saved = await c.save(REPO, KEY, work, ["node_modules", "tools/venv", "missing"]);
  expect(saved).toEqual({ ok: true, value: "saved" });
  const got = await c.get(REPO, KEY);
  if (!got.ok || got.value === null) throw new Error("entry not found");
  return got.value;
}

for (const platform of ["test-fallback", process.platform]) {
  test(`save, get and restore round-trip a nested dir and a symlink (${platform})`, async () => {
    const c = cache(platform);
    const entry = await savedEntry(c);
    expect(entry.paths).toEqual(["node_modules", "tools/venv"]);
    expect(entry.bytes).toBeGreaterThan(0);
    const fresh = join(env.root, "fresh");
    mkdirSync(join(fresh, "node_modules", "stale"), { recursive: true });
    expect(await c.restore(entry, fresh)).toEqual({ ok: true, value: undefined });
    expect(existsSync(join(fresh, "node_modules", "stale"))).toBe(false);
    expect(readFileSync(join(fresh, "node_modules", "pkg", "lib", "index.js"), "utf8")).toBe(
      "module.exports = 1;\n",
    );
    const bin = join(fresh, "node_modules", ".bin", "pkg");
    expect(lstatSync(bin).isSymbolicLink()).toBe(true);
    expect(readlinkSync(bin)).toBe("../pkg/lib/index.js");
    expect(readFileSync(join(fresh, "tools", "venv", "cfg"), "utf8")).toBe("x\n");
  });
}

test("a second save of the same key reports exists", async () => {
  const c = cache();
  await savedEntry(c);
  expect(await c.save(REPO, KEY, work, ["node_modules"])).toEqual({ ok: true, value: "exists" });
});

test("restore updates usedAt", async () => {
  let t = Date.parse("2026-01-01T00:00:00Z");
  const c = new FsEnvCache(runner, join(env.stateDir, "env-cache"), {
    platform: "test-fallback",
    now: () => new Date(t),
  });
  const entry = await savedEntry(c);
  t += 60_000;
  mkdirSync(join(env.root, "fresh"));
  expect((await c.restore(entry, join(env.root, "fresh"))).ok).toBe(true);
  const again = await c.get(REPO, KEY);
  expect(again.ok && again.value?.usedAt).toBe("2026-01-01T00:01:00.000Z");
  expect(again.ok && again.value?.createdAt).toBe("2026-01-01T00:00:00.000Z");
});

test("list skips staging and broken entries; remove deletes one", async () => {
  const c = cache();
  await savedEntry(c);
  const root = join(env.stateDir, "env-cache", REPO);
  mkdirSync(join(root, `.staging-${KEY}-1-abc`));
  mkdirSync(join(root, "ffffffffffffffffffffffffffffffff"));
  const listed = await c.list(REPO);
  expect(listed.ok && listed.value.map((e) => e.key)).toEqual([KEY]);
  expect(await c.list("other-repo")).toEqual({ ok: true, value: [] });
  expect((await c.remove(REPO, KEY)).ok).toBe(true);
  expect(await c.get(REPO, KEY)).toEqual({ ok: true, value: null });
});

test("a broken entry is replaced by the next save", async () => {
  const c = cache();
  mkdirSync(c.dirFor(REPO, KEY), { recursive: true });
  expect(await c.get(REPO, KEY)).toEqual({ ok: true, value: null });
  expect(await c.save(REPO, KEY, work, ["node_modules"])).toEqual({ ok: true, value: "saved" });
});

test("invalid keys, repo ids and paths are refused before touching the filesystem", async () => {
  const c = cache();
  expect((await c.get(REPO, "../../etc")).ok).toBe(false);
  expect((await c.get("../x", KEY)).ok).toBe(false);
  expect((await c.save(REPO, KEY.toUpperCase(), work, ["node_modules"])).ok).toBe(false);
  expect((await c.save(REPO, KEY, work, ["../outside"])).ok).toBe(false);
  expect((await c.remove(REPO, "abc")).ok).toBe(false);
  expect(existsSync(join(env.stateDir, "env-cache"))).toBe(false);
});

test("copies are clones where the platform supports them", () => {
  expect(copyCommands("darwin", "a", "b")[0]).toEqual(["cp", "-c", "-R", "-P", "-p", "a", "b"]);
  expect(copyCommands("linux", "a", "b")[0]).toEqual(["cp", "-a", "--reflink=auto", "a", "b"]);
  expect(copyCommands("freebsd", "a", "b")).toEqual([["cp", "-R", "-P", "-p", "a", "b"]]);
});

test("restore refuses a symlinked parent instead of writing through it", async () => {
  const c = cache();
  const entry = await savedEntry(c);
  const outside = join(env.root, "outside");
  mkdirSync(join(outside, "venv"), { recursive: true });
  writeFileSync(join(outside, "venv", "keep"), "mine\n");
  const agent = join(env.root, "agent");
  mkdirSync(agent);
  symlinkSync(outside, join(agent, "tools"));
  const r = await c.restore(entry, agent);
  expect(r.ok).toBe(false);
  expect(readFileSync(join(outside, "venv", "keep"), "utf8")).toBe("mine\n");
});

test("save refuses a symlinked parent", async () => {
  const outside = join(env.root, "outside");
  mkdirSync(join(outside, "venv"), { recursive: true });
  const agent = join(env.root, "agent");
  mkdirSync(agent);
  symlinkSync(outside, join(agent, "tools"));
  expect((await cache().save(REPO, KEY, agent, ["tools/venv"])).ok).toBe(false);
});

test("a restore that cannot copy leaves the target as it was", async () => {
  const c = cache();
  const entry = await savedEntry(c);
  const fresh = join(env.root, "fresh");
  mkdirSync(join(fresh, "node_modules", "old"), { recursive: true });
  rmSync(join(env.stateDir, "env-cache", REPO, KEY, "files", "node_modules", "pkg"), {
    recursive: true,
  });
  chmodSync(join(env.stateDir, "env-cache", REPO, KEY, "files", "node_modules"), 0o000);
  const r = await c.restore(entry, fresh);
  chmodSync(join(env.stateDir, "env-cache", REPO, KEY, "files", "node_modules"), 0o755);
  if (process.getuid?.() !== 0) expect(r.ok).toBe(false);
  expect(existsSync(join(fresh, "node_modules", r.ok ? ".bin" : "old"))).toBe(true);
});
