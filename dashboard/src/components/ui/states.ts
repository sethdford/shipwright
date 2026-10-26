// Empty, error, offline and loading states (spec section 4.4). Copy names the action.

import { h } from "./dom";
import { button } from "./button";

export function emptyState(title: string, action?: string): HTMLDivElement {
  return h("div", { class: "state state-empty" },
    h("p", { class: "state-title", text: title }),
    action ? h("p", { class: "state-body", text: action }) : null,
  );
}

export interface ErrorStateOptions {
  route: string;
  status?: number | string;
  lastGood?: Date | null;
  onRetry: () => void;
}

/** A failed fetch: names the route, the status, when data was last good, and offers Retry. */
export function errorState(opts: ErrorStateOptions): HTMLDivElement {
  const status = opts.status == null ? "no response" : "HTTP " + opts.status;
  const last = opts.lastGood ? "Showing data from " + clock(opts.lastGood) + "." : "No data loaded yet.";
  return h("div", { class: "state state-error", role: "alert" },
    h("p", { class: "state-title" },
      h("span", { class: "glyph", "aria-hidden": "true", text: "✕" }),
      "Could not load ",
      h("code", { text: opts.route }),
      " (" + status + ").",
    ),
    h("p", { class: "state-body", text: last }),
    button({ label: "Retry", size: "sm", onClick: opts.onRetry }),
  );
}

/** Placeholder rows sized like the final content, so nothing shifts when data lands. */
export function skeleton(rows = 3): HTMLDivElement {
  const el = h("div", { class: "skeleton", "aria-hidden": "true" });
  for (let i = 0; i < rows; i++) el.append(h("div", { class: "skeleton-row" }));
  return el;
}

export function clock(d: Date): string {
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
}
