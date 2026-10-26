import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  buildCommands,
  filterCommands,
  scoreMatch,
  setupCommandPalette,
  type Command,
  type CommandContext,
} from "./command-palette";
import { DESTINATIONS } from "../core/router";
import type { FleetState } from "../types/api";

function mount(html: string): void {
  const doc = new DOMParser().parseFromString(html, "text/html");
  document.body.replaceChildren(...Array.from(doc.body.childNodes));
}

const fleet = {
  pipelines: [
    { issue: 4187, title: "Add retry to webhook client", stage: "test", status: "running" },
    { issue: 4171, title: "Merge settings page", stage: "merge", status: "paused" },
  ],
} as unknown as FleetState;

function ctx(over: Partial<CommandContext> = {}): CommandContext {
  return {
    destinations: DESTINATIONS,
    fleet,
    canAct: true,
    go: vi.fn(),
    openRun: vi.fn(),
    isPaused: (n: number) => n === 4171,
    pauseRun: vi.fn(),
    resumeRun: vi.fn(),
    stopRun: vi.fn(),
    emergencyBrake: vi.fn(),
    toggleTheme: vi.fn(),
    showShortcuts: vi.fn(),
    ...over,
  };
}

describe("scoreMatch", () => {
  it("prefers substring over subsequence and earlier, word-start matches", () => {
    expect(scoreMatch("runs", "Go to Runs")).toBeGreaterThan(scoreMatch("gtr", "Go to Runs"));
    expect(scoreMatch("4187", "Open run #4187 x")).toBeGreaterThan(0);
    expect(scoreMatch("cost", "Go to Cost and DORA")).toBeGreaterThan(scoreMatch("ost", "Go to Cost and DORA"));
    expect(scoreMatch("zzz", "Go to Runs")).toBe(-1);
    expect(scoreMatch("", "anything")).toBe(0);
  });

  it("matches fuzzy subsequences ignoring case and spaces", () => {
    expect(scoreMatch("GT SAF", "Go to Safety")).toBeGreaterThan(0);
  });
});

describe("buildCommands", () => {
  it("lists the six destinations with their g shortcuts", () => {
    const cmds = buildCommands(ctx());
    const go = cmds.filter((c) => c.kind === "destination");
    expect(go.map((c) => c.label)).toEqual([
      "Go to Triage",
      "Go to Runs",
      "Go to Agents",
      "Go to Safety",
      "Go to Cost and DORA",
      "Go to Settings",
    ]);
    expect(go[4].keys).toEqual(["g", "c"]);
  });

  it("lists runs by number and title", () => {
    const c = ctx();
    const open = buildCommands(c).find((x) => x.id === "open-4187");
    expect(open?.label).toBe("Open run #4187 Add retry to webhook client");
    open?.run();
    expect(c.openRun).toHaveBeenCalledWith(4187);
  });

  it("offers one Pause/Resume toggle per run, by the pause state this page knows, plus stop", () => {
    const c = ctx();
    const cmds = buildCommands(c);
    const ids = cmds.map((x) => x.id);
    expect(ids).toEqual(expect.arrayContaining(["pause-4187", "stop-4187", "resume-4171", "stop-4171", "brake"]));
    expect(ids).not.toContain("resume-4187");
    expect(ids).not.toContain("pause-4171");
    cmds.find((x) => x.id === "resume-4171")?.run();
    cmds.find((x) => x.id === "pause-4187")?.run();
    expect(c.resumeRun).toHaveBeenCalledWith(4171);
    expect(c.pauseRun).toHaveBeenCalledWith(4187);
  });

  it("marks destructive actions and routes stop through the confirmation callback", () => {
    const c = ctx();
    const stop = buildCommands(c).find((x) => x.id === "stop-4187");
    expect(stop?.danger).toBe(true);
    stop?.run();
    expect(c.stopRun).toHaveBeenCalledWith(4187, "test");
  });

  it("leaves actions out for viewers", () => {
    const ids = buildCommands(ctx({ canAct: false })).map((c) => c.id);
    expect(ids.some((id) => /^(pause|resume|stop)-|^brake$/.test(id))).toBe(false);
    expect(ids).toContain("open-4187");
  });

  it("works with no fleet state yet", () => {
    expect(buildCommands(ctx({ fleet: null })).filter((c) => c.kind === "run")).toEqual([]);
  });
});

