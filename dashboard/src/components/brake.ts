// Emergency brake: engage (a confirmation, Cancel focused; the incomplete alert's Retry repeats
// an engage already confirmed), the engaged state that
// stays in the shell until released, and an alert that stays until dismissed whenever the
// brake or its release is incomplete. Release resumes, behind a confirmation, only what this
// brake paused: intake and runs that were already paused stay paused.

import { store } from "../core/state";
import * as api from "../core/api";
import { h } from "./ui/dom";
import { openDialog, confirmDialog } from "./ui/dialog";
import { toast } from "./ui/toast";
import { clock } from "./ui/states";
import { actionBlockReason, guardAction } from "./ui/guard";
import { onRunAction, pausedRuns } from "./modal";
import { switchTab } from "../core/router";

interface Hooks {
  /** Whether the live feed is current, so the dialog can state the running count. */
  isLive: () => boolean;
  /** Re-read daemon state after the brake changed intake. */
  refresh: () => void;
  /** The engaged state changed (the alert banner labels its brake action from it). */
  changed: () => void;
}

/** What this brake paused: Release resumes exactly this. */
interface Engaged {
  /** Intake is paused by this brake (Release resumes it). */
  intake: boolean;
  /** Intake was already paused before the brake; Release leaves it paused. */
  intakeAlready?: boolean;
  /** A release already resumed intake (only runs are left). */
  intakeResumed?: boolean;
  /** Runs this brake paused, fully or partly (not runs that were already paused). */
  issues: number[];
  /** The last engage was incomplete: the brake button retries it. */
  partial?: boolean;
  /**
   * A request got no answer, so the server may have acted: on a retry, a run or intake it reports
   * as already paused may have been paused by this brake, so it is counted as the brake's own.
   */
  uncertain?: boolean;
  intakeUncertain?: boolean;
  /** A release got no answer (or is in flight): what it resumed is unknown until a retry answers. */
  releaseUncertain?: boolean;
  at: number;
}

/** Whether the brake holds anything to release (otherwise it only remembers an unanswered try). */
const holds = (e: Engaged | null): e is Engaged => Boolean(e && (e.intake || e.issues.length));

const KEY = "sw-brake";
let hooks: Hooks = { isLive: () => false, refresh: () => {}, changed: () => {} };
let engaged: Engaged | null = null;
/** A brake or release request is in flight in this tab. */
let busy = false;
const BUSY = "The brake is already being applied or released; wait for its result.";
const CHANGED = "The brake changed while this was open, so nothing was sent. Check it and try again.";
/** The record an action was confirmed against: if another tab changed it since, nothing is sent. */
const snap = () => JSON.stringify(engaged);
let dialogSeen: string | undefined;

/** The record changed since it was shown: nothing is sent, and a stale alert (and its Retry) goes. */
function refuseChanged(): void {
  showAlert(null);
  toast(CHANGED, "error");
}
/**
 * One brake or release at a time across every tab. The Web Locks lock ("sw-brake") is the guard:
 * it is atomic across tabs and is released when its tab closes. The shared marker shows other
 * tabs that a request is in flight; it is owned by the tab that set it and expires after the
 * server's request timeout. Without Web Locks the marker is the guard (a read then a write,
 * so two tabs confirming in the same instant can both send).
 */
const BUSY_KEY = "sw-brake-busy";
const LOCK = "sw-brake";
const TAB = Math.random().toString(36).slice(2);
const BUSY_MS = 90_000;
const locks = (): LockManager | undefined => (typeof navigator === "undefined" ? undefined : navigator.locks);

/** When another tab's in-flight marker expires (0 if there is none). */
function otherTabUntil(): number {
  try {
    const m = JSON.parse(localStorage.getItem(BUSY_KEY) ?? "null") as { tab: string; until: number } | null;
    return m && m.tab !== TAB && m.until > Date.now() ? m.until : 0;
  } catch {
    return 0;
  }
}

