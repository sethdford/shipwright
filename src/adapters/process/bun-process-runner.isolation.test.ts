import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const target = join(import.meta.dir, "bun-process-runner.test.ts");
const leakTestName = "timed-out run leaves no surviving grandchild that ignores SIGTERM";

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  try {
    return readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1]?.[0] !== "Z";
  } catch {
    return true;
  }
}

async function runLeakTestWithStray(): Promise<{ code: number; out: string; strayAlive: boolean }> {
  const stray = Bun.spawn(["sleep", "41"], { stdout: "ignore", stderr: "ignore" });
  try {
    await new Promise((resolve) => setTimeout(resolve, 100));
    const child = Bun.spawn([process.execPath, "test", target, "-t", leakTestName], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    return { code, out: out + err, strayAlive: alive(stray.pid) };
  } finally {
    try {
      stray.kill("SIGKILL");
    } catch {
      // already gone
    }
  }
}

test("AC-1: leak test passes while an unrelated `sleep 41` exists", async () => {
  const r = await runLeakTestWithStray();
  expect(r.out).toContain("1 pass");
  expect(r.code).toBe(0);
}, 30000);

test("AC-2: leak test does not kill an unrelated `sleep 41`", async () => {
  const r = await runLeakTestWithStray();
  expect(r.strayAlive).toBe(true);
}, 30000);

test("AC-3: leak test source does not use pgrep or pkill", () => {
  const src = readFileSync(target, "utf8");
  const start = src.indexOf(leakTestName);
  expect(start).toBeGreaterThan(-1);
  const rest = src.slice(start);
  const end = rest.indexOf("\nasync function withKillSpy");
  const body = end > 0 ? rest.slice(0, end) : rest;
  expect(body).not.toMatch(/pgrep|pkill/);
});
