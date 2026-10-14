import { describe, expect, test } from "bun:test";
import { assertAgentOptions } from "./privilege-guard";

describe("assertAgentOptions (F9 runtime guard)", () => {
  test("accepts dontAsk with an allowlisted env", () => {
    expect(() =>
      assertAgentOptions({ permissionMode: "dontAsk", env: { PATH: "/bin", HOME: "/h" } }),
    ).not.toThrow();
  });

  test("refuses a permission bypass", () => {
    expect(() => assertAgentOptions({ permissionMode: "bypassPermissions" })).toThrow(/F9/);
    expect(() => assertAgentOptions({ allowDangerouslySkipPermissions: true })).toThrow(/F9/);
  });

  test("refuses any GitHub token in the agent env", () => {
    for (const key of [
      "GH_TOKEN",
      "GITHUB_TOKEN",
      "GH_ENTERPRISE_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
    ]) {
      expect(() => assertAgentOptions({ env: { PATH: "/bin", [key]: "t" } })).toThrow(key);
    }
  });
});
