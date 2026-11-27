import { randomBytes } from "node:crypto";
import { lstat, mkdir, realpath, rename, rm } from "node:fs/promises";
import { dirname, isAbsolute, join, relative } from "node:path";

/**
 * Resolves repository-relative path `p` under `dir` without following a symlink in any parent
 * component. A checkout an agent edited may hold `vendor -> /somewhere/else`; restoring or saving
 * `vendor/bundle` through it would delete or copy files outside the checkout (ADR-0020). The last
 * component may be a symlink: rm and `cp -P` act on the link itself.
 */
export async function containedPath(
  dir: string,
  p: string,
): Promise<{ ok: true; path: string } | { ok: false; message: string }> {
  const root = await realpath(dir).catch(() => null);
  if (root === null) return { ok: false, message: `no such directory: ${dir}` };
  const parts = p.split("/");
  let cur = root;
  for (const part of parts.slice(0, -1)) {
    cur = join(cur, part);
    const st = await lstat(cur).catch(() => null);
    if (st === null) break;
    if (st.isSymbolicLink() || !st.isDirectory()) {
      return { ok: false, message: `${p}: ${relative(root, cur)} is a symlink or not a directory` };
    }
  }
  return { ok: true, path: join(root, p) };
}

/** True when real path `child` is `parent` or inside it. */
export function inside(parent: string, child: string): boolean {
  const rel = relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

/**
 * Replaces `target` with what `fill(tmp)` writes into a sibling temporary path: the old tree is
 * moved aside, the new one renamed in, then the old one deleted. A fill that fails leaves the
 * target exactly as it was, so a reader never sees half of a `node_modules`.
 */
export async function swapIn(
  target: string,
  root: string,
  fill: (tmp: string) => Promise<{ ok: true } | { ok: false; message: string }>,
): Promise<{ ok: true } | { ok: false; message: string }> {
  await mkdir(dirname(target), { recursive: true });
  const parent = await realpath(dirname(target));
  if (!inside(root, parent)) return { ok: false, message: `${target} leaves ${root}` };
  const tag = randomBytes(6).toString("hex");
  const tmp = `${target}.sw-restore-${tag}`;
  const old = `${target}.sw-old-${tag}`;
  const filled = await fill(tmp);
  if (!filled.ok) {
    await rm(tmp, { recursive: true, force: true }).catch(() => {});
    return filled;
  }
  const hadOld = await lstat(target).then(
    () => true,
    () => false,
  );
  if (hadOld) await rename(target, old);
  await rename(tmp, target);
  if (hadOld) await rm(old, { recursive: true, force: true }).catch(() => {});
  return { ok: true };
}
