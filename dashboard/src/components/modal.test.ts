import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("../core/api", () => ({ sendIntervention: vi.fn() }));

import { sendRunAction, pausedRuns, confirmAbort } from "./modal";
import { store } from "../core/state";
import * as api from "../core/api";

const toast = () => document.getElementById("toast");

describe("sendRunAction reports what the server signalled", () => {
  beforeEach(() => {
    document.body.replaceChildren();
    pausedRuns.clear();
    vi.mocked(api.sendIntervention).mockReset();
    store.set("connected", true);
    store.set("currentUser", { username: "ada", role: "operator" });
  });

  it("treats ok:true with nothing signalled as 'not running', never success", async () => {
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true } as never);
    await sendRunAction(7, "pause");
    expect(toast()?.textContent).toBe("Pause did nothing: run #7 is not running.");
    expect(toast()?.getAttribute("role")).toBe("alert");
    expect(pausedRuns.has(7)).toBe(false);
  });

  it("names the refusal reason", async () => {
    vi.mocked(api.sendIntervention).mockResolvedValue({
      ok: true,
      signalled: [],
      failed: [],
      refused: "stale pid: the process started after the job",
    } as never);
    await sendRunAction(7, "resume");
    expect(toast()?.textContent).toBe("Resume did nothing: run #7 could not be confirmed as this run's pipeline (stale pid: the process started after the job).");
  });

  it("records a pause only when every process was signalled", async () => {
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [11, 10], failed: [] } as never);
    await sendRunAction(7, "pause");
    expect(pausedRuns.has(7)).toBe(true);
    expect(toast()?.textContent).toBe("Run #7 paused: 2 processes.");

    vi.mocked(api.sendIntervention).mockResolvedValue({
      ok: true,
      signalled: [10],
      failed: [{ pid: 11, error: "EPERM" }],
    } as never);
    await sendRunAction(8, "pause");
    expect(pausedRuns.has(8)).toBe(false);
    expect(toast()?.textContent).toBe("Pause incomplete for run #8: 1 process could not be signalled.");
  });

  it("reports processes killed after the stop grace period", async () => {
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [10, 11], failed: [], killed: [11] } as never);
    await sendRunAction(9, "abort");
    expect(toast()?.textContent).toBe("Run #9 stopped: 2 processes, 1 killed after the grace period.");
  });

  it("never calls a refused resume that continued leftovers a success", async () => {
    pausedRuns.add(12);
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: false, signalled: [5, 6], failed: [], refused: "not running" } as never);
    await sendRunAction(12, "resume");
    expect(toast()?.textContent).toBe("Run #12 had already ended; continued 2 processes its pause left frozen. Check the host.");
    expect(toast()?.getAttribute("role")).toBe("alert");
    expect(pausedRuns.has(12)).toBe(false);
  });

  it("says when a stop continued processes an earlier run of the issue left paused", async () => {
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [10, 11], failed: [], killed: [], continued: [7, 8] } as never);
    await sendRunAction(9, "abort");
    expect(toast()?.textContent).toBe(
      "Run #9 stopped: 2 processes. Continued 2 processes an earlier run left paused; check the host.",
    );
  });

  it("reports a stop as incomplete when escaped processes can't be traced", async () => {
    vi.mocked(api.sendIntervention).mockResolvedValue({
      ok: false,
      signalled: [10, 11],
      failed: [],
      killed: [],
      untraced: "the run does not lead its own process group",
    } as never);
    await sendRunAction(9, "abort");
    expect(toast()?.textContent).toBe(
      "Stop incomplete for run #9: 2 processes stopped, but processes that left the run can't be traced. Check the host.",
    );
    expect(toast()?.getAttribute("role")).toBe("alert");
  });

  it("sends nothing while disconnected", async () => {
    store.set("connected", false);
    await sendRunAction(7, "pause");
    expect(api.sendIntervention).not.toHaveBeenCalled();
  });
});

describe("confirmAbort", () => {
  it("names the stage by its label", async () => {
    store.set("connected", true);
    store.set("currentUser", { username: "ada", role: "operator" });
    const pending = confirmAbort(12, "compound_quality");
    const dlg = document.querySelector("dialog.confirm-dialog") as HTMLDialogElement;
    expect(dlg.querySelector("h2")?.textContent).toBe("Stop run #12?");
    expect(dlg.querySelector("p")?.textContent).toMatch(/^The run is in the Compound quality stage\. /);
    (document.activeElement as HTMLElement).click();
    await pending;
    expect(api.sendIntervention).not.toHaveBeenCalled();
  });
});