const isBusy = () => busy || otherTabUntil() > 0;

/** Runs a brake or release only if no tab holds the lock; otherwise says to wait. */
async function exclusive(run: () => Promise<void>): Promise<void> {
  const lm = locks();
  if (!lm) return run();
  await lm.request(LOCK, { ifAvailable: true }, async (lock) => {
    if (!lock) return void toast(BUSY, "error");
    await run();
  });
}

let expiry: ReturnType<typeof setTimeout> | undefined;
let watching = false;

/**
 * While another tab's request is in flight, waits for it to end so this tab stops showing
 * "waiting" and shows the stored state: when the lock is free (that tab got its answer or
 * closed; a marker left then is stale), or else when the marker expires.
 */
function watchOtherTab(): void {
  clearTimeout(expiry);
  const until = otherTabUntil();
  if (!until) return;
  expiry = setTimeout(follow, until - Date.now() + 50);
  const lm = locks();
  if (!lm || watching) return;
  watching = true;
  void lm.request(LOCK, { mode: "shared" }, () => setBusy(false)).finally(() => {
    watching = false;
    follow();
  });
}

function setBusy(on: boolean): void {
  busy = on;
  try {
    if (on) localStorage.setItem(BUSY_KEY, JSON.stringify({ tab: TAB, until: Date.now() + BUSY_MS }));
    else localStorage.removeItem(BUSY_KEY);
  } catch {
    // Private mode: only this tab is guarded.
  }
  render();
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : word.endsWith("s") ? "es" : "s"}`;
const runs = (n: number) => (n === 0 ? "no runs" : `${n} run${n === 1 ? "" : "s"}`);

/** The stored record, or undefined when storage cannot be read (this page's record then stands). */
function load(): Engaged | null | undefined {
  let raw: string | null;
  try {
    raw = localStorage.getItem(KEY);
  } catch {
    return undefined;
  }
  try {
    const v = JSON.parse(raw ?? "null") as Engaged | null;
    return v && Array.isArray(v.issues) ? v : null;
  } catch {
    return null;
  }
}

function save(next: Engaged | null): void {
  const keep = next !== null && (next.intake || next.issues.length > 0 || next.uncertain || next.intakeUncertain);
  engaged = keep ? next : null;
  try {
    if (engaged) localStorage.setItem(KEY, JSON.stringify(engaged));
    else localStorage.removeItem(KEY);
  } catch {
    // Private mode: the engaged state lasts for this page only.
  }
  render();
  hooks.changed();
}

/**
 * Re-reads the stored record: another tab may have engaged, retried or released since. Every
 * action starts from it, so a tab never overwrites a newer record with its stale view.
 */
function sync(): void {
  const v = load();
  if (v !== undefined) engaged = v;
  for (const n of engaged?.issues ?? []) pausedRuns.add(n);
}

/** Shows what another tab did. */
function follow(): void {
  const gone = engaged?.issues ?? [];
  sync();
  for (const n of gone) if (!engaged?.issues.includes(n)) pausedRuns.delete(n);
  render();
  hooks.changed();
}

export function setupBrake(with_: Hooks): void {
  hooks = with_;
  sync();
  // Another tab changed the brake: show what it did.
  window.addEventListener("storage", (ev) => {
    if (ev.key === KEY || ev.key === BUSY_KEY || ev.key === null) follow();
  });
  document.getElementById("emergency-brake")?.addEventListener("click", brakeClick);
  document.getElementById("emergency-confirm")?.addEventListener("click", () => void engageBrake(dialogSeen));
  // A run resumed or stopped by hand is no longer this brake's to release.
  onRunAction((issue, action) => {
    sync();
    if (engaged && action !== "pause" && engaged.issues.includes(issue)) {
      save({ ...engaged, issues: engaged.issues.filter((n) => n !== issue) });
    }
  });
  render();
}

/** Intake was resumed by hand (Triage): no longer paused, and no longer this brake's to release. */
export function forgetIntake(): void {
  sync();
  if (engaged?.intake || engaged?.intakeAlready) save({ ...engaged, intake: false, intakeAlready: false, intakeResumed: true });
}

/** Whether the brake holds something to release (the alert banner labels its brake action so). */
export function brakeEngaged(): boolean {
  return holds(engaged) && !engaged.partial;
}

/** The brake is exempt from the connection check; the role check still applies (core/guard.ts). */
export function brakeBlockReason(): string | undefined {
  return actionBlockReason({ allowOffline: true });
}

function guardBrake(): boolean {
  const reason = brakeBlockReason();
  if (reason) toast(reason, "error");
  return reason === undefined;
}

/** Engaged (or a release unanswered): the release path. Otherwise the engage dialog. A blocked click says why. */
export function brakeClick(): void {
  if (isBusy()) return void toast(BUSY, "error");
  sync();
  if (holds(engaged) && (!engaged.partial || engaged.releaseUncertain)) void releaseBrake();
  else openBrakeDialog();
}

export function brakeBody(running: number | null): string {
  const what =
    running === null
      ? "pauses every process of every running run. The live feed is not current, so how many runs are running is unknown here; the result says what was paused."
      : `pauses every process of each running run (${running} now).`;
  return `This pauses daemon intake, so no new runs start, and ${what} Queued work stays in the queue. Release the brake to resume them.`;
}

export function renderBrakeBody(): void {
  const desc = document.getElementById("brake-desc");
  const running = hooks.isLive() ? (store.get("fleetState")?.pipelines?.length ?? 0) : null;
  if (desc) desc.textContent = brakeBody(running);
}

function openBrakeDialog(): void {
  if (!guardBrake()) return;
  if (isBusy()) return void toast(BUSY, "error");
  sync();
  dialogSeen = snap();
  renderBrakeBody();
  openDialog("emergency-modal");
}

/** A failed request in plain words; the raw error goes in the details. */
function plainError(err: unknown, what: string): string {
  if (err instanceof TypeError) return `The dashboard server did not answer the ${what}; it may have acted.`;
  if (err && typeof err === "object" && "status" in err) return `The dashboard server refused the ${what} (HTTP ${String(err.status)}).`;
  return `The ${what} was not sent: ${err instanceof Error ? err.message : String(err)}`;
}

/**
 * A request with no answer: it failed in transit, so the server may have acted. A server error
 * is an answer (a failed pause undoes itself), and a request the page blocked was never sent.
 */
const noAnswer = (r: PromiseSettledResult<unknown>) => r.status === "rejected" && r.reason instanceof TypeError;

/** The last attempt got no answer, so what it paused is unknown until a retry answers. */
const unanswered = (e: Engaged) => Boolean(e.uncertain || e.intakeUncertain);

type BrakeJob = api.BrakeResult["jobs"][number];

function jobProblem(j: BrakeJob): string | null {
  if (j.refused === "not running") return `#${j.issue}: no process was found for this run, so nothing was paused.`;
  if (j.refused) return `#${j.issue}: could not be confirmed as this run's pipeline, so nothing was paused.`;
  if (j.failed.length) return `#${j.issue}: ${plural(j.failed.length, "process")} could not be paused.`;
  if (!j.signalled.length) return `#${j.issue}: nothing was paused.`;
  return null;
}

