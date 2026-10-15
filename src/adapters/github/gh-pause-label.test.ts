import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhPauseLabel } from "./gh-pause-label";

test("lists open issues carrying shipwright:pause", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["gh", "issue", "list"],
      result: { exitCode: 0, stdout: '[{"number":12},{"number":34}]', stderr: "" },
    },
  ]);
  expect(await new GhPauseLabel(runner).labelled()).toEqual({ ok: true, value: [12, 34] });
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--label",
    "shipwright:pause",
    "--limit",
    "20",
    "--json",
    "number",
  ]);
});

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 503: unavailable" } },
  ]);
  const r = await new GhPauseLabel(runner).labelled();
  expect(!r.ok && r.error.kind).toBe("transient");
});
