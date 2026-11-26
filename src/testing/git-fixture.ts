import { BunProcessRunner } from "../adapters/process/bun-process-runner";
import type { ProcessRunner } from "../shared/kernel/ports";
import type { TestEnv } from "./test-env";

const PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";

/** A runner whose children see only the test HOME and no user or system git config. */
export function isolatedRunner(env: () => TestEnv): ProcessRunner {
  const real = new BunProcessRunner();
  return {
    run: (req) =>
      real.run({
        ...req,
        env: {
          PATH,
          HOME: env().home,
          GIT_CONFIG_NOSYSTEM: "1",
          GIT_CONFIG_GLOBAL: "/dev/null",
          ...req.env,
        },
      }),
  };
}

/** Runs git and returns trimmed stdout; throws on failure. */
export async function gitIn(
  runner: ProcessRunner,
  cwd: string,
  ...args: string[]
): Promise<string> {
  const r = await runner.run({ argv: ["git", ...args], cwd, timeoutMs: 30_000 });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}

/** Commits everything in `cwd` as a fixed author. */
export async function commitAll(
  runner: ProcessRunner,
  cwd: string,
  message: string,
): Promise<void> {
  await gitIn(runner, cwd, "add", "-A");
  await gitIn(
    runner,
    cwd,
    "-c",
    "user.name=t",
    "-c",
    "user.email=t@t",
    "commit",
    "-q",
    "-m",
    message,
  );
}
