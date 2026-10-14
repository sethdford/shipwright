import { expect, test } from "bun:test";
import { dirname, resolve } from "node:path";
import { createTestEnv } from "../../src/testing/test-env";

const ROOT = resolve(import.meta.dir, "../..");

// scripts/sw routes ported commands to `bun src/cli.ts`, so the TypeScript sources must ship.
const REQUIRED = [
  "src/cli.ts",
  "src/main.ts",
  "src/cli/commands/hello.ts",
  "package.json",
  "scripts/sw",
];

function packedFiles(): string[] {
  const npm = Bun.which("npm");
  const node = Bun.which("node");
  if (!npm || !node) throw new Error("npm and node must be on PATH to check the package contents");
  const env = createTestEnv();
  try {
    const proc = Bun.spawnSync([npm, "pack", "--dry-run", "--json", "--ignore-scripts"], {
      cwd: ROOT,
      env: {
        HOME: env.home,
        PATH: `${dirname(node)}:${dirname(npm)}:/usr/bin:/bin`,
        npm_config_cache: `${env.root}/npm-cache`,
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    if (proc.exitCode !== 0) throw new Error(`npm pack failed: ${proc.stderr.toString()}`);
    const [pack] = JSON.parse(proc.stdout.toString()) as [{ files: { path: string }[] }];
    return pack.files.map((f) => f.path);
  } finally {
    env.cleanup();
  }
}

test(
  "the npm package ships the TypeScript CLI but no tests or test helpers",
  () => {
    const files = packedFiles();
    for (const path of REQUIRED) expect(files).toContain(path);
    expect(files.filter((f) => f.startsWith("src/") && f.endsWith(".test.ts"))).toEqual([]);
    expect(files.filter((f) => f.startsWith("src/testing/"))).toEqual([]);
  },
  { timeout: 60_000 },
);
