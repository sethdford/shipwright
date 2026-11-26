import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import { extractFacts } from "../domain/extract";
import { contentHash } from "../domain/hash";
import {
  EXTRACTOR_VERSION,
  type FileEntry,
  indexable,
  isTestPath,
  MODEL_SCHEMA,
  type RepoModel,
} from "../domain/model";
import type { RepoModelPorts, SourceFileStat } from "../ports";

export const MAX_FILE_BYTES = 512 * 1024;
const AUTHOR_COMMITS = 400;
const BATCH = 32;
const CODEOWNERS_PATHS = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"];

export interface RefreshStats {
  readonly files: number;
  readonly reused: number;
  readonly extracted: number;
  readonly removed: number;
  readonly skipped: number;
}

export interface Refreshed {
  readonly model: RepoModel;
  readonly stats: RefreshStats;
  /** False when nothing changed since the stored model (it was not written again). */
  readonly changed: boolean;
}

type Outcome = { entry: FileEntry; fresh: boolean; touched: boolean } | undefined;

async function entryFor(
  ports: RepoModelPorts,
  root: string,
  stat: SourceFileStat,
  prev: FileEntry | undefined,
): Promise<Outcome> {
  if (prev && prev.size === stat.size && prev.mtimeMs === stat.mtimeMs)
    return { entry: prev, fresh: false, touched: false };
  const text = await ports.source.read(root, stat.path);
  if (!text.ok || text.value.includes("\0")) return undefined;
  const hash = contentHash(text.value);
  if (prev && prev.hash === hash)
    return {
      entry: { ...prev, size: stat.size, mtimeMs: stat.mtimeMs },
      fresh: false,
      touched: true,
    };
  const facts = extractFacts(stat.path, text.value);
  const entry = {
    ...facts,
    path: stat.path,
    hash,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    test: isTestPath(stat.path),
  };
  return { entry, fresh: true, touched: true };
}

async function readCodeowners(ports: RepoModelPorts, root: string, listed: ReadonlySet<string>) {
  for (const p of CODEOWNERS_PATHS) {
    if (!listed.has(p)) continue;
    const r = await ports.source.read(root, p);
    if (r.ok) return r.value;
  }
  return "";
}

async function authorsFor(
  ports: RepoModelPorts,
  root: string,
  head: string,
  prev: RepoModel | undefined,
) {
  if (prev && prev.head === head) return prev.authors;
  const r = await ports.source.authorship(root, AUTHOR_COMMITS);
  return r.ok ? r.value : {};
}

async function collect(
  ports: RepoModelPorts,
  root: string,
  stats: readonly SourceFileStat[],
  prev?: RepoModel,
) {
  const before = new Map((prev?.files ?? []).map((f) => [f.path, f] as const));
  const wanted = stats.filter((s) => indexable(s.path) && s.size <= MAX_FILE_BYTES);
  const files: FileEntry[] = [];
  let extracted = 0;
  let touched = 0;
  for (let i = 0; i < wanted.length; i += BATCH) {
    const batch = wanted.slice(i, i + BATCH);
    const outcomes = await Promise.all(
      batch.map((s) => entryFor(ports, root, s, before.get(s.path))),
    );
    for (const o of outcomes) {
      if (!o) continue;
      files.push(o.entry);
      if (o.fresh) extracted += 1;
      if (o.touched) touched += 1;
    }
  }
  files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const kept = new Set(files.map((f) => f.path));
  const removed = [...before.keys()].filter((p) => !kept.has(p)).length;
  return { files, extracted, touched, removed, skipped: stats.length - wanted.length };
}

/**
 * Brings the stored model up to date with the working tree. Unchanged files (same size and mtime, or same
 * content hash) are reused as they are; only new and edited files are read and extracted again, so a refresh
 * between agent turns costs a directory listing plus the edited files.
 */
export async function refreshModel(
  ports: RepoModelPorts,
  root: string,
): Promise<Result<Refreshed, AdapterError>> {
  const listed = await ports.source.list(root);
  if (!listed.ok) return err(listed.error);
  const loaded = await ports.store.load(root);
  const current = loaded?.schema === MODEL_SCHEMA && loaded.extractor === EXTRACTOR_VERSION;
  const prev = current && loaded.root === root ? loaded : undefined;
  const head = await ports.source.head(root);
  const { files, extracted, touched, removed, skipped } = await collect(
    ports,
    root,
    listed.value,
    prev,
  );
  const changed = !prev || extracted > 0 || removed > 0 || prev.head !== head;
  const model: RepoModel = changed
    ? {
        schema: MODEL_SCHEMA,
        extractor: EXTRACTOR_VERSION,
        root,
        builtAt: ports.now(),
        head,
        files,
        codeowners: await readCodeowners(ports, root, new Set(listed.value.map((s) => s.path))),
        authors: await authorsFor(ports, root, head, prev),
      }
    : { ...prev, files };
  if (changed || touched > 0) await ports.store.save(model);
  const stats = {
    files: files.length,
    reused: files.length - extracted,
    extracted,
    removed,
    skipped,
  };
  return ok({ model, stats, changed });
}