describe("filterCommands", () => {
  const cmds = buildCommands(ctx());

  it("hides per-run actions until something is typed", () => {
    const empty = filterCommands(cmds, "").map((c) => c.id);
    expect(empty).toContain("go-triage");
    expect(empty).toContain("open-4187");
    expect(empty).not.toContain("stop-4187");
  });

  it("finds a run by number and ranks the open command first", () => {
    const res = filterCommands(cmds, "4187").map((c) => c.id);
    expect(res[0]).toBe("open-4187");
    expect(res).toContain("stop-4187");
    expect(res).not.toContain("open-4171");
  });

  it("finds a run by title words", () => {
    expect(filterCommands(cmds, "webhook")[0].id).toBe("open-4187");
  });

  it("matches keywords that are not shown", () => {
    expect(filterCommands(cmds, "audit").map((c) => c.id)).toContain("audit");
  });
});

describe("setupCommandPalette", () => {
  const PALETTE = `
    <button id="opener">Search</button>
    <dialog id="palette">
      <input id="palette-input" role="combobox" aria-expanded="true" aria-controls="palette-list" />
      <ul id="palette-list" role="listbox"></ul>
    </dialog>`;
  let ran: string[];
  let commands: Command[];

  beforeEach(() => {
    mount(PALETTE);
    ran = [];
    const mk = (id: string, label: string, extra: Partial<Command> = {}): Command => ({
      id,
      label,
      kind: "destination",
      run: () => ran.push(id),
      ...extra,
    });
    commands = [mk("a", "Go to Triage", { keys: ["g", "t"] }), mk("b", "Go to Runs", { keys: ["g", "r"] }), mk("c", "Open run #12 fix")];
  });

  const input = () => document.getElementById("palette-input") as HTMLInputElement;
  const options = () => Array.from(document.querySelectorAll('[role="option"]'));
  const press = (k: string) => input().dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));

  it("opens as a modal with focus in the combobox and the first option active", () => {
    const p = setupCommandPalette(() => commands);
    p.open();
    expect(p.isOpen()).toBe(true);
    expect(document.activeElement).toBe(input());
    expect(options()).toHaveLength(3);
    expect(input().getAttribute("aria-activedescendant")).toBe(options()[0].id);
    expect(options()[0].getAttribute("aria-selected")).toBe("true");
  });

  it("shows each command's shortcut", () => {
    setupCommandPalette(() => commands).open();
    const kbds = Array.from(options()[1].querySelectorAll("kbd")).map((k) => k.textContent);
    expect(kbds).toEqual(["g", "r"]);
  });

  it("moves the active option with the arrow keys, wrapping", () => {
    setupCommandPalette(() => commands).open();
    press("ArrowDown");
    expect(input().getAttribute("aria-activedescendant")).toBe(options()[1].id);
    press("ArrowUp");
    press("ArrowUp");
    expect(input().getAttribute("aria-activedescendant")).toBe(options()[2].id);
  });

  it("filters as you type and runs the active command on Enter, closing first", () => {
    const p = setupCommandPalette(() => commands);
    p.open();
    input().value = "run #12";
    input().dispatchEvent(new Event("input"));
    expect(options()).toHaveLength(1);
    press("Enter");
    expect(p.isOpen()).toBe(false);
    expect(ran).toEqual(["c"]);
  });

  it("says so when nothing matches", () => {
    setupCommandPalette(() => commands).open();
    input().value = "qqqq";
    input().dispatchEvent(new Event("input"));
    expect(options()).toHaveLength(0);
    expect(input().getAttribute("aria-expanded")).toBe("false");
    expect(input().hasAttribute("aria-activedescendant")).toBe(false);
    expect(document.querySelector(".pal-empty")?.textContent).toMatch(/No matches/);
  });

  it("runs a command on click", () => {
    setupCommandPalette(() => commands).open();
    (options()[1] as HTMLElement).click();
    expect(ran).toEqual(["b"]);
  });

  it("toggles closed and returns focus to the opener", () => {
    const opener = document.getElementById("opener") as HTMLButtonElement;
    opener.focus();
    const p = setupCommandPalette(() => commands);
    p.toggle();
    expect(p.isOpen()).toBe(true);
    p.toggle();
    expect(p.isOpen()).toBe(false);
    expect(document.activeElement).toBe(opener);
  });

  it("is a no-op without its markup", () => {
    document.body.replaceChildren();
    const p = setupCommandPalette(() => commands);
    expect(() => p.open()).not.toThrow();
    expect(p.isOpen()).toBe(false);
  });
});
