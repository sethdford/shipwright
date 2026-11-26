import { randomBytes } from "node:crypto";
import { lstat, mkdir, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { type CacheEntry, type EnvCache, relPathProblem } from "../../contexts/platform";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { cowCopy, treeBytes } from "./cow-copy";

const REPO_ID = /^[a-z0-9-]{1,80}$/;
const KEY = /^[0-9a-f]{32}$/;
const MANIFEST = "manifest.json";

export interface FsEnvCacheOptions {
  /** `process.platform`; decides how copies are cloned (tests force the plain fallback). */
  readonly platform: string;
  readonly now?: () => Date;
}

/**
 * Built environments on disk (ADR-0020): `<root>/<repoId>/<key>/{manifest.json, files/...}`.
 * An entry is assembled in a staging directory beside it and renamed into place, so a reader sees
 * either all of it or nothing.
 */
export class FsEnvCache implements EnvCache {
  private readonly now: () => Date;

  constructor(
    private readonly runner: ProcessRunner,
    private readonly root: string,
    private readonly options: FsEnvCacheOptions,
  ) {
    this.now = options.now ?? (() => new Date());
  }

  dirFor(repoId: string, key: string): string {
    return join(this.root, repoId, key);
  }

  async get(repoId: string, key: string): Promise<Result<CacheEntry | null, AdapterError>> {
    const bad = idProblem(repoId, key);
    if (bad) return err(bad);
    return ok(await readManifest(this.dirFor(repoId, key), repoId, key));
  }

  async restore(entry: CacheEntry, dir: string): Promise<Result<void, AdapterError>> {
    const bad = idProblem(entry.repoId, entry.key) ?? pathsProblem(entry.paths);
    if (bad) return err(bad);
    const src = this.dirFor(entry.repoId, entry.key);
    for (const p of entry.paths) {
      const from = join(src, "files", p);
      if (!(await exists(from))) continue;
      const to = join(dir, p);
      try {
        await rm(to, { recursive: true, force: true });
        await mkdir(dirname(to), { recursive: true });
      } catch (cause) {
        return err({ kind: "failed", message: `restore ${p}: ${String(cause)}` });
      }
      const copied = await cowCopy(this.runner, this.options.platform, from, to);
      if (!copied.ok) return err({ kind: "failed", message: `restore ${p}: ${copied.message}` });
    }
    await this.touch(src, entry).catch(() => {});
    return ok(undefined);
  }

  async save(
    repoId: string,
    key: string,
    dir: string,
    paths: readonly string[],
  ): Promise<Result<"saved" | "exists", AdapterError>> {
    const bad = idProblem(repoId, key) ?? pathsProblem(paths);
    if (bad) return err(bad);
    const final = this.dirFor(repoId, key);
    if (await exists(final)) {
      if ((await readManifest(final, repoId, key)) !== null) return ok("exists");
      // A renamed-in entry always has a manifest: one without a readable manifest is broken.
      await rm(final, { recursive: true, force: true }).catch(() => {});
    }
    const staging = join(
      this.root,
      repoId,
      `.staging-${key}-${process.pid}-${randomBytes(6).toString("hex")}`,
    );
    try {
      const saved = await this.stage(staging, repoId, key, dir, paths);
      if (!saved.ok) return saved;
      if (await exists(final)) return ok("exists");
      await rename(staging, final);
      return ok("saved");
    } catch (cause) {
      if (await exists(final)) return ok("exists");
      return err({ kind: "failed", message: `save ${key}: ${String(cause)}` });
    } finally {
      await rm(staging, { recursive: true, force: true }).catch(() => {});
    }
  }

  async list(repoId: string): Promise<Result<readonly CacheEntry[], AdapterError>> {
    if (!REPO_ID.test(repoId))
      return err({ kind: "failed", message: `invalid repo id: ${repoId}` });
    let names: string[];
    try {
      names = await readdir(join(this.root, repoId));
    } catch (cause) {
      if ((cause as { code?: string }).code === "ENOENT") return ok([]);
      return err({ kind: "failed", message: String(cause) });
    }
    const entries: CacheEntry[] = [];
    for (const name of names.filter((n) => KEY.test(n)).sort()) {
      const entry = await readManifest(this.dirFor(repoId, name), repoId, name);
      if (entry !== null) entries.push(entry);
    }
    return ok(entries);
  }

  async remove(repoId: string, key: string): Promise<Result<void, AdapterError>> {
    const bad = idProblem(repoId, key);
    if (bad) return err(bad);
    try {
      await rm(this.dirFor(repoId, key), { recursive: true, force: true });
      return ok(undefined);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }

  /** Copies the paths that exist and writes the manifest into `staging`. */
  private async stage(
    staging: string,
    repoId: string,
    key: string,
    dir: string,
    paths: readonly string[],
  ): Promise<Result<void, AdapterError>> {
    await mkdir(join(staging, "files"), { recursive: true });
    const kept: string[] = [];
    for (const p of paths) {
      if (!(await exists(join(dir, p)))) continue;
      const to = join(staging, "files", p);
      await mkdir(dirname(to), { recursive: true });
      const copied = await cowCopy(this.runner, this.options.platform, join(dir, p), to);
      if (!copied.ok) return err({ kind: "failed", message: `save ${p}: ${copied.message}` });
      kept.push(p);
    }
    const at = this.now().toISOString();
    const bytes = await treeBytes(join(staging, "files"));
    const entry: CacheEntry = { repoId, key, createdAt: at, usedAt: at, bytes, paths: kept };
    await writeFile(join(staging, MANIFEST), `${JSON.stringify(entry, null, 2)}\n`);
    return ok(undefined);
  }

  /** Rewrites the manifest with a new `usedAt` (temp file + rename). */
  private async touch(dir: string, entry: CacheEntry): Promise<void> {
    const current = (await readManifest(dir, entry.repoId, entry.key)) ?? entry;
    const tmp = join(dir, `.${MANIFEST}.${process.pid}-${randomBytes(4).toString("hex")}`);
    await writeFile(
      tmp,
      `${JSON.stringify({ ...current, usedAt: this.now().toISOString() }, null, 2)}\n`,
    );
    await rename(tmp, join(dir, MANIFEST));
  }
}

function idProblem(repoId: string, key: string): AdapterError | null {
  if (!REPO_ID.test(repoId)) return { kind: "failed", message: `invalid repo id: ${repoId}` };
  if (!KEY.test(key)) return { kind: "failed", message: `invalid cache key: ${key}` };
  return null;
}

function pathsProblem(paths: readonly string[]): AdapterError | null {
  for (const p of paths) {
    const bad = relPathProblem(p);
    if (bad) return { kind: "failed", message: `refusing cache path ${p}: ${bad}` };
  }
  return null;
}

async function exists(path: string): Promise<boolean> {
  return lstat(path).then(
    () => true,
    () => false,
  );
}

/** The entry described by `dir/manifest.json`, or null when it is missing or does not match. */
async function readManifest(dir: string, repoId: string, key: string): Promise<CacheEntry | null> {
  try {
    const m = JSON.parse(await readFile(join(dir, MANIFEST), "utf8")) as Partial<CacheEntry>;
    const valid =
      m.repoId === repoId &&
      m.key === key &&
      typeof m.createdAt === "string" &&
      typeof m.usedAt === "string" &&
      typeof m.bytes === "number" &&
      Array.isArray(m.paths) &&
      m.paths.every((p) => typeof p === "string" && relPathProblem(p) === null);
    return valid ? (m as CacheEntry) : null;
  } catch {
    return null;
  }
}