const jobDetail = (j: BrakeJob) =>
  `#${j.issue} pid ${j.pid}: ${j.refused ?? j.failed.map((f) => `${f.pid} ${f.error}`).join(", ")}`;

/**
 * Pauses daemon intake and every process of every running run; both requests are always sent.
 * "Engaged" only when intake paused and the server reports every running run paused; anything
 * else leaves an alert, naming the runs, until it is dismissed.
 */
export async function engageBrake(seen?: string): Promise<void> {
  if (!guardBrake()) return;
  if (isBusy()) return void toast(BUSY, "error");
  await exclusive(() => engage(seen));
}

async function engage(seen?: string): Promise<void> {
  sync();
  if (seen !== undefined && snap() !== seen) return refuseChanged();
  const before = engaged;
  showAlert(null);
  // Until the answers arrive this attempt is unanswered: if the page closes or the answer is
  // lost, the brake stays visible as unconfirmed and a retry counts what it paused as its own.
  setBusy(true);
  save({ intake: false, issues: [], at: Date.now(), ...before, partial: true, uncertain: true, intakeUncertain: true });
  let settled: [PromiseSettledResult<{ ok: boolean; wasPaused?: boolean }>, PromiseSettledResult<api.BrakeResult>];
  try {
    settled = await Promise.allSettled([api.pauseIntakeForBrake(), api.emergencyBrake()]);
  } finally {
    setBusy(false);
  }
  const [intake, result] = settled;
  setTimeout(hooks.refresh, 500);
  const items: string[] = [];
  const details: string[] = [];
  const paused: number[] = [];
  const already: number[] = [];
  if (intake.status === "rejected") {
    items.push(`Intake: not confirmed paused. ${plainError(intake.reason, "brake")}`);
    details.push(`intake: ${String(intake.reason)}`);
  }
  if (result.status === "rejected") {
    items.push(`Runs: not confirmed paused. ${plainError(result.reason, "brake")}`);
    details.push(`runs: ${String(result.reason)}`);
  } else {
    for (const j of result.value.jobs) {
      const problem = jobProblem(j);
      // Someone else's pause only if the server says so, this brake never stopped any of the
      // run's processes, and no earlier attempt went unanswered.
      const theirs = j.wasPaused && !before?.issues.includes(j.issue) && !before?.uncertain;
      if (problem) {
        items.push(problem);
        details.push(jobDetail(j));
        // Partly stopped is still the brake's to release.
        if (j.signalled.length) paused.push(j.issue);
      } else (theirs ? already : paused).push(j.issue);
    }
    if (result.value.jobs.length !== result.value.running) items.push("The server's run list did not match its count.");
  }
  for (const n of [...paused, ...already]) pausedRuns.add(n);
  const intakeOk = intake.status === "fulfilled";
  // On a retry, what this brake paused the first time is still its own, not "already paused".
  const intakeAlready = intakeOk && Boolean(intake.value.wasPaused) && !before?.intake && !before?.intakeUncertain;
  const complete = items.length === 0 && result.status === "fulfilled";
  // Merge into the record as it is now (a hand resume in another tab may have changed it).
  sync();
  const now = engaged;
  save({
    intake: (intakeOk && !intakeAlready) || Boolean(before?.intake && now?.intake),
    // An answer replaces the flag: intake this attempt paused itself was not already paused.
    intakeAlready: intakeOk ? intakeAlready : now?.intakeAlready,
    issues: [...new Set([...(now?.issues ?? []), ...paused])],
    partial: !complete,
    // Unanswered until that request succeeds: a refused retry confirms nothing.
    // Pausing again settles any unanswered release.
    releaseUncertain: false,
    uncertain: noAnswer(result) || (Boolean(before?.uncertain) && result.status === "rejected"),
    intakeUncertain: noAnswer(intake) || (Boolean(before?.intakeUncertain) && intake.status === "rejected"),
    at: now?.at ?? Date.now(),
  });
  if (complete) {
    showAlert(null);
    const n = result.value.running;
    if (!holds(engaged)) {
      toast(
        n === 0
          ? "Emergency brake: intake was already paused and no runs were running; nothing changed."
          : `Emergency brake: intake and ${n === 1 ? "the 1 running run" : `all ${n} running runs`} were already paused; nothing changed.`,
      );
      return;
    }
    // Processes of runs this brake paused (a run that was already paused is re-signalled, not counted).
    const procs = result.value.jobs.filter((j) => !already.includes(j.issue)).reduce((sum, j) => sum + j.signalled.length, 0);
    const kept = already.length
      ? ` ${already.map((a) => `#${a}`).join(", ")} ${already.length === 1 ? "was" : "were"} already paused and stay${already.length === 1 ? "s" : ""} paused on release.`
      : "";
    const all = n === 1 ? "the 1 running run" : `all ${n} running runs`;
    toast(
      `Emergency brake engaged: intake ${intakeAlready ? "was already paused" : "paused"}; ` +
        (n === 0
          ? "no runs were running."
          : already.length === n
            ? `${all} ${n === 1 ? "was" : "were"} already paused and stay${n === 1 ? "s" : ""} paused on release.`
            : already.length
              ? `${n - already.length} of ${n} running runs paused (${plural(procs, "process")}).${kept}`
              : `${all} paused (${plural(procs, "process")}).`),
    );
    return;
  }
  showAlert({
    title: "Emergency brake incomplete",
    items,
    next: "Retry the brake. If it still fails, stop the daemon on the host: shipwright daemon stop.",
    retry: ["Retry brake", ((seen) => () => void engageBrake(seen))(snap())],
    details,
  });
}

