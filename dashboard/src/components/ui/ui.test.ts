import { describe, it, expect, vi } from "vitest";
import { h, hydrateInitialHidden } from "./dom";
import { pill, setPill } from "./pill";
import { button, setDisabled, isDisabled } from "./button";
import { confirmDialog, openDialog, anyDialogOpen } from "./dialog";
import { errorState, offlineText, emptyState, skeleton } from "./states";
import { setupTablist } from "./tabs";
import { toast } from "./toast";

describe("h", () => {
  it("sets text as text, never as markup", () => {
    const el = h("p", { class: "x", text: "<b>hi</b>" });
    expect(el.textContent).toBe("<b>hi</b>");
    expect(el.querySelector("b")).toBeNull();
    expect(el.className).toBe("x");
  });

  it("wires on* props as listeners and skips null and false", () => {
    const fn = vi.fn();
    const el = h("button", { onclick: fn, title: null, disabled: false, autofocus: true });
    el.click();
    expect(fn).toHaveBeenCalled();
    expect(el.hasAttribute("title")).toBe(false);
    expect(el.hasAttribute("disabled")).toBe(false);
    expect(el.hasAttribute("autofocus")).toBe(true);
  });
});

describe("hydrateInitialHidden", () => {
  it("turns data-hidden into an inline display:none a view can clear", () => {
    const el = h("div", { "data-hidden": true });
    document.body.replaceChildren(el);
    hydrateInitialHidden();
    expect(el.style.display).toBe("none");
    expect(el.hasAttribute("data-hidden")).toBe(false);
    el.style.display = "";
    expect(el.style.display).toBe("");
  });
});

describe("pill", () => {
  it("always carries tone, a hidden glyph and a text label", () => {
    const el = pill("danger", "✕", "Failed");
    expect(el.dataset.tone).toBe("danger");
    expect(el.querySelector(".glyph")?.getAttribute("aria-hidden")).toBe("true");
    expect(el.textContent).toContain("Failed");
    setPill(el, "ok", "✓", "Passed");
    expect(el.dataset.tone).toBe("ok");
    expect(el.textContent).toBe("✓Passed");
  });
});

describe("button", () => {
  it("maps variants to classes and keeps a disabled control focusable with its reason", () => {
    const b = button({ label: "Stop", variant: "danger", size: "sm" });
    expect(b.className).toBe("btn danger sm");
    expect(b.type).toBe("button");
    setDisabled(b, "Offline");
    expect(isDisabled(b)).toBe(true);
    expect(b.disabled).toBe(false);
    expect(b.title).toBe("Offline");
    setDisabled(b);
    expect(isDisabled(b)).toBe(false);
  });
});

describe("confirmDialog", () => {
  it("focuses Cancel and resolves false on cancel", async () => {
    const p = confirmDialog({ title: "Stop run #7?", body: "Ends it.", confirmLabel: "Stop run", danger: true });
    const dlg = document.querySelector("dialog.confirm-dialog") as HTMLDialogElement;
    expect(dlg.open).toBe(true);
    expect(anyDialogOpen()).toBe(true);
    expect(document.activeElement?.textContent).toBe("Cancel");
    expect(dlg.querySelector("h2")?.textContent).toBe("Stop run #7?");
    (document.activeElement as HTMLElement).click();
    await expect(p).resolves.toBe(false);
    expect(document.querySelector("dialog.confirm-dialog")).toBeNull();
  });

  it("resolves true only from the confirm button", async () => {
    const p = confirmDialog({ title: "Go?", body: "", confirmLabel: "Engage brake", danger: true });
    const ok = Array.from(document.querySelectorAll("dialog button")).find((b) => b.textContent === "Engage brake") as HTMLElement;
    expect(ok.className).toContain("danger-solid");
    ok.click();
    await expect(p).resolves.toBe(true);
  });

  it("names the dialog by its title and description", () => {
    void confirmDialog({ title: "T", body: "B", confirmLabel: "OK" });
    const dlg = document.querySelector("dialog.confirm-dialog") as HTMLDialogElement;
    const title = document.getElementById(dlg.getAttribute("aria-labelledby") ?? "");
    const desc = document.getElementById(dlg.getAttribute("aria-describedby") ?? "");
    expect(title?.textContent).toBe("T");
    expect(desc?.textContent).toBe("B");
    dlg.close();
  });
});

