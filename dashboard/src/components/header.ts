// Global chrome: destination tabs, connection state, breaker pill, emergency brake, command
// palette, shortcuts, theme and the account menu. Also the daemon control bar on Triage.

import { store } from "../core/state";
import * as api from "../core/api";
import { createKeyHandler, SHORTCUTS } from "../core/keys";
import { DESTINATIONS, switchTab } from "../core/router";
import { buildCommands, setupCommandPalette, type Palette } from "./command-palette";
import { h, hydrateInitialHidden } from "./ui/dom";
import { kbd, modKey } from "./ui/kbd";
import { setPill, GLYPHS } from "./ui/pill";
import { setDisabled, isDisabled } from "./ui/button";
import { openDialog, anyDialogOpen, confirmDialog } from "./ui/dialog";
import { setupTablist } from "./ui/tabs";
import { toast } from "./ui/toast";
import { clock, offlineText } from "./ui/states";
import { setupNotificationsModal, confirmAbort } from "./modal";
import type { FleetState, DaemonConfig } from "../types/api";

let soundEnabled = false;
let previousPipelineIds: Set<number> = new Set();
let palette: Palette | null = null;

const BRAKE_OFFLINE = "Not connected: the brake needs a live connection to the server.";

export function setupHeader(): void {
  hydrateInitialHidden();
  setupTheme();
  setupUserMenu();
  fetchUser();
  setupDaemonControlBar();
  setupEmergencyBrake();
  setupNotificationsModal();
  setupConnectionStatus();
  setupPaletteAndKeys();
  const tabs = document.getElementById("dest-tabs");
  if (tabs) setupTablist(tabs);
  fetchDaemonConfig();
  setInterval(fetchDaemonConfig, 30000);
}

// ── Theme: system (no attribute), dark, light ──────────────────────────

const THEMES = ["system", "dark", "light"] as const;
type Theme = (typeof THEMES)[number];

function readTheme(): Theme {
  try {
    const saved = localStorage.getItem("sw-theme");
    return (THEMES as readonly string[]).includes(saved ?? "") ? (saved as Theme) : "system";
  } catch {
    return "system";
  }
}

function applyTheme(theme: Theme): void {
  const root = document.documentElement;
  if (theme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
  const btn = document.getElementById("theme-toggle");
  const name = document.getElementById("theme-name");
  if (name) name.textContent = theme;
  if (btn) btn.setAttribute("aria-label", `Theme: ${theme}. Activate to change`);
}

function cycleTheme(): void {
  const next = THEMES[(THEMES.indexOf(readTheme()) + 1) % THEMES.length];
  try {
    localStorage.setItem("sw-theme", next);
  } catch {
    // Private mode: the choice lasts for this page only.
  }
  applyTheme(next);
}

function setupTheme(): void {
  applyTheme(readTheme());
  document.getElementById("theme-toggle")?.addEventListener("click", cycleTheme);
}

// ── Account menu (initials only: the CSP blocks remote avatars) ────────

export function initialsFor(name: string): string {
  const parts = name.trim().split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function applyRoleRestrictions(role: string): void {
  if (role !== "viewer") return;
  const selectors = [
    "#emergency-brake",
    "#daemon-btn-start",
    "#daemon-btn-stop",
    "#daemon-btn-pause",
    "#daemon-btn-patrol",
    "#btn-add-machine",
    "#btn-join-link",
    "#btn-create-invite",
    ".pipeline-checkbox",
    ".bulk-actions",
  ];
  for (const sel of selectors) {
    document.querySelectorAll<HTMLElement>(sel).forEach((el) => (el.style.display = "none"));
  }
}

function fetchUser(): void {
  api
    .fetchMe()
    .then((user) => {
      store.set("currentUser", user);
      const name = user.username || "User";
      const role = user.role ? ` (${user.role})` : "";
      const nameEl = document.getElementById("dropdown-username");
      if (nameEl) nameEl.textContent = name + role;
      const initials = document.getElementById("avatar-initials");
      if (initials) initials.textContent = initialsFor(name);
      document.getElementById("user-avatar")?.setAttribute("aria-label", `Account: ${name}`);
      if (user.role) applyRoleRestrictions(user.role);
    })
    .catch(() => {});
}

function setupUserMenu(): void {
  const btn = document.getElementById("user-avatar");
  const menu = document.getElementById("user-dropdown");
  if (!btn || !menu) return;
  const setOpen = (open: boolean) => {
    menu.hidden = !open;
    btn.setAttribute("aria-expanded", String(open));
  };
  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    setOpen(menu.hidden);
    if (!menu.hidden) menu.querySelector<HTMLElement>("button, a")?.focus();
  });
  menu.addEventListener("click", (e) => e.stopPropagation());
  menu.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    e.stopPropagation();
    setOpen(false);
    btn.focus();
  });
  document.addEventListener("click", () => setOpen(false));
  const sound = document.getElementById("sound-toggle");
  sound?.addEventListener("click", () => {
    soundEnabled = !soundEnabled;
    sound.setAttribute("aria-pressed", String(soundEnabled));
  });
}

