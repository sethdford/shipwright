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
import { setDisabled } from "./ui/button";
import { openDialog, anyDialogOpen, confirmDialog } from "./ui/dialog";
import { setupTablist } from "./ui/tabs";
import { toast } from "./ui/toast";
import { clock } from "./ui/states";
import { actionBlockReason, canAct, guardAction, markRoleUnavailable } from "./ui/guard";
import { setupNotificationsModal, confirmAbort, pausedRuns, sendRunAction } from "./modal";
import type { FleetState, DaemonConfig } from "../types/api";

let soundEnabled = false;
let previousPipelineIds: Set<number> = new Set();
let palette: Palette | null = null;

/** Controls that change the fleet; each is disabled, with its reason, while actions are blocked. */
const ACTION_CONTROLS = ["emergency-brake", "daemon-btn-start", "daemon-btn-stop", "daemon-btn-pause", "daemon-btn-patrol"];

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
  setupSkipLink();
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
      syncActionControls();
    })
    .catch(() => {
      // Fail closed: without a role, no action is offered.
      markRoleUnavailable();
      syncActionControls();
    });
}

function syncActionControls(): void {
  const reason = actionBlockReason();
  for (const id of ACTION_CONTROLS) {
    const el = document.getElementById(id);
    if (el) setDisabled(el, id === "emergency-brake" ? brakeBlockReason() : reason);
  }
}

/**
 * The brake is exempt from the connection check (it must work when the feed is stale or
 * down, and it reports the server's real result); the role check still applies.
 */
function brakeBlockReason(): string | undefined {
  return actionBlockReason({ allowOffline: true });
}

function guardBrake(): boolean {
  const reason = brakeBlockReason();
  if (reason) toast(reason, "error");
  return reason === undefined;
}

/** The skip link moves focus without adding a history entry or a hash the router would see. */
function setupSkipLink(): void {
  document.querySelector(".skip-link")?.addEventListener("click", (e) => {
    e.preventDefault();
    document.getElementById("main")?.focus();
  });
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

// ── Connection state: one vocabulary for header and banner ─────────────
// Live: connected with fresh data. Stale: connected, but no data for STALE_MS.
// Reconnecting: disconnected for under STALE_MS. Offline: disconnected for longer.

export type ConnState = "connecting" | "live" | "stale" | "reconnecting" | "offline";

export const STALE_MS = 30000;

export interface ConnInputs {
  connected: boolean;
  disconnectedAt: number | null;
  lastDataAt: number | null;
  now: number;
}

export function connectionState(c: ConnInputs): ConnState {
  if (c.connected) {
    if (c.lastDataAt === null) return "connecting";
    return c.now - c.lastDataAt > STALE_MS ? "stale" : "live";
  }
  if (c.disconnectedAt === null) return c.lastDataAt === null ? "connecting" : "reconnecting";
  return c.now - c.disconnectedAt > STALE_MS ? "offline" : "reconnecting";
}

const at = (t: number | null) => (t === null ? "" : clock(new Date(t)));

export function connectionText(state: ConnState, c: ConnInputs): string {
  const age = c.lastDataAt === null ? 0 : Math.max(0, Math.round((c.now - c.lastDataAt) / 1000));
  switch (state) {
    case "live":
      return age < 5 ? "Live \u00b7 just now" : `Live \u00b7 updated ${age}s ago`;
    case "stale":
      return `Stale \u00b7 data from ${at(c.lastDataAt)}`;
    case "offline":
      return `Offline since ${at(c.disconnectedAt)}`;
    case "reconnecting":
      return "Reconnecting";
    default:
      return "Connecting";
  }
}

/** Compact label for narrow headers: the same words, so state is never colour alone. */
export function connectionShort(state: ConnState): string {
  return state[0].toUpperCase() + state.slice(1);
}

/** Offline banner text, in the header's vocabulary, saying what still works. */
export function bannerText(state: ConnState, c: ConnInputs): string {
  const head = state === "offline" ? `Offline since ${at(c.disconnectedAt)}.` : "Reconnecting.";
  const data = c.lastDataAt === null ? "No data received yet." : `Showing data from ${at(c.lastDataAt)}.`;
  return `${head} ${data} Actions are off until reconnected; the emergency brake still works and reports what it paused.`;
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
    syncActionControls();
  });
  store.subscribe("currentUser", syncActionControls);
  renderConnection();
  setInterval(renderConnection, 1000);
}

