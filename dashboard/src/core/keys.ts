// Global keyboard shortcuts. Pure mapping from key events to actions so it can be tested
// without a DOM. Destructive actions are never bound to a single key: they open a dialog.

export interface KeyActions {
  /** Cmd+K or Ctrl+K. Works even while typing. */
  togglePalette(): void;
  /** `g` then a destination key. Returns false when the key is not a destination. */
  go(key: string): boolean;
  /** `?` */
  showShortcuts(): void;
  /** `j` (+1) and `k` (-1). */
  moveRow(delta: 1 | -1): void;
  /** `Enter` while a row has focus. Returns false when focus is not on a row. */
  openRow(): boolean;
  /** `Esc` outside a dialog (dialogs close themselves). */
  escape(): void;
  /** True while a modal dialog is open: single-key shortcuts are suspended. */
  isBlocked(): boolean;
}

export interface KeyLike {
  key: string;
  metaKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  target?: EventTarget | null;
  preventDefault(): void;
}

/** How long `g` waits for its second key. */
export const SEQUENCE_MS = 1000;

export const SHORTCUTS: ReadonlyArray<{ keys: string[]; label: string }> = [
  { keys: ["⌘", "K"], label: "Open the command palette (Ctrl+K elsewhere)" },
  { keys: ["g", "t"], label: "Go to Triage" },
  { keys: ["g", "r"], label: "Go to Runs" },
  { keys: ["g", "a"], label: "Go to Agents" },
  { keys: ["g", "s"], label: "Go to Safety" },
  { keys: ["g", "c"], label: "Go to Cost and DORA" },
  { keys: ["g", "d"], label: "Go to Settings" },
  { keys: ["j"], label: "Next row" },
  { keys: ["k"], label: "Previous row" },
  { keys: ["Enter"], label: "Open the focused row" },
  { keys: ["Esc"], label: "Close the dialog or panel" },
  { keys: ["?"], label: "Show this sheet" },
];

export function isTypingTarget(target: EventTarget | null | undefined): boolean {
  const el = target as HTMLElement | null | undefined;
  if (!el || typeof el.tagName !== "string") return false;
  const tag = el.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable === true;
}

/** Returns a keydown handler. `now` is injectable for tests. */
export function createKeyHandler(
  actions: KeyActions,
  now: () => number = Date.now,
): (e: KeyLike) => void {
  let gAt = 0;
  return (e) => {
    if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
      e.preventDefault();
      actions.togglePalette();
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey || actions.isBlocked() || isTypingTarget(e.target)) {
      gAt = 0;
      return;
    }
    if (gAt && now() - gAt < SEQUENCE_MS) {
      gAt = 0;
      if (actions.go(e.key)) e.preventDefault();
      return;
    }
    gAt = 0;
    switch (e.key) {
      case "g":
        gAt = now();
        return;
      case "?":
        e.preventDefault();
        actions.showShortcuts();
        return;
      case "j":
      case "k":
        e.preventDefault();
        actions.moveRow(e.key === "j" ? 1 : -1);
        return;
      case "Enter":
        if (actions.openRow()) e.preventDefault();
        return;
      case "Escape":
        actions.escape();
        return;
    }
  };
}
