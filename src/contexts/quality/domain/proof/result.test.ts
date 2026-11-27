import { expect, test } from "bun:test";
import { type CliResult, type FlowResult, judgeProof, proofBlocks, type WebResult } from "./result";

const flow = (over: Partial<FlowResult> = {}): FlowResult => ({
  name: "home",
  steps: [{ step: "goto /", ok: true }],
  screenshots: [],
  video: null,
  consoleErrors: [],
  pageErrors: [],
  httpErrors: [],
  blocked: [],
  ...over,
});
const ran = (...flows: FlowResult[]): WebResult => ({
  status: "ran",
  url: "http://127.0.0.1:1",
  flows,
  serverLog: "web/server.log",
});
const cli = (exitCode: number, timedOut = false): CliResult => ({
  name: "help",
  argv: ["x"],
  exitCode,
  expectExit: 0,
  timedOut,
  transcript: "cli/1.txt",
});

test("a clean run passes; console errors are only noted", () => {
  const v = judgeProof(ran(flow({ consoleErrors: ["favicon 404"] })), [cli(0)]);
  expect(v.status).toBe("pass");
  expect(v.warnings).toEqual(["1 console error(s) logged"]);
});

test("failed steps, page errors, 5xx, bad exits and timeouts fail", () => {
  const v = judgeProof(
    ran(
      flow({ steps: [{ step: "click #go", ok: false, error: "timeout" }] }),
      flow({ name: "b", pageErrors: ["TypeError"], httpErrors: [{ url: "/api", status: 500 }] }),
    ),
    [cli(2), cli(0, true)],
  );
  expect(v.status).toBe("fail");
  expect(v.failures).toEqual([
    'home: step "click #go" failed: timeout',
    "b: 1 uncaught page error(s)",
    "b: 1 server error response(s)",
    "help: exited 2, expected 0",
    "help: timed out",
  ]);
});

test("an app that does not start fails; no browser or nothing to run is skipped", () => {
  expect(judgeProof({ status: "start_failed", reason: "exit 1", serverLog: "l" }, []).status).toBe(
    "fail",
  );
  const nobrowser = judgeProof(
    { status: "browser_unavailable", reason: "no chromium", serverLog: "l" },
    [],
  );
  expect(nobrowser).toEqual({ status: "skipped", failures: [], warnings: ["no chromium"] });
  expect(judgeProof(null, []).status).toBe("skipped");
  expect(
    judgeProof({ status: "browser_unavailable", reason: "x", serverLog: "l" }, [cli(0)]).status,
  ).toBe("pass");
});

test("only enforce blocks, and only a failure", () => {
  const fail = judgeProof(null, [cli(1)]);
  expect(proofBlocks("enforce", fail)).toBe(true);
  expect(proofBlocks("advisory", fail)).toBe(false);
  expect(proofBlocks("enforce", judgeProof(null, []))).toBe(false);
});
