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

test("treats an empty override as unset", () => {
  expect(resolvePaths({ HOME: "/h", SHIPWRIGHT_STATE_DIR: "" }).stateDir).toBe("/h/.shipwright");
});

test("rejects a relative HOME", () => {
  expect(() => resolvePaths({ HOME: "h" })).toThrow(/absolute/);
});

test("rejects a relative state dir", () => {
  expect(() => resolvePaths({ HOME: "/h", SHIPWRIGHT_STATE_DIR: "rel" })).toThrow(/absolute/);
});