function releaseBody(e: Engaged): string {
  const list = e.issues.map((n) => `#${n}`).join(", ");
  const what = [e.intake ? "daemon intake" : "", e.issues.length ? `the ${runs(e.issues.length)} this brake paused (${list})` : ""]
    .filter(Boolean)
    .join(" and ");
  const intakeKept = e.intakeAlready ? " Intake was paused before the brake and stays paused." : "";
  const maybe = e.releaseUncertain ? " The last release got no answer, so some of this may already be resumed." : "";
  return `This resumes ${what || "nothing: the brake paused nothing that is still paused"}. Runs paused another way stay paused.${intakeKept}${maybe}`;
}

async function releaseBrake(): Promise<void> {
  sync();
  if (!holds(engaged) || !guardAction()) return;
  if (isBusy()) return void toast(BUSY, "error");
  if (unanswered(engaged)) {
    toast("Retry the brake first: its last attempt got no answer, so what it paused is not known yet.", "error");
    return;
  }
  const seen = snap();
  const ok = await confirmDialog({
    title: "Release the emergency brake?",
    body: releaseBody(engaged),
    confirmLabel: "Release brake",
    cancelLabel: "Keep engaged",
  });
  if (ok) await release(seen);
}

/**
 * Refusals that mean the run is over: its process is gone, or (tmux) the pane shell outlived
 * the pipeline. A run paused by the brake keeps its pipeline process (stopped, not gone).
 */
