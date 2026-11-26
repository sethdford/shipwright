import { lstat, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { ProcessRunner } from "../../shared/kernel/ports";
import { runOrFail } from "../process/run-or-fail";

const COPY_TIMEOUT_MS = 30 * 60_000;

/**
 * The `cp` argv lists to try, in order, for a copy that keeps symlinks as symlinks
 * (node_modules/.bin) and is a copy-on-write clone where the filesystem can do it.
 */
export function copyCommands(platform: string, src: string, dst: string): string[][] {
  const plain = ["cp", "-R", "-P", "-p", src, dst];
  if (platform === "darwin") return [["cp", "-c", "-R", "-P", "-p", src, dst], plain];
  if (platform === "linux") return [["cp", "-a", "--reflink=auto", src, dst], plain];
  return [plain];
}

/** Copies `src` (a file, symlink or directory) to `dst`, which must not exist yet. */
export async function cowCopy(
  runner: ProcessRunner,
  platform: string,
  src: string,
  dst: string,
): Promise<{ ok: true } | { ok: false; message: string }> {
  let message = "";
  for (const argv of copyCommands(platform, src, dst)) {
    await rm(dst, { recursive: true, force: true });
    const r = await runOrFail(runner, { argv, timeoutMs: COPY_TIMEOUT_MS });
    if (r.exitCode === 0 && !r.timedOut) return { ok: true };
    message = r.timedOut ? `${argv[0]} timed out` : r.stderr.trim() || `cp exited ${r.exitCode}`;
  }
  return { ok: false, message };
}

/** Bytes under `path`, counting symlinks as themselves (never followed). */
export async function treeBytes(path: string): Promise<number> {
  const st = await lstat(path);
  if (!st.isDirectory()) return st.size;
  let total = 0;
  for (const name of await readdir(path)) total += await treeBytes(join(path, name));
  return total;
}
