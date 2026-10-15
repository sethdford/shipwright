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
      expect(() =>
        assertAgentOptions({ permissionMode: "dontAsk", env: { PATH: "/bin", [key]: "t" } }),
      ).toThrow(key);
    }
  });
});

describe("assertAgentOptions allowlist (F9 bypass paths)", () => {
  const dontAsk = { permissionMode: "dontAsk" } as const;

  test("refuses SDK options that can carry CLI flags (extraArgs, executableArgs)", () => {
    expect(() =>
      assertAgentOptions({ ...dontAsk, extraArgs: { "dangerously-skip-permissions": null } }),
    ).toThrow(/F9/);
    expect(() =>
      assertAgentOptions({ ...dontAsk, extraArgs: { "permission-mode": "bypassPermissions" } }),
    ).toThrow(/F9/);
    expect(() =>
      assertAgentOptions({ ...dontAsk, executableArgs: ["--dangerously-skip-permissions"] }),
    ).toThrow(/F9/);
  });

  test("refuses settings, which can set permissions.defaultMode", () => {
    expect(() =>
      assertAgentOptions({
        ...dontAsk,
        settings: { permissions: { defaultMode: "bypassPermissions" } },
      }),
    ).toThrow(/F9/);
    expect(() =>
      assertAgentOptions({ ...dontAsk, settings: { permissions: { defaultMode: "dontAsk" } } }),
    ).toThrow(/F9/);
  });

  test("refuses any option key outside the allowlist, including spellings of the bypass", () => {
    expect(() => assertAgentOptions({ ...dontAsk, dangerouslySkipPermissions: true })).toThrow(
      /F9/,
    );
    expect(() => assertAgentOptions({ ...dontAsk, allowDangerouslySkipPermissions: true })).toThrow(
      /F9/,
    );
    expect(() => assertAgentOptions({ ...dontAsk, executable: "/tmp/evil" })).toThrow(/F9/);
  });

  test("permissionMode must be exactly dontAsk, however it is spelled", () => {
    for (const mode of ["bypassPermissions", "acceptEdits", "default", "auto", "plan", ""]) {
      expect(() => assertAgentOptions({ permissionMode: mode })).toThrow(/F9/);
    }
    // A concatenated or computed spelling reaches the guard as its runtime value.
    expect(() =>
      assertAgentOptions({ permissionMode: ["bypass", "Permissions"].join("") }),
    ).toThrow(/F9/);
    expect(() => assertAgentOptions({})).toThrow(/F9/);
  });

  test("accepts the option set the runner really passes", () => {
    expect(() =>
      assertAgentOptions({
        model: "m",
        effort: "low",
        systemPrompt: "s",
        permissionMode: "dontAsk",
        tools: [],
        allowedTools: [],
        strictMcpConfig: true,
        settingSources: ["project"],
        persistSession: false,
        maxTurns: 3,
        maxBudgetUsd: 1,
        outputFormat: { type: "json_schema", schema: {} },
        cwd: "/repo",
        env: { PATH: "/bin" },
        abortController: new AbortController(),
      }),
    ).not.toThrow();
  });
});

describe("assertAgentOptions hardening", () => {
  const base = { permissionMode: "dontAsk" } as const;

  test("refuses an accessor (getter) on an option or an env key", () => {
    const getter = {
      get permissionMode() {
        return "dontAsk";
      },
    };
    expect(() => assertAgentOptions(getter)).toThrow(/F9/);
    const env = {
      get GH_TOKEN() {
        return "t";
      },
    };
    expect(() =>
      assertAgentOptions({
        ...base,
        env: Object.defineProperty({}, "X", { get: () => 1, enumerable: true }),
      }),
    ).toThrow(/F9/);
    expect(() => assertAgentOptions({ ...base, env })).toThrow(/F9/);
  });

  test("refuses a non-plain prototype and an inherited permissionMode", () => {
    class Opts {}
    expect(() => assertAgentOptions(Object.assign(new Opts(), base))).toThrow(/F9/);
    expect(() => assertAgentOptions(Object.create({ permissionMode: "dontAsk" }))).toThrow(/F9/);
  });

  test("refuses a symbol key", () => {
    expect(() => assertAgentOptions({ ...base, [Symbol("x")]: 1 })).toThrow(/F9/);
  });

  test("checks env token names case-insensitively", () => {
    for (const key of ["gh_token", "Github_Token", "gh_enterprise_token"]) {
      expect(() => assertAgentOptions({ ...base, env: { [key]: "t" } })).toThrow(/F9/);
    }
  });

  test("accepts a frozen copy and a null-prototype object", () => {
    expect(() =>
      assertAgentOptions(Object.freeze({ ...base, env: Object.freeze({ PATH: "/bin" }) })),
    ).not.toThrow();
    expect(() => assertAgentOptions(Object.assign(Object.create(null), base))).not.toThrow();
  });
});