const ended_ = (refused?: string) => refused === "not running" || Boolean(refused?.startsWith("no pipeline for #"));

/** Retry an unfinished release (already confirmed once). */
function retryRelease(): void {
  void release();
}

const release = (seen?: string) => exclusive(() => releaseHeld(seen));

async function releaseHeld(seen?: string): Promise<void> {
  sync();
  if (seen !== undefined && snap() !== seen) return refuseChanged();
  if (!holds(engaged)) return void toast("Nothing is left to release.");
  if (unanswered(engaged) || !guardAction()) return;
  if (isBusy()) return void toast(BUSY, "error");
  const e = engaged;
  setBusy(true);
  // Recorded before sending: if the page closes or the answer is lost, the brake says what it
  // releases may already be resumed, rather than that it is still paused.
  save({ ...e, releaseUncertain: true });
  let settled: PromiseSettledResult<{ ok: boolean } & Partial<api.TreeSignal>>[];
  try {
    settled = await Promise.allSettled([
      e.intake ? api.daemonControl("resume") : Promise.resolve({ ok: true }),
      ...e.issues.map((n) => api.sendIntervention(n, "resume")),
    ]);
  } finally {
    setBusy(false);
  }
  const [intake, ...results] = settled;
  setTimeout(hooks.refresh, 500);
  const items: string[] = [];
  const details: string[] = [];
  const left: number[] = [];
  const ended: number[] = [];
  if (intake.status === "rejected") {
    items.push(`Intake: not confirmed resumed. ${plainError(intake.reason, "release")}`);
    details.push(`intake: ${String(intake.reason)}`);
  }
  results.forEach((r, i) => {
    const n = e.issues[i];
    if (r.status === "fulfilled" && (r.value.ok || (ended_(r.value.refused) && !r.value.failed?.length))) {
      // A run stopped or finished while braked has nothing left to resume (the server continues
      // what the brake froze in it; a failure there keeps it in the list).
      if (!r.value.ok) ended.push(n);
      return void pausedRuns.delete(n);
    }
    if (r.status === "fulfilled" && r.value.refused && !ended_(r.value.refused) && !r.value.failed?.length) {
      // The record no longer verifies (a recycled PID, say): the brake cannot act on it any more,
      // so it leaves the list, and the operator is told to check it.
      items.push(`#${n}: could no longer be confirmed as this run's pipeline. Check it in Runs.`);
      details.push(`#${n}: ${r.value.refused}`);
      return void pausedRuns.delete(n);
    }
    left.push(n);
    items.push(r.status === "rejected" ? `#${n}: not confirmed resumed. ${plainError(r.reason, "release")}` : `#${n}: not resumed.`);
    details.push(`#${n}: ${r.status === "rejected" ? String(r.reason) : (r.value.refused ?? JSON.stringify(r.value.failed ?? []))}`);
  });
  const intakeLeft = e.intake && intake.status === "rejected";
  // A resume with no answer may have happened: kept in the list, but shown as "may be resumed".
  // Unconfirmed until a retry is answered in full: a refused retry confirms nothing.
  const all = [intake, ...results];
  const lost = all.some(noAnswer) || (Boolean(e.releaseUncertain) && all.some((r) => r.status === "rejected"));
  // Merge into the record as it is now: drop what this release settled, keep anything else.
  sync();
  const now = engaged ?? e;
  save({
    ...now,
    intake: now.intake && (!e.intake || intakeLeft),
    intakeResumed: now.intakeResumed || (e.intake && !intakeLeft),
    issues: now.issues.filter((n) => !e.issues.includes(n) || left.includes(n)),
    uncertain: false,
    intakeUncertain: false,
    releaseUncertain: lost,
  });
  if (items.length === 0) {
    showAlert(null);
    const resumed = e.issues.length - ended.length;
    const parts = [
      e.intake ? "intake resumed" : "",
      resumed ? `${runs(resumed)} resumed` : "",
      ended.length ? `${ended.map((n) => `#${n}`).join(", ")} had already ended` : "",
    ].filter(Boolean);
    toast(`Emergency brake released${parts.length ? ": " + parts.join("; ") : ""}.`);
    return;
  }
  showAlert({
    title: "Brake release incomplete",
    items,
    ...(holds(engaged)
      ? { next: "Retry the release, or resume runs one at a time from Runs.", retry: ["Retry release", ((seen) => () => void release(seen))(snap())] as [string, () => void] }
      : { next: "Check the runs listed above in Runs." }),
    details,
  });
}