function renderConnection(): void {
  conn.now = Date.now();
  // A page that never connects gets no "connected" change (it starts false), but ws.ts shows
  // its offline banner on the first failed attempt: count the outage from then.
  const wsBanner = document.getElementById("offline-banner");
  if (!conn.connected && conn.disconnectedAt === null && wsBanner && wsBanner.style.display !== "none") {
    conn.disconnectedAt = conn.now;
  }
  const state = connectionState(conn);
  const el = document.getElementById("conn");
  const text = document.getElementById("conn-text");
  const short = document.getElementById("conn-short");
  if (el) el.dataset.state = state;
  if (text) text.textContent = connectionText(state, conn);
  if (short) short.textContent = connectionShort(state);
  // Announce transitions only; the ticking age would be noise for a screen reader.
  if (state !== announced) {
    announced = state;
    const live = document.getElementById("conn-live");
    if (live) live.textContent = "Connection: " + connectionShort(state);
  }
  // ws.ts owns the offline banner and its Reconnect button; the text comes from here.
  const banner = document.querySelector("#offline-banner > span:nth-child(2)");
  if (banner && !conn.connected) banner.textContent = bannerText(state, conn);
  syncActionControls();
}

// The breaker pill is static markup in index.html: the dashboard server does not expose
// circuit-breaker state yet, so the pill says "not reported" instead of guessing.

// ── Emergency brake (always a confirmation, Cancel focused) ────────────

export function updateEmergencyBrakeVisibility(_data: FleetState): void {
  const dlg = document.getElementById("emergency-modal") as HTMLDialogElement | null;
  if (dlg?.open) renderBrakeBody();
}

/** Running count from the live feed, or null when the feed is not live (count unknown). */
function liveRunCount(): number | null {
  conn.now = Date.now();
  if (connectionState(conn) !== "live") return null;
  return store.get("fleetState")?.pipelines?.length ?? 0;
}

export function brakeBody(running: number | null): string {
  const runs =
    running === null
      ? "pauses every process of every running pipeline. The live feed is not current, so how many are running is unknown here; the result says what was paused."
      : `pauses every process of each running pipeline (${running} now).`;
  return `This pauses daemon intake, so no new runs start, and ${runs} Queued work stays in the queue. Resume intake on Triage, and resume runs from Runs.`;
}

function renderBrakeBody(): void {
  const desc = document.getElementById("brake-desc");
  if (desc) desc.textContent = brakeBody(liveRunCount());
}

function setupEmergencyBrake(): void {
  // A disabled brake still answers a click or Enter with its reason.
  document.getElementById("emergency-brake")?.addEventListener("click", openBrakeDialog);
  document.getElementById("emergency-confirm")?.addEventListener("click", () => void engageBrake());
}

function openBrakeDialog(): void {
  if (!guardBrake()) return;
  renderBrakeBody();
  openDialog("emergency-modal");
}

type BrakeJob = api.BrakeResult["jobs"][number];

function jobProblem(j: BrakeJob): string | null {
  if (j.refused) return `#${j.issue} ${j.refused}`;
  if (j.failed.length) return `#${j.issue} ${j.failed.length} process${j.failed.length === 1 ? "" : "es"} not paused`;
  if (!j.signalled.length) return `#${j.issue} nothing to pause`;
  return null;
}

/**
 * Pauses daemon intake and every process of every running pipeline. Both requests are
 * always sent. "Engaged" only when intake paused and the server reports every running
 * job's tree paused; anything else is an incomplete alert that names the runs.
 */
