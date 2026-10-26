// Content-Security-Policy for the dashboard page (epic #8697, decision 2: strict CSP).
// Every script, stylesheet, font and connection is same-origin; nothing runs inline.
// One narrow exception: style-src-attr 'unsafe-inline' lets the legacy view modules keep
// their computed inline widths and colours (style="width:42%") until T3 rewrites them with
// CSSOM custom properties. <style> elements and inline scripts stay blocked.

export const DASHBOARD_CSP = [
  "default-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self'",
  "style-src 'self'",
  "style-src-attr 'unsafe-inline'",
  "script-src 'self'",
  "font-src 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'self'",
].join("; ");

/**
 * Policy for the small server-rendered pages (login, logout confirmation, access denied).
 * They carry their styles inline and run no script, so inline style is allowed and
 * everything else, including remote fonts, is refused.
 */
export const INLINE_PAGE_CSP = [
  "default-src 'none'",
  "style-src 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'self'",
].join("; ");

/** Headers for HTML documents served from dashboard/public. */
export function htmlSecurityHeaders(): Record<string, string> {
  return { "Content-Security-Policy": DASHBOARD_CSP };
}

/** Headers for a server-rendered HTML page. */
export function inlinePageHeaders(): Record<string, string> {
  return { "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": INLINE_PAGE_CSP };
}
