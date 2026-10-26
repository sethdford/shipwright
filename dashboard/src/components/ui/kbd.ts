// Keyboard hint: one <kbd> per key.

import { h } from "./dom";

export function isMac(): boolean {
  return typeof navigator !== "undefined" && /Mac|iP(hone|ad|od)/.test(navigator.platform || navigator.userAgent);
}

/** The modifier glyph for this platform: ⌘ on Apple devices, Ctrl elsewhere. */
export function modKey(): string {
  return isMac() ? "⌘" : "Ctrl";
}

export function kbd(...keys: string[]): HTMLSpanElement {
  return h("span", { class: "kbd-group" }, ...keys.map((k) => h("kbd", { text: k })));
}
