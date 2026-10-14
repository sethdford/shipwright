import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { Paths } from "../shared/kernel/ports";

export interface TestEnv extends Paths {
  readonly root: string;
  cleanup(): void;
}

/** Isolated HOME, state dir and tmux socket for one test (spec rule F8). */
export function createTestEnv(): TestEnv {
  const root = mkdtempSync(join(tmpdir(), "sw-test-"));
  const home = join(root, "home");
  const stateDir = join(home, ".shipwright");
  mkdirSync(stateDir, { recursive: true });
  return {
    root,
    home,
    stateDir,
    tmuxSocketName: `sw-test-${basename(root)}`,
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  };
}
