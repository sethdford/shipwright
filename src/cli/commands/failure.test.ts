import { describe, expect, test } from "bun:test";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { failureCommand } from "./failure";

const files = new FakeFileReader({
  "/logs/pre.log":
    "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret\n",
  "/logs/rate.log": "API Error: 429 rate limit\n",
});

describe("failure classify", () => {
  test("auth text escalates with exit 3 and class auth", async () => {
    const io = captureIO();
    const code = await failureCommand.run(
      ["classify", "--log", "/logs/pre.log", "--json"],
      commandContext(io, undefined, {}, files),
    );
    expect(code).toBe(3);
    expect(JSON.parse(io.outLines[0] ?? "{}")).toMatchObject({ class: "auth", action: "escalate" });
  });

  test("an unreadable log fails closed with exit 1", async () => {
    const io = captureIO();
    expect(
      await failureCommand.run(
        ["classify", "--log", "/nope.log"],
        commandContext(io, undefined, {}, files),
      ),
    ).toBe(1);
  });

  test("a missing --log is a usage error with exit 2", async () => {
    const io = captureIO();
    expect(await failureCommand.run(["classify"], commandContext(io, undefined, {}, files))).toBe(
      2,
    );
  });

  test("a first transient failure retries with exit 0", async () => {
    const io = captureIO();
    expect(
      await failureCommand.run(
        ["classify", "--log", "/logs/rate.log"],
        commandContext(io, undefined, {}, files),
      ),
    ).toBe(0);
  });
});
