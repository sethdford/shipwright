import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhOpenIssues } from "./gh-open-issues";

const listing = (stdout: string) =>
  new FakeProcessRunner([
    { prefix: ["gh", "issue", "list"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);

test("lists open issues with titles and labels", async () => {
  const stdout = JSON.stringify([
    { number: 8525, title: "Detect thrashing", labels: [{ name: "auto-patrol" }] },
  ]);
  const runner = listing(stdout);
  expect(await new GhOpenIssues(runner).open()).toEqual({
    ok: true,
    value: [{ number: 8525, title: "Detect thrashing", labels: ["auto-patrol"] }],
  });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--limit",
    "2000",
    "--json",
    "number,title,labels",
  ]);
  expect(runner.calls[0]?.timeoutMs).toBe(30_000);
});

test("a listing that fills the limit may be truncated: error, not a short list", async () => {
  const rows = [1, 2, 3].map((n) => ({ number: n, title: `t${n}`, labels: [] }));
  const r = await new GhOpenIssues(listing(JSON.stringify(rows)), 3).open();
  expect(!r.ok && r.error.kind).toBe("failed");
  expect(!r.ok && r.error.message).toContain("truncated");
  expect((await new GhOpenIssues(listing(JSON.stringify(rows)), 4).open()).ok).toBe(true);
});

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 429: Too Many Requests" } },
  ]);
  const r = await new GhOpenIssues(runner).open();
  expect(!r.ok && r.error.kind).toBe("transient");
});
