// Command palette (Cmd+K / Ctrl+K): a combobox over a listbox, with aria-activedescendant
// so focus stays in the input. Lists destinations, runs by number or title, and actions.

import { h } from "./ui/dom";
import { kbd } from "./ui/kbd";
import { openDialog } from "./ui/dialog";
import type { FleetState } from "../types/api";

export type CommandKind = "destination" | "run" | "action";

export interface Command {
  id: string;
  label: string;
  kind: CommandKind;
  /** Shortcut keys shown on the right, e.g. ["g", "r"]. */
  keys?: string[];
  /** Extra words that match but are not shown. */
  keywords?: string;
  /** Per-run actions are only listed once the operator types something. */
  needsQuery?: boolean;
  danger?: boolean;
  run(): void;
}

const KIND_LABEL: Record<CommandKind, string> = { destination: "Go to", run: "Run", action: "Action" };
const MAX_RESULTS = 50;

/**
 * Fuzzy score of `query` against `text`, higher is better, -1 when it does not match.
 * Substring matches beat subsequence matches; earlier and word-start matches score higher.
 */
export function scoreMatch(query: string, text: string): number {
  const q = query.trim().toLowerCase();
  const t = text.toLowerCase();
  if (!q) return 0;
  const at = t.indexOf(q);
  if (at !== -1) {
    const wordStart = at === 0 || /[\s#:/-]/.test(t[at - 1]);
    return 1000 - at + (wordStart ? 200 : 0);
  }
  let score = 0;
  let pos = -1;
  for (const ch of q) {
    if (ch === " ") continue;
    const next = t.indexOf(ch, pos + 1);
    if (next === -1) return -1;
    score += next === pos + 1 ? 5 : 1;
    pos = next;
  }
  return score;
}

export function filterCommands(commands: readonly Command[], query: string): Command[] {
  const q = query.trim();
  if (!q) return commands.filter((c) => !c.needsQuery).slice(0, MAX_RESULTS);
  return commands
    .map((c, i) => ({ c, i, s: scoreMatch(q, c.label + " " + (c.keywords ?? "")) }))
    .filter((x) => x.s >= 0)
    .sort((a, b) => b.s - a.s || a.i - b.i)
    .slice(0, MAX_RESULTS)
    .map((x) => x.c);
}

export interface CommandContext {
  destinations: ReadonlyArray<{ id: string; label: string; key: string }>;
  fleet: FleetState | null;
  canAct: boolean;
  go(dest: string): void;
  openRun(issue: number): void;
  /** Whether this page paused the run; the server does not report paused state. */
  isPaused(issue: number): boolean;
  pauseRun(issue: number): void;
  resumeRun(issue: number): void;
  stopRun(issue: number, stage: string): void;
  emergencyBrake(): void;
  toggleTheme(): void;
  showShortcuts(): void;
}

/** Builds the command list from the current state. Actions are left out for viewers. */
export function buildCommands(ctx: CommandContext): Command[] {
  const out: Command[] = ctx.destinations.map((d) => ({
    id: "go-" + d.id,
    label: "Go to " + d.label,
    kind: "destination" as const,
    keys: ["g", d.key],
    run: () => ctx.go(d.id),
  }));
  const runs = ctx.fleet?.pipelines ?? [];
  for (const p of runs) {
    const name = `#${p.issue} ${p.title || "Untitled"}`;
    out.push({
      id: "open-" + p.issue,
      label: `Open run ${name}`,
      kind: "run",
      keywords: p.stage,
      run: () => ctx.openRun(p.issue),
    });
  }
  out.push({ id: "audit", label: "Open the audit log", kind: "action", keywords: "safety activity", run: () => ctx.go("safety") });
  out.push({ id: "theme", label: "Change theme", kind: "action", keywords: "dark light system", run: ctx.toggleTheme });
  out.push({ id: "keys", label: "Show keyboard shortcuts", kind: "action", keys: ["?"], keywords: "help", run: ctx.showShortcuts });
  if (!ctx.canAct) return out;
  out.push({ id: "brake", label: "Engage the emergency brake…", kind: "action", danger: true, keywords: "pause all stop", run: ctx.emergencyBrake });
  for (const p of runs) {
    const n = p.issue;
    out.push(
      ctx.isPaused(n)
        ? { id: "resume-" + n, label: `Resume run #${n}`, kind: "action", needsQuery: true, run: () => ctx.resumeRun(n) }
        : { id: "pause-" + n, label: `Pause run #${n}`, kind: "action", needsQuery: true, run: () => ctx.pauseRun(n) },
      { id: "stop-" + n, label: `Stop run #${n}…`, kind: "action", needsQuery: true, danger: true, run: () => ctx.stopRun(n, p.stage) },
    );
  }
  return out;
}

export interface Palette {
  open(): void;
  close(): void;
  toggle(): void;
  isOpen(): boolean;
}

/** Wires the static palette markup in index.html. */
export function setupCommandPalette(getCommands: () => Command[]): Palette {
  const dlg = document.getElementById("palette") as HTMLDialogElement | null;
  const input = document.getElementById("palette-input") as HTMLInputElement | null;
  const list = document.getElementById("palette-list");
  if (!dlg || !input || !list) {
    const noop = () => {};
    return { open: noop, close: noop, toggle: noop, isOpen: () => false };
  }
  let items: Command[] = [];
  let index = 0;
  let commands: Command[] = [];

  const setIndex = (i: number) => {
    index = i;
    const opts = list.querySelectorAll<HTMLElement>('[role="option"]');
    opts.forEach((o, j) => o.setAttribute("aria-selected", String(j === i)));
    const active = opts[i];
    if (active) {
      input.setAttribute("aria-activedescendant", active.id);
      if (typeof active.scrollIntoView === "function") active.scrollIntoView({ block: "nearest" });
    } else input.removeAttribute("aria-activedescendant");
  };

  const runAt = (i: number) => {
    const cmd = items[i];
    if (!cmd) return;
    // Run after the close event, once focus has gone back to the opener, so a command that
    // opens another dialog or moves focus is not undone by the focus return.
    dlg.addEventListener("close", () => cmd.run(), { once: true });
    dlg.close();
  };

  const render = () => {
    items = filterCommands(commands, input.value);
    list.replaceChildren(
      ...items.map((c, i) =>
        h("li", {
          id: "palette-opt-" + i,
          role: "option",
          class: "pal-item" + (c.danger ? " is-danger" : ""),
          "aria-selected": "false",
          onclick: () => runAt(i),
          onmousemove: () => index !== i && setIndex(i),
        },
          h("span", { class: "pal-label", text: c.label }),
          c.keys ? kbd(...c.keys) : h("span", { class: "pal-kind", text: KIND_LABEL[c.kind] }),
        ),
      ),
    );
    if (!items.length) list.append(h("li", { class: "pal-empty", role: "presentation", text: "No matches. Try a run number or a destination." }));
    input.setAttribute("aria-expanded", String(items.length > 0));
    setIndex(items.length ? 0 : -1);
  };

  input.addEventListener("input", render);
  input.addEventListener("keydown", (e) => {
    const n = items.length;
    if (e.key === "ArrowDown" && n) setIndex((index + 1) % n);
    else if (e.key === "ArrowUp" && n) setIndex((index - 1 + n) % n);
    else if (e.key === "Home" && n && e.ctrlKey) setIndex(0);
    else if (e.key === "End" && n && e.ctrlKey) setIndex(n - 1);
    else if (e.key === "Enter") runAt(index);
    else return;
    e.preventDefault();
  });

  const open = () => {
    if (dlg.open) return;
    commands = getCommands();
    input.value = "";
    render();
    openDialog(dlg);
    input.focus();
  };
  const close = () => dlg.open && dlg.close();
  return { open, close, toggle: () => (dlg.open ? close() : open()), isOpen: () => dlg.open };
}
