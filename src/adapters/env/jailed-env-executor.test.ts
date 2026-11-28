import { afterEach, beforeEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { isolatedRunner } from "../../testing/git-fixture";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { JailedEnvExecutor } from "./jailed-env-executor";

let env: TestEnv;
const runner = isolatedRunner(() => env);
const SCRIPT = join(import.meta.dir, "..", "..", "..", "scripts", "lib", "env-exec.sh");

beforeEach(() => {
  env = createTestEnv();
});
afterEach(() => env.cleanup());

const base = () => ({
  PATH: "/usr/bin:/bin",
  HOME: env.home,
  GH_TOKEN: "secret",
  SW_ENV_NO_JAIL: "1",
});

test("runs the argv in cwd with recipe env added and credentials removed", async () => {
  writeFileSync(
    join(env.root, "probe.sh"),
    'printf "%s|%s|%s|%s" "$PWD" "$FOO" "$GH_TOKEN" "$HOME"\n',
  );
  const exec = new JailedEnvExecutor(runner, SCRIPT, base());
  const r = await exec.run(["bash", "probe.sh"], env.root, { FOO: "bar", HOME: "/evil" }, 30_000);
  expect(r.exitCode).toBe(0);
  expect(r.stdout).toBe(`${env.root}|bar||${env.home}`);
});

test("passes the exit status through and honours the timeout", async () => {
  const exec = new JailedEnvExecutor(runner, SCRIPT, base());
  expect((await exec.run(["false"], env.root, {}, 30_000)).exitCode).toBe(1);
  expect((await exec.run(["sleep", "5"], env.root, {}, 200)).timedOut).toBe(true);
});

test("recipe env cannot set jail or shipwright controls", async () => {
  writeFileSync(
    join(env.root, "probe.sh"),
    'printf "%s|%s|%s" "${SW_TEST_SANDBOX_WRITABLE:-}" "${NODE_OPTIONS:-}" "${GIT_DIR:-}"\n',
  );
  const exec = new JailedEnvExecutor(runner, SCRIPT, base());
  const widen = {
    SW_TEST_SANDBOX_WRITABLE: env.home,
    NODE_OPTIONS: "--require /evil.js",
    GIT_DIR: "/evil",
  };
  const r = await exec.run(["bash", "probe.sh"], env.root, widen, 30_000);
  expect(r.exitCode).toBe(0);
  expect(r.stdout).toBe("||");
});