export async function engageBrake(): Promise<void> {
  if (!guardBrake()) return;
  const [intake, runs] = await Promise.allSettled([api.pauseIntakeForBrake(), api.emergencyBrake()]);
  setTimeout(fetchDaemonConfig, 500);
  const problems: string[] = [];
  if (intake.status === "rejected") problems.push(`pausing intake failed (${String(intake.reason)})`);
  if (runs.status === "rejected") {
    problems.push(`pausing pipelines failed (${String(runs.reason)})`);
  } else {
    const res = runs.value;
    const jobs = res.jobs ?? [];
    for (const j of jobs) {
      const problem = jobProblem(j);
      if (problem) problems.push(problem);
      else pausedRuns.add(j.issue);
    }
    if (jobs.length !== res.running) problems.push("the server's job list did not match its count");
  }
  if (problems.length === 0 && runs.status === "fulfilled") {
    const n = runs.value.running;
    const procs = runs.value.jobs.reduce((sum, j) => sum + j.signalled.length, 0);
    toast(
      n === 0
        ? "Emergency brake engaged: intake paused; no pipelines were running."
        : `Emergency brake engaged: intake paused; all ${n} running pipeline${n === 1 ? "" : "s"} paused (${procs} processes).`,
    );
    return;
  }
  toast(`Emergency brake incomplete: ${problems.join("; ")}. Check the daemon now.`, "error");
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

function commands() {
  return buildCommands({
    destinations: DESTINATIONS,
    fleet: store.get("fleetState"),
    canAct: canAct(),
    go: switchTab,
    openRun,
    isPaused: (n) => pausedRuns.has(n),
    pauseRun: (n) => void sendRunAction(n, "pause"),
    resumeRun: (n) => void sendRunAction(n, "resume"),
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
      const acts = canAct();
      const issue = alert.issue;
      // On phones the actions collapse into one Review button (CSS swaps which show).
      add("Review", () => (issue ? openRun(issue) : switchTab("safety")), "btn sm alert-review");
      if (issue) add("View", () => openRun(issue));
      if (acts && alert.type === "failure_spike") add("Emergency brake…", openBrakeDialog, "btn sm danger");
      if (acts && alert.type === "stuck_pipeline" && issue) add("Stop run…", () => void confirmAbort(issue), "btn sm danger");
      add("Dismiss", () => {
        store.set("alertDismissed", true);
        hide();
        setTimeout(() => store.set("alertDismissed", false), 30000);
      }, "btn sm ghost alert-dismiss");
      container.dataset.tone = tone;
      container.replaceChildren(
        h("span", { class: "glyph", "aria-hidden": "true", text: tone === "danger" ? GLYPHS.fail : GLYPHS.warn }),
        h("span", { class: "alert-message", text: alert.message || "", title: alert.message || "" }),
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
    if (!guardAction()) return;
    const ok = await confirmDialog({
      title: "Stop the daemon?",
      body: daemonStopBody(store.get("fleetState")?.pipelines?.length ?? 0),
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

/** What stopping the daemon does: its exit handler terminates every active pipeline (sw-daemon.sh). */
export function daemonStopBody(running: number): string {
  const runs =
    running === 0
      ? "No pipelines are running now; any that start before it exits are terminated too."
      : `All ${running} running pipeline${running === 1 ? " is" : "s are"} terminated; they cannot be resumed from the dashboard.`;
  return `The daemon stops polling and exits. ${runs} Queued work stays queued. Start it again from here.`;
}

async function daemonControlAction(action: string): Promise<void> {
  if (!guardAction()) return;
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
  // The server reports the intake pause flag, not whether the daemon process is running.
  badge.dataset.state = data.paused ? "paused" : "unknown";
  if (data.paused) setPill(badge, "warn", GLYPHS.half, "Intake paused");
  else setPill(badge, "neutral", GLYPHS.unknown, "Daemon: not reported");
  if (pauseBtn) pauseBtn.textContent = data.paused ? "Resume intake" : "Pause intake";

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

