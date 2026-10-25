// Native <dialog> helpers. showModal() gives the focus trap, Esc and the inert backdrop;
// these helpers add focus return and a promise-based confirmation with Cancel focused.

import { h } from "./dom";

const openers = new WeakMap<HTMLDialogElement, HTMLElement | null>();

function resolve(target: string | HTMLDialogElement): HTMLDialogElement | null {
  return typeof target === "string"
    ? (document.getElementById(target) as HTMLDialogElement | null)
    : target;
}

export function openDialog(target: string | HTMLDialogElement): HTMLDialogElement | null {
  const dlg = resolve(target);
  if (!dlg || dlg.open) return dlg;
  openers.set(dlg, document.activeElement as HTMLElement | null);
  if (!dlg.dataset.wired) {
    dlg.dataset.wired = "1";
    dlg.addEventListener("close", () => {
      const back = openers.get(dlg);
      if (back && back.isConnected && typeof back.focus === "function") back.focus();
    });
    // A click on the backdrop lands on the dialog element itself.
    dlg.addEventListener("click", (e) => {
      if (e.target === dlg && dlg.dataset.dismissable !== "false") dlg.close();
    });
    dlg.querySelectorAll<HTMLElement>("[data-close]").forEach((btn) =>
      btn.addEventListener("click", () => dlg.close()),
    );
  }
  dlg.showModal();
  dlg.querySelector<HTMLElement>("[autofocus]")?.focus();
  return dlg;
}

export function closeDialog(target: string | HTMLDialogElement): void {
  const dlg = resolve(target);
  if (dlg?.open) dlg.close();
}

export function anyDialogOpen(): boolean {
  return document.querySelector("dialog[open]") !== null;
}

export interface ConfirmOptions {
  title: string;
  body: string;
  confirmLabel: string;
  cancelLabel?: string;
  danger?: boolean;
}

/**
 * Asks for confirmation in a modal dialog. Cancel has focus, so Enter or Esc never confirms
 * by accident. Resolves true only when the confirm button is activated.
 */
export function confirmDialog(opts: ConfirmOptions): Promise<boolean> {
  const id = "dlg-" + Math.random().toString(36).slice(2, 8);
  const cancel = h("button", { type: "button", class: "btn", autofocus: true, text: opts.cancelLabel ?? "Cancel" });
  const ok = h("button", {
    type: "button",
    class: opts.danger ? "btn danger-solid" : "btn primary",
    text: opts.confirmLabel,
  });
  const dlg = h(
    "dialog",
    { class: "confirm-dialog", "aria-labelledby": id + "-t", "aria-describedby": id + "-d" },
    h("div", { class: "confirm" },
      h("h2", { id: id + "-t", text: opts.title }),
      h("p", { id: id + "-d", text: opts.body }),
      h("div", { class: "actions" }, cancel, ok),
    ),
  );
  document.body.append(dlg);
  return new Promise((done) => {
    let confirmed = false;
    cancel.addEventListener("click", () => dlg.close());
    ok.addEventListener("click", () => {
      confirmed = true;
      dlg.close();
    });
    dlg.addEventListener("close", () => {
      dlg.remove();
      done(confirmed);
    });
    openDialog(dlg);
  });
}
