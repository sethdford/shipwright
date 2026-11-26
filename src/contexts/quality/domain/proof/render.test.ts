import { expect, test } from "bun:test";
import type { ProofPlan } from "./plan";
import { cell, fenced, PROOF_MARKER, type ProofReportView, renderProofSection } from "./render";
import { judgeProof, type WebResult } from "./result";

const plan: ProofPlan = {
  web: {
    start: ["npm", "run", "dev"],
    port: 3000,
    url: null,
    readyPath: "/",
    readyTimeoutMs: 1,
    allowHosts: [],
    flows: [],
    source: "detected",
  },
  cli: [],
  notes: [],
};
const web: WebResult = {
  status: "ran",
  url: "http://127.0.0.1:3000",
  serverLog: "web/server.log",
  flows: [
    {
      name: "page /",
      steps: [{ step: "goto /", ok: true }],
      screenshots: [{ name: "home", file: "web/1-home.png" }],
      video: "web/1-flow.webm",
      consoleErrors: [],
      pageErrors: [],
      httpErrors: [],
      blocked: ["https://fonts.example/x"],
    },
  ],
};
const view = (over: Partial<ProofReportView> = {}): ProofReportView => ({
  plan,
  web,
  cli: [],
  verdict: judgeProof(web, []),
  baseUrl: "https://github.com/o/r/raw/abc/run/1/",
  outDir: "/tmp/out",
  texts: {},
  ...over,
});

test("published artifacts are embedded as images and linked", () => {
  const md = renderProofSection(view());
  expect(md.startsWith(PROOF_MARKER)).toBe(true);
  expect(md).toContain("The app ran and the changed flows worked.");
  expect(md).toContain("![home](https://github.com/o/r/raw/abc/run/1/web/1-home.png)");
  expect(md).toContain(
    "[video of this flow](https://github.com/o/r/raw/abc/run/1/web/1-flow.webm)",
  );
  expect(md).toContain("[server log](https://github.com/o/r/raw/abc/run/1/web/server.log)");
  expect(md).toContain("blocked 1 request(s)");
});

test("unpublished artifacts are named by path", () => {
  const md = renderProofSection(view({ baseUrl: null }));
  expect(md).toContain("`web/1-home.png`");
  expect(md).toContain("kept on the machine that ran the pipeline, in `/tmp/out`");
});

test("a failed start shows the end of the server log; CLI output is fenced", () => {
  const failed: WebResult = {
    status: "start_failed",
    reason: "exit 1",
    serverLog: "web/server.log",
  };
  const md = renderProofSection(
    view({
      web: failed,
      verdict: judgeProof(failed, []),
      cli: [
        {
          name: "h",
          argv: ["t", "--help"],
          exitCode: 0,
          expectExit: 0,
          timedOut: false,
          transcript: "cli/1.txt",
        },
      ],
      texts: { "web/server.log": "Error: DATABASE_URL missing", "cli/1.txt": "```\n</details>" },
    }),
  );
  expect(md).toContain("Running the app found a problem.");
  expect(md).toContain("DATABASE_URL missing");
  expect(md).toContain("````text\n```\n</details>\n````");
});

test("model or app text cannot break the markdown", () => {
  expect(cell("a|b`c\nd")).toBe("a'b'c d");
  expect(fenced("x")).toBe("```text\nx\n```");
});