// ── Connection state: live, reconnecting, stale with timestamp ─────────

export type ConnState = "connecting" | "live" | "reconnecting" | "stale";

/** Data older than this, or a disconnect longer than this, counts as stale. */
export const STALE_MS = 30000;

export interface ConnInputs {
  connected: boolean;
  disconnectedAt: number | null;
  lastDataAt: number | null;
  now: number;
}

export function connectionState(c: ConnInputs): ConnState {
  if (c.connected) {
    return c.lastDataAt !== null && c.now - c.lastDataAt > STALE_MS ? "stale" : "live";
  }
  if (c.disconnectedAt === null) return c.lastDataAt === null ? "connecting" : "reconnecting";
  return c.now - c.disconnectedAt > STALE_MS ? "stale" : "reconnecting";
}

export function connectionText(state: ConnState, c: ConnInputs): string {
  const age = c.lastDataAt === null ? null : Math.max(0, Math.round((c.now - c.lastDataAt) / 1000));
  switch (state) {
    case "connecting":
      return "Connecting";
    case "live":
      return age === null ? "Live" : `Live, updated ${age}s ago`;
    case "reconnecting":
      return "Reconnecting";
    case "stale":
      return c.lastDataAt === null ? "Stale, no data yet" : `Stale since ${clock(new Date(c.lastDataAt))}`;
  }
}

/** Compact label for narrow headers; still text, so state is never colour alone. */
export function connectionShort(state: ConnState, c: ConnInputs): string {
  if (state === "stale") return c.lastDataAt === null ? "Stale" : `Stale ${clock(new Date(c.lastDataAt))}`;
  return state === "reconnecting" ? "Retrying" : state === "live" ? "Live" : "Connecting";
}

const conn: ConnInputs = { connected: false, disconnectedAt: null, lastDataAt: null, now: 0 };
let announced: ConnState | null = null;

function setupConnectionStatus(): void {
  store.subscribe("connected", (connected) => {
    conn.connected = connected;
    conn.disconnectedAt = connected ? null : Date.now();
    renderConnection();
  });
  store.subscribe("fleetState", () => {
    conn.lastDataAt = Date.now();
  });
  renderConnection();
  setInterval(renderConnection, 1000);
}

function renderConnection(): void {
  conn.now = Date.now();
  const state = connectionState(conn);
  const el = document.getElementById("conn");
  const text = document.getElementById("conn-text");
  if (el) el.dataset.state = state;
  if (text) text.textContent = connectionText(state, conn);
  const short = document.getElementById("conn-short");
  if (short) short.textContent = connectionShort(state, conn);
  // Announce transitions only; the ticking age would be noise for a screen reader.
  if (state !== announced) {
    announced = state;
    const live = document.getElementById("conn-live");
    if (live) live.textContent = "Connection: " + connectionText(state, { ...conn, lastDataAt: null });
  }
  // ws.ts owns the offline banner and its Reconnect button; add the timestamps here.
  const bannerText = document.querySelector("#offline-banner > span:nth-child(2)");
  if (bannerText && conn.disconnectedAt !== null) {
    bannerText.textContent = offlineText(
      new Date(conn.disconnectedAt),
      conn.lastDataAt === null ? null : new Date(conn.lastDataAt),
    );
  }
  const brake = document.getElementById("emergency-brake");
  if (brake) setDisabled(brake, conn.connected ? undefined : BRAKE_OFFLINE);
}

// The breaker pill is static markup in index.html: the dashboard server does not expose
// circuit-breaker state yet, so the pill says "not reported" instead of guessing.