// ── Shell state ─────────────────────────────────────────────────────────

interface AlertSpec {
  title: string;
  items: string[];
  next: string;
  retry?: [string, () => void];
  details: string[];
}

function showAlert(spec: AlertSpec | null): void {
  const el = document.getElementById("brake-alert");
  if (!el) return;
  if (!spec) {
    el.replaceChildren();
    el.hidden = true;
    return;
  }
  const btn = (text: string, onclick: () => void, cls = "btn sm") => h("button", { type: "button", class: cls, text, onclick });
  el.replaceChildren(
    h("h2", { text: spec.title }),
    h("ul", null, ...spec.items.map((text) => h("li", { text }))),
    h("p", { text: "Next: " + spec.next }),
    h("div", { class: "alert-actions" },
      ...(spec.retry ? [btn(spec.retry[0], spec.retry[1], "btn sm danger")] : []),
      btn("Open Runs", () => switchTab("runs")),
      btn("Dismiss", () => showAlert(null), "btn sm ghost"),
    ),
    h("details", null, h("summary", { text: "Details" }), h("pre", { text: spec.details.join("\n") || "None" })),
  );
  el.hidden = false;
}

function render(): void {
  watchOtherTab();
  // An unanswered attempt is shown even when nothing is confirmed: runs may be paused.
  const e = engaged;
  const releasable = holds(e) && !unanswered(e);
  const btn = document.getElementById("emergency-brake");
  if (btn) {
    const partial = Boolean(e?.partial || e?.releaseUncertain);
    btn.setAttribute("aria-pressed", e ? (partial ? "mixed" : "true") : "false");
    btn.setAttribute(
      "aria-label",
      !e
        ? "Emergency brake"
        : !holds(e)
          ? "Emergency brake unconfirmed. Activate to retry"
          : e.releaseUncertain
            ? "Emergency brake release unconfirmed. Activate to retry the release"
          : partial
            ? "Emergency brake partly engaged. Activate to retry"
            : "Emergency brake engaged. Activate to release",
    );
    const long = btn.querySelector(".label-long");
    const short = btn.querySelector(".label-short");
    if (long) {
      long.textContent = isBusy()
        ? "Brake: waiting"
        : !e
          ? "Emergency brake"
          : e.releaseUncertain
            ? "Release unconfirmed"
            : !holds(e)
              ? "Brake unconfirmed"
              : partial
                ? "Brake incomplete"
                : "Brake engaged";
    }
    if (short) short.textContent = isBusy() ? "Waiting" : !e ? "Pause all" : e.releaseUncertain ? "Release" : partial ? "Retry" : "Engaged";
  }
  const el = document.getElementById("brake-state");
  if (!el) return;
  if (!e) {
    el.replaceChildren();
    el.hidden = true;
    return;
  }
  const rel = Boolean(e.releaseUncertain);
  const intake = e.intake
    ? rel
      ? "intake may be resumed"
      : "intake paused"
    : e.intakeAlready
      ? "intake was already paused"
      : e.intakeResumed
        ? "intake resumed"
        : e.intakeUncertain
          ? "intake may be paused"
          : "intake not confirmed paused";
  if (isBusy()) {
    el.replaceChildren(h("span", { class: "brake-state-text", text: "Emergency brake: waiting for the dashboard server to answer…" }));
    el.hidden = false;
    return;
  }
  // After an unanswered request the server may have paused more runs than are confirmed here.
  const n = e.issues.length;
  const counted = rel ? (n ? `${runs(n)} may be resumed` : "") : `${runs(n)} paused by it`;
  const parts = [
    `Brake ${!holds(e) ? "unconfirmed" : rel ? "release unconfirmed" : e.partial ? "partly engaged" : "engaged"} since ${clock(new Date(e.at))}`,
    intake,
    e.uncertain ? (n ? `${counted}, and more runs may be paused` : "runs may be paused") : counted,
    ...(unanswered(e) ? ["its last attempt got no answer: retry to confirm"] : []),
    ...(rel ? ["the last release got no answer: retry it to confirm"] : []),
  ];
  el.replaceChildren(
    h("span", { class: "brake-state-text", text: parts.filter(Boolean).join(" · ") }),
    ...(e.partial && !rel ? [h("button", { type: "button", class: "btn sm", text: "Retry brake…", onclick: openBrakeDialog })] : []),
    ...(releasable
      ? [h("button", { type: "button", class: "btn sm", text: rel ? "Retry release" : "Release brake…", onclick: rel ? retryRelease : () => void releaseBrake() })]
      : []),
  );
  el.hidden = false;
}
