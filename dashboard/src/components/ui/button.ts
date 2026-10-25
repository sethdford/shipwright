// Button. Danger buttons always open a confirmation (see dialog.ts confirmDialog).

import { h } from "./dom";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger";

export interface ButtonOptions {
  label: string;
  variant?: ButtonVariant;
  size?: "sm" | "md";
  onClick?: (e: MouseEvent) => void;
  disabledReason?: string;
}

export function button(opts: ButtonOptions): HTMLButtonElement {
  const variant = opts.variant ?? "secondary";
  const cls = ["btn", variant === "secondary" ? "" : variant, opts.size === "sm" ? "sm" : ""]
    .filter(Boolean)
    .join(" ");
  const el = h("button", { type: "button", class: cls, text: opts.label });
  if (opts.onClick) el.addEventListener("click", opts.onClick);
  setDisabled(el, opts.disabledReason);
  return el;
}

/**
 * Marks a control unavailable with a reason, or available again when no reason is given.
 * Uses aria-disabled so the control stays focusable and its reason (title) stays reachable;
 * click handlers check isDisabled() before acting.
 */
export function setDisabled(el: HTMLElement, reason?: string): void {
  if (reason) {
    el.setAttribute("aria-disabled", "true");
    el.title = reason;
  } else {
    el.removeAttribute("aria-disabled");
    el.removeAttribute("title");
  }
}

export function isDisabled(el: HTMLElement): boolean {
  return el.getAttribute("aria-disabled") === "true";
}