// ── Emergency brake (always a confirmation, Cancel focused) ────────────

export function updateEmergencyBrakeVisibility(data: FleetState): void {
  const active = document.getElementById("emergency-active-count");
  if (active) active.textContent = String(data.pipelines?.length ?? 0);
}

function setupEmergencyBrake(): void {
  document.getElementById("emergency-brake")?.addEventListener("click", (e) => {
    if (isDisabled(e.currentTarget as HTMLElement)) return;
    openBrakeDialog();
  });
  document.getElementById("emergency-confirm")?.addEventListener("click", () => {
    if (!conn.connected) return toast(BRAKE_OFFLINE, "error");
    api
      .emergencyBrake()
      .then((res) => {
        const paused = (res as { paused?: number }).paused;
        toast(paused == null ? "Emergency brake sent." : `Emergency brake: paused ${paused} pipeline${paused === 1 ? "" : "s"}.`);
      })
      .catch((err) => toast("Emergency brake failed: " + String(err), "error"));
  });
}

function openBrakeDialog(): void {
  if (!conn.connected) {
    toast(BRAKE_OFFLINE, "error");
    return;
  }
  const fleet = store.get("fleetState");
  const active = document.getElementById("emergency-active-count");
  if (active) active.textContent = String(fleet?.pipelines?.length ?? 0);
  openDialog("emergency-modal");
}

// ── Command palette and keyboard shortcuts ─────────────────────────────

function openRun(issue: number): void {
  switchTab("runs");
  // The Runs view renders its rows on mount; open the row once it exists.
  requestAnimationFrame(() => {
    const row = document.querySelector<HTMLElement>(`.pipeline-row[data-issue="${issue}"]`);
    if (row) {
      row.click();
      focusRow(row);
    } else toast(`Run #${issue} is not in the run list.`);
  });
}

function intervene(issue: number, action: "pause" | "resume"): void {
  api
    .sendIntervention(issue, action)
    .then(() => toast(`${action === "pause" ? "Pause" : "Resume"} sent to run #${issue}.`))
    .catch((err) => toast(`${action} failed for run #${issue}: ${String(err)}`, "error"));
}

function commands() {
  return buildCommands({
    destinations: DESTINATIONS,
    fleet: store.get("fleetState"),
    canAct: store.get("currentUser")?.role !== "viewer",
    go: switchTab,
    openRun,
    pauseRun: (n) => intervene(n, "pause"),
    resumeRun: (n) => intervene(n, "resume"),
    stopRun: (n, stage) => void confirmAbort(n, stage),
    emergencyBrake: openBrakeDialog,
    toggleTheme: cycleTheme,
    showShortcuts,
  });
}

function showShortcuts(): void {
  const list = document.getElementById("shortcut-list");
  if (list && !list.childElementCount) {
    for (const s of SHORTCUTS) {
      const keys = s.keys.map((k) => (k === "⌘" ? modKey() : k));
      list.append(h("div", { class: "shortcut" }, h("dt", null, kbd(...keys)), h("dd", { text: s.label })));
    }
  }
  openDialog("shortcuts-modal");
}

const ROW_SELECTOR = "[data-row], .pipeline-row, .pipeline-card, .queue-row";

function visibleRows(): HTMLElement[] {
  const panel = document.querySelector<HTMLElement>("[data-route]:not([hidden])");
  if (!panel) return [];
  return Array.from(panel.querySelectorAll<HTMLElement>(ROW_SELECTOR)).filter(
    (r) => r.offsetParent !== null || r.getClientRects().length > 0,
  );
}

function focusRow(row: HTMLElement): void {
  if (!row.hasAttribute("tabindex")) row.tabIndex = -1;
  row.focus();
  if (typeof row.scrollIntoView === "function") row.scrollIntoView({ block: "nearest" });
}

function moveRow(delta: 1 | -1): void {
  const rows = visibleRows();
  if (!rows.length) return;
  const at = rows.indexOf(document.activeElement as HTMLElement);
  const next = at === -1 ? (delta === 1 ? 0 : rows.length - 1) : Math.min(rows.length - 1, Math.max(0, at + delta));
  focusRow(rows[next]);
}

function openRow(): boolean {
  const el = document.activeElement as HTMLElement | null;
  if (!el || !el.matches(ROW_SELECTOR)) return false;
  el.click();
  return true;
}

