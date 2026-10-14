import { expect, test } from "bun:test";
import { resolvePaths } from "./paths";

test("defaults state dir and socket from HOME", () => {
  expect(resolvePaths({ HOME: "/h" })).toEqual({
    home: "/h",
    stateDir: "/h/.shipwright",
    tmuxSocketName: "shipwright",
  });
});

test("honours explicit overrides", () => {
  const paths = resolvePaths({
    HOME: "/h",
    SHIPWRIGHT_STATE_DIR: "/s",
    SHIPWRIGHT_TMUX_SOCKET: "sock",
  });
  expect(paths).toEqual({ home: "/h", stateDir: "/s", tmuxSocketName: "sock" });
});

test("fails loudly without HOME rather than guessing", () => {
  expect(() => resolvePaths({})).toThrow(/HOME is not set/);
});
