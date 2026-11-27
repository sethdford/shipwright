import { afterEach, beforeEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { GatedAppLauncher, urlFromOutput } from "./gated-app-launcher";

// The real gate script and a real server: the credential scrub and process-group kill are what
// this adapter is for, so they are tested against bash and the OS, not a script of them.
const GATE = join(import.meta.dir, "..", "..", "..", "scripts", "lib", "test-gate-exec.sh");
const PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";
let env: TestEnv;
beforeEach(() => {
  env = createTestEnv();
  writeFileSync(
    join(env.root, "server.ts"),
    `Bun.serve({ port: Number(process.env.PORT), hostname: "127.0.0.1",
      fetch: () => new Response("token:" + (process.env.GITHUB_TOKEN ?? "none")) });
     console.log("listening on http://localhost:" + process.env.PORT);`,
  );
});
afterEach(() => env.cleanup());

const launcher = () =>
  new GatedAppLauncher(GATE, env.root, {
    PATH,
    HOME: env.home,
    GITHUB_TOKEN: "ghp_must_not_reach_the_app_000000000000",
  });

test("dev-server URLs are read from output, colours and all", () => {
  expect(urlFromOutput("\u001b[32m  ➜  Local:   http://localhost:5173/\u001b[0m")).toBe(
    "http://localhost:5173",
  );
  expect(urlFromOutput("ready on 0.0.0.0? http://0.0.0.0:3000")).toBe("http://127.0.0.1:3000");
  expect(urlFromOutput("see https://example.com:8080")).toBeNull();
});

test("starts the app without credentials, answers, and stops the whole group", async () => {
  const l = launcher();
  const port = await l.freePort();
  const started = await l.start({
    argv: [process.execPath, "server.ts"],
    port,
    url: null,
    readyPath: "/",
    readyTimeoutMs: 20_000,
  });
  expect(started.ok).toBe(true);
  if (!started.ok) return;
  const body = await (await fetch(`${started.app.url}/`)).text();
  expect(body).toBe("token:none");
  expect(started.app.log()).toContain("listening on");
  await started.app.stop();
  await expect(fetch(`${started.app.url}/`)).rejects.toThrow();
}, 30_000);

test("a start command that exits is a failure with its output", async () => {
  const l = launcher();
  const r = await l.start({
    argv: [process.execPath, "-e", "console.error('no DATABASE_URL'); process.exit(3)"],
    port: await l.freePort(),
    url: null,
    readyPath: "/",
    readyTimeoutMs: 10_000,
  });
  expect(r.ok).toBe(false);
  if (r.ok) return;
  expect(r.reason).toContain("exited with code 3");
  expect(r.log).toContain("no DATABASE_URL");
}, 20_000);

test("an app that never answers times out", async () => {
  const l = launcher();
  const r = await l.start({
    argv: ["sleep", "30"],
    port: await l.freePort(),
    url: null,
    readyPath: "/",
    readyTimeoutMs: 1_500,
  });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toContain("nothing answered");
}, 20_000);

test("a port another server holds is refused before anything starts", async () => {
  const other = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("other") });
  try {
    const r = await launcher().start({
      argv: ["sleep", "30"],
      port: Number(other.port),
      url: null,
      readyPath: "/",
      readyTimeoutMs: 5_000,
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe(`port ${other.port} is already in use`);
  } finally {
    other.stop(true);
  }
});
