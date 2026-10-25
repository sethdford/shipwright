import { describe, it, expect, vi, beforeEach } from "vitest";
import { createKeyHandler, isTypingTarget, SEQUENCE_MS, SHORTCUTS, type KeyActions, type KeyLike } from "./keys";

function actions(overrides: Partial<KeyActions> = {}): KeyActions & Record<string, ReturnType<typeof vi.fn>> {
  return {
    togglePalette: vi.fn(),
    go: vi.fn((k: string) => ["t", "r", "a", "s", "c", "d"].includes(k)),
    showShortcuts: vi.fn(),
    moveRow: vi.fn(),
    openRow: vi.fn(() => true),
    escape: vi.fn(),
    isBlocked: vi.fn(() => false),
    ...overrides,
  } as never;
}

function key(k: string, extra: Partial<KeyLike> = {}): KeyLike & { preventDefault: ReturnType<typeof vi.fn> } {
  return { key: k, preventDefault: vi.fn(), target: document.body, ...extra } as never;
}

describe("createKeyHandler", () => {
  let a: ReturnType<typeof actions>;
  let t: number;
  let handle: (e: KeyLike) => void;

  beforeEach(() => {
    a = actions();
    t = 1000;
    handle = createKeyHandler(a, () => t);
  });

  it("toggles the palette on Cmd+K and Ctrl+K, even while typing", () => {
    const input = document.createElement("input");
    const e1 = key("k", { metaKey: true });
    handle(e1);
    handle(key("K", { ctrlKey: true, target: input }));
    expect(a.togglePalette).toHaveBeenCalledTimes(2);
    expect(e1.preventDefault).toHaveBeenCalled();
  });

  it("does not treat Ctrl+Alt+K as the palette", () => {
    handle(key("k", { ctrlKey: true, altKey: true }));
    expect(a.togglePalette).not.toHaveBeenCalled();
  });

  it.each(["t", "r", "a", "s", "c", "d"])("g then %s goes to a destination", (k) => {
    handle(key("g"));
    const e = key(k);
    handle(e);
    expect(a.go).toHaveBeenCalledWith(k);
    expect(e.preventDefault).toHaveBeenCalled();
    expect(a.moveRow).not.toHaveBeenCalled();
  });

  it("drops the g prefix after the sequence window", () => {
    handle(key("g"));
    t += SEQUENCE_MS + 1;
    handle(key("k"));
    expect(a.go).not.toHaveBeenCalled();
    expect(a.moveRow).toHaveBeenCalledWith(-1);
  });

  it("consumes the second key even when it is not a destination", () => {
    handle(key("g"));
    const e = key("x");
    handle(e);
    expect(a.go).toHaveBeenCalledWith("x");
    expect(e.preventDefault).not.toHaveBeenCalled();
    handle(key("j"));
    expect(a.moveRow).toHaveBeenCalledWith(1);
  });

  it("moves rows with j and k", () => {
    handle(key("j"));
    handle(key("k"));
    expect(a.moveRow.mock.calls).toEqual([[1], [-1]]);
  });

  it("opens the focused row on Enter and leaves Enter alone otherwise", () => {
    const e = key("Enter");
    handle(e);
    expect(a.openRow).toHaveBeenCalled();
    expect(e.preventDefault).toHaveBeenCalled();
    const b = actions({ openRow: vi.fn(() => false) });
    const e2 = key("Enter");
    createKeyHandler(b)(e2);
    expect(e2.preventDefault).not.toHaveBeenCalled();
  });

  it("shows the shortcut sheet on ? and handles Escape", () => {
    handle(key("?"));
    handle(key("Escape"));
    expect(a.showShortcuts).toHaveBeenCalled();
    expect(a.escape).toHaveBeenCalled();
  });

  it("ignores single keys while typing in a field", () => {
    for (const tag of ["input", "textarea", "select"]) {
      const el = document.createElement(tag);
      handle(key("g", { target: el }));
      handle(key("t", { target: el }));
      handle(key("j", { target: el }));
      handle(key("?", { target: el }));
    }
    expect(a.go).not.toHaveBeenCalled();
    expect(a.moveRow).not.toHaveBeenCalled();
    expect(a.showShortcuts).not.toHaveBeenCalled();
  });

  it("ignores single keys while a dialog is open", () => {
    const b = actions({ isBlocked: vi.fn(() => true) });
    const h = createKeyHandler(b);
    h(key("j"));
    h(key("?"));
    expect(b.moveRow).not.toHaveBeenCalled();
    expect(b.showShortcuts).not.toHaveBeenCalled();
  });

  it("ignores keys with modifiers other than the palette chord", () => {
    handle(key("j", { metaKey: true }));
    handle(key("g", { altKey: true }));
    handle(key("t"));
    expect(a.moveRow).not.toHaveBeenCalled();
    expect(a.go).not.toHaveBeenCalled();
  });
});

describe("isTypingTarget", () => {
  it("detects fields and contenteditable", () => {
    const div = document.createElement("div");
    div.contentEditable = "true";
    expect(isTypingTarget(document.createElement("input"))).toBe(true);
    expect(isTypingTarget(document.createElement("button"))).toBe(false);
    expect(isTypingTarget(null)).toBe(false);
    expect(isTypingTarget(div)).toBe(div.isContentEditable === true);
  });
});

describe("SHORTCUTS", () => {
  it("documents every destination and no single-key destructive action", () => {
    const labels = SHORTCUTS.map((s) => s.label).join(" ");
    for (const d of ["Triage", "Runs", "Agents", "Safety", "Cost and DORA", "Settings"]) {
      expect(labels).toContain("Go to " + d);
    }
    expect(labels).not.toMatch(/stop|abort|brake|delete/i);
  });
});