function escape(): void {
  const menu = document.getElementById("user-dropdown");
  if (menu && !menu.hidden) {
    menu.hidden = true;
    document.getElementById("user-avatar")?.setAttribute("aria-expanded", "false");
    return;
  }
  const detail = document.querySelector<HTMLElement>(".pipeline-detail-panel.open");
  if (detail) detail.querySelector<HTMLElement>(".detail-panel-close")?.click();
}

function setupPaletteAndKeys(): void {
  palette = setupCommandPalette(commands);
  const mod = modKey();
  const hint = document.getElementById("palette-kbd");
  if (hint) hint.textContent = mod === "Ctrl" ? "Ctrl K" : "⌘K";
  document.getElementById("open-palette")?.addEventListener("click", () => palette?.open());
  const onKey = createKeyHandler({
    togglePalette: () => palette?.toggle(),
    go: (key) => {
      const dest = DESTINATIONS.find((d) => d.key === key);
      if (dest) switchTab(dest.id);
      return Boolean(dest);
    },
    showShortcuts,
    moveRow,
    openRow,
    escape,
    isBlocked: anyDialogOpen,
  });
  document.addEventListener("keydown", onKey);
}

// ── Counts on tabs, cost line, alerts ──────────────────────────────────

export function renderCostTicker(data: FleetState): void {
  const runs = document.getElementById("count-runs");
  if (runs) {
    const n = data.pipelines?.length ?? 0;
    runs.textContent = String(n);
    runs.hidden = n === 0;
    runs.setAttribute("aria-label", `${n} active`);
  }
  const cost = data.cost;
  if (!cost) return;
  const el24 = document.getElementById("cost-24h");
  const elBudget = document.getElementById("cost-budget");
  if (el24 && cost.today_spent != null) el24.textContent = "$" + cost.today_spent.toFixed(2);
  if (elBudget) {
    const cap = cost.daily_budget ?? 0;
    elBudget.textContent =
      cap > 0
        ? `\u00b7 $${Math.max(0, cap - (cost.today_spent ?? 0)).toFixed(2)} of $${cap.toFixed(2)} cap left`
        : "\u00b7 no daily cap set";
  }
}

export function renderAlertBanner(_data: FleetState): void {
  const container = document.getElementById("alert-banner");
  if (!container) return;
  const hide = () => {
    container.replaceChildren();
    container.hidden = true;
  };
  if (store.get("alertDismissed")) return hide();
  api
    .fetchAlerts()
    .then(({ alerts }) => {
      if (!alerts || alerts.length === 0) return hide();
      const alert = alerts[0];
      store.set("alertsCache", alerts);
      const tone = alert.severity === "critical" || alert.severity === "error" ? "danger" : "warn";
      const actions = h("span", { class: "alert-actions" });
      const add = (label: string, fn: () => void, cls = "btn sm") =>
        actions.append(h("button", { type: "button", class: cls, text: label, onclick: fn }));
      const canAct = store.get("currentUser")?.role !== "viewer";
      if (alert.issue) add("View", () => switchTab("runs"));
      if (canAct && alert.type === "failure_spike") add("Emergency brake…", openBrakeDialog, "btn sm danger");
      if (canAct && alert.type === "stuck_pipeline" && alert.issue) {
        const n = alert.issue;
        add("Stop run…", () => void confirmAbort(n), "btn sm danger");
        add("Skip stage", () =>
          api
            .sendIntervention(n, "skip")
            .then(() => toast(`Skip sent to run #${n}.`))
            .catch((err) => toast(`Skip failed for run #${n}: ${String(err)}`, "error")),
        );
      }
      add("Dismiss", () => {
        store.set("alertDismissed", true);
        hide();
        setTimeout(() => store.set("alertDismissed", false), 30000);
      }, "btn sm ghost");
      container.dataset.tone = tone;
      container.replaceChildren(
        h("span", { class: "glyph", "aria-hidden": "true", text: tone === "danger" ? GLYPHS.fail : GLYPHS.warn }),
        h("span", { class: "alert-message", text: alert.message || "" }),
        actions,
      );
      container.hidden = false;
    })
    .catch(hide);
}

/** Retired: the ambient indicator animated with no state change (spec section 4.2). */
export function updateAmbientIndicator(_data: FleetState): void {}

