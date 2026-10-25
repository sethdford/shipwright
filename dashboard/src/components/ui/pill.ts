// Status pill: tone, glyph and text together. Colour never carries meaning alone.

import { h } from "./dom";

export type Tone = "ok" | "warn" | "danger" | "info" | "neutral" | "accent";

export const GLYPHS = {
  ok: "✓",
  fail: "✕",
  warn: "▲",
  half: "◐",
  live: "●",
  idle: "○",
  unknown: "?",
  skip: "–",
} as const;

export function pill(tone: Tone, glyph: string, text: string, title?: string): HTMLSpanElement {
  const el = h("span", { class: "pill", "data-tone": tone, title });
  setPill(el, tone, glyph, text);
  return el;
}

/** Updates an existing pill in place (keeps its id and listeners). */
export function setPill(el: HTMLElement, tone: Tone, glyph: string, text: string): void {
  el.dataset.tone = tone;
  el.replaceChildren(
    h("span", { class: "glyph", "aria-hidden": "true", text: glyph }),
    h("span", { text }),
  );
}