describe("openDialog", () => {
  it("wires data-close and returns focus to the opener", () => {
    const opener = h("button", { text: "open" });
    const close = h("button", { "data-close": true, text: "Close" });
    const dlg = h("dialog", { id: "d1" }, close);
    document.body.replaceChildren(opener, dlg);
    opener.focus();
    openDialog("d1");
    expect(dlg.open).toBe(true);
    close.click();
    expect(dlg.open).toBe(false);
    expect(document.activeElement).toBe(opener);
  });
});

describe("states", () => {
  it("error state names the route, the status and the last good data, with Retry", () => {
    const retry = vi.fn();
    const el = errorState({ route: "/api/metrics", status: 502, lastGood: new Date(2026, 9, 25, 14, 2), onRetry: retry });
    expect(el.getAttribute("role")).toBe("alert");
    expect(el.textContent).toContain("/api/metrics");
    expect(el.textContent).toContain("HTTP 502");
    expect(el.textContent).toContain("Showing data from 14:02.");
    el.querySelector("button")?.click();
    expect(retry).toHaveBeenCalled();
  });

  it("offline text gives both timestamps", () => {
    expect(offlineText(new Date(2026, 9, 25, 14, 2), new Date(2026, 9, 25, 14, 1))).toBe(
      "Offline since 14:02. Showing data from 14:01.",
    );
    expect(offlineText(new Date(2026, 9, 25, 9, 5), null)).toBe("Offline since 09:05. No data received yet.");
  });

  it("empty state and skeleton render", () => {
    expect(emptyState("No runs yet.", "Label an issue shipwright.").textContent).toContain("Label an issue");
    const sk = skeleton(4);
    expect(sk.children).toHaveLength(4);
    expect(sk.getAttribute("aria-hidden")).toBe("true");
  });
});

describe("setupTablist", () => {
  it("moves focus with arrows, Home and End and hands the tab stop back on leave", () => {
    const tabs = ["a", "b", "c"].map((id, i) =>
      h("button", { role: "tab", id, "aria-selected": String(i === 0), tabindex: i === 0 ? "0" : "-1" }),
    );
    const list = h("div", { role: "tablist" }, ...tabs);
    const outside = h("button", { text: "x" });
    document.body.replaceChildren(list, outside);
    setupTablist(list);
    const press = (key: string) =>
      document.activeElement?.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
    tabs[0].focus();
    press("ArrowRight");
    expect(document.activeElement).toBe(tabs[1]);
    press("End");
    expect(document.activeElement).toBe(tabs[2]);
    press("ArrowRight");
    expect(document.activeElement).toBe(tabs[0]);
    press("ArrowLeft");
    press("Home");
    expect(document.activeElement).toBe(tabs[0]);
    press("ArrowRight");
    expect(tabs[1].tabIndex).toBe(0);
    list.dispatchEvent(new FocusEvent("focusout", { relatedTarget: outside }));
    expect(tabs.map((t) => t.tabIndex)).toEqual([0, -1, -1]);
  });
});

describe("toast", () => {
  it("uses role=status for results and role=alert for errors", () => {
    toast("Sent");
    const el = document.getElementById("toast") as HTMLElement;
    expect(el.getAttribute("role")).toBe("status");
    expect(el.hidden).toBe(false);
    toast("Failed", "error");
    expect(el.getAttribute("role")).toBe("alert");
    expect(el.textContent).toBe("Failed");
  });
});