export function detectCompletions(data: FleetState): void {
  const currentIds = new Set(data.pipelines?.map((p) => p.issue) || []);
  if (soundEnabled) {
    for (const prevId of previousPipelineIds) {
      if (currentIds.has(prevId)) continue;
      const ended = data.events?.find((e) => e.issue === prevId && /completed|failed/.test(String(e.type || "")));
      if (ended) playTone(String(ended.type).includes("failed"));
    }
  }
  previousPipelineIds = currentIds;
}

function playTone(failed: boolean): void {
  try {
    const ctx = new AudioContext();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);
    const t = ctx.currentTime;
    if (failed) {
      osc.type = "sawtooth";
      osc.frequency.setValueAtTime(200, t);
      osc.frequency.setValueAtTime(150, t + 0.2);
    } else {
      osc.frequency.setValueAtTime(523.25, t);
      osc.frequency.setValueAtTime(659.25, t + 0.1);
      osc.frequency.setValueAtTime(783.99, t + 0.2);
    }
    gain.gain.setValueAtTime(0.08, t);
    gain.gain.exponentialRampToValueAtTime(0.01, t + 0.45);
    osc.start(t);
    osc.stop(t + 0.45);
  } catch {
    // Audio is optional.
  }
}

// ── Daemon control bar (Triage) ────────────────────────────────────────

function fetchDaemonConfig(): void {
  api
    .fetchDaemonConfig()
    .then((data) => {
      store.set("daemonConfig", data);
      updateDaemonControlBar(data);
    })
    .catch(() => {});
}

function setupDaemonControlBar(): void {
  for (const action of ["start", "patrol"]) {
    document.getElementById("daemon-btn-" + action)?.addEventListener("click", () => daemonControlAction(action));
  }
  document.getElementById("daemon-btn-stop")?.addEventListener("click", async () => {
    const ok = await confirmDialog({
      title: "Stop the daemon?",
      body: "The daemon stops polling for labelled issues and starting runs. Start it again from here.",
      confirmLabel: "Stop daemon",
      cancelLabel: "Keep running",
      danger: true,
    });
    if (ok) void daemonControlAction("stop");
  });
  document.getElementById("daemon-btn-pause")?.addEventListener("click", () => {
    const badge = document.getElementById("daemon-status-badge");
    daemonControlAction(badge?.dataset.state === "paused" ? "resume" : "pause");
  });
}

async function daemonControlAction(action: string): Promise<void> {
  const id = action === "resume" ? "pause" : action;
  const btn = document.getElementById("daemon-btn-" + id) as HTMLButtonElement | null;
  if (btn) btn.disabled = true;
  try {
    await api.daemonControl(action);
    setTimeout(fetchDaemonConfig, 1000);
  } catch (err) {
    toast(`Daemon ${action} failed: ${String(err)}`, "error");
  } finally {
    if (btn) btn.disabled = false;
  }
}

function updateDaemonControlBar(data: DaemonConfig): void {
  const badge = document.getElementById("daemon-status-badge");
  if (!badge) return;
  const pauseBtn = document.getElementById("daemon-btn-pause");
  const [state, tone, glyph, label] = data.paused
    ? (["paused", "warn", GLYPHS.half, "Paused"] as const)
    : data.config?.watch_label
      ? (["running", "ok", GLYPHS.live, "Running"] as const)
      : (["stopped", "neutral", GLYPHS.idle, "Stopped"] as const);
  badge.dataset.state = state;
  setPill(badge, tone, glyph, label);
  if (pauseBtn) pauseBtn.textContent = data.paused ? "Resume" : "Pause";

  const cfg = (data.config ?? {}) as Record<string, unknown>;
  const set = (id: string, v: unknown) => {
    const el = document.getElementById(id);
    if (el) el.textContent = v == null || v === "" ? "-" : String(v);
  };
  if (data.config) {
    set("daemon-info-workers", cfg.max_workers);
    set("daemon-info-poll", cfg.poll_interval);
    set("daemon-info-patrol", (cfg.patrol as Record<string, unknown> | undefined)?.interval);
  }
  if (data.budget) {
    const budget = data.budget as Record<string, unknown>;
    const remaining = budget.remaining ?? budget.daily_limit;
    set("daemon-info-budget", typeof remaining === "number" ? remaining.toFixed(2) : remaining);
  }
}

