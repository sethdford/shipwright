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

/**
 * The response with headers that can be set. Headers are set on the response itself where
 * possible: copying it with `new Response(body, res)` loses the type Bun infers for a string
 * body, and a text/plain 404 would become a download. Immutable headers (a proxied fetch
 * response) force a copy, which keeps the type explicitly. Probing sets nosniff, which every
 * response carries anyway.
 */
export function mutableResponse(res: Response): Response {
  try {
    res.headers.set("X-Content-Type-Options", "nosniff");
    return res;
  } catch {
    const type = res.headers.get("content-type");
    const out = new Response(res.body, res);
    if (type) out.headers.set("Content-Type", type);
    return out;
  }
}

/**
 * Applied to every response: nosniff everywhere, and a policy on any HTML or SVG document
 * that does not already carry one (error pages, static SVG).
 */
export function withSecurityHeaders(res: Response | undefined): Response | undefined {
  if (!res) return res;
  const out = mutableResponse(res);
  out.headers.set("X-Content-Type-Options", "nosniff");
  const type = out.headers.get("content-type") ?? "";
  if (/^(text\/html|image\/svg\+xml)/.test(type) && !out.headers.has("content-security-policy")) {
    out.headers.set("Content-Security-Policy", INLINE_PAGE_CSP);
  }
  return out;
}
