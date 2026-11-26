import type { Flow } from "./config";
import type { WebFramework } from "./detect";

/**
 * Which pages a change touched, from its changed file paths (ADR-0019). File-system routers map a
 * file to a URL directly; anything else falls back to the home page. Dynamic segments ([id],
 * :id, $id) cannot be filled in without data, so those pages are skipped and the home page kept.
 */

export const MAX_ROUTES = 5;

interface Router {
  readonly pattern: RegExp;
  /** Turns the captured page path into a URL path, or null when it is not a page. */
  readonly toRoute: (page: string) => string | null;
}

const indexless = (p: string): string => p.replace(/(^|\/)index$/, "").replace(/\/$/, "");
const groups = (p: string): string => p.replace(/\([^/)]*\)\/?/g, "");

const ROUTERS: Partial<Record<WebFramework, readonly Router[]>> = {
  next: [
    { pattern: /^(?:src\/)?app\/(.*?)\/?page\.(?:tsx|jsx|ts|js|mdx)$/, toRoute: (p) => groups(p) },
    {
      pattern: /^(?:src\/)?pages\/(.+)\.(?:tsx|jsx|ts|js|mdx)$/,
      toRoute: (p) => (/^(api\/|_app|_document|_error)/.test(p) ? null : indexless(p)),
    },
  ],
  sveltekit: [{ pattern: /^src\/routes\/(.*?)\/?\+page\.svelte$/, toRoute: (p) => groups(p) }],
  astro: [{ pattern: /^src\/pages\/(.+)\.(?:astro|md|mdx)$/, toRoute: (p) => indexless(p) }],
  nuxt: [{ pattern: /^(?:app\/)?pages\/(.+)\.vue$/, toRoute: (p) => indexless(p) }],
  remix: [
    {
      pattern: /^app\/routes\/(.+)\.(?:tsx|jsx)$/,
      toRoute: (p) => indexless(p.replace(/\._index$|^_index$/, "").replace(/\./g, "/")),
    },
  ],
};

const DYNAMIC = /\[|\]|(^|\/)[:$]/;

function routeOf(framework: WebFramework, file: string): string | null {
  for (const router of ROUTERS[framework] ?? []) {
    const m = router.pattern.exec(file);
    if (!m) continue;
    const page = router.toRoute(m[1] ?? "");
    if (page === null || DYNAMIC.test(page)) return null;
    return `/${page}`.replace(/\/+/g, "/");
  }
  return null;
}

/** Up to MAX_ROUTES pages a change touched, always starting with "/" as the smoke page. */
export function changedRoutes(framework: WebFramework, changed: readonly string[]): string[] {
  const routes = ["/"];
  for (const file of changed) {
    const route = routeOf(framework, file);
    if (route !== null && !routes.includes(route)) routes.push(route);
    if (routes.length >= MAX_ROUTES) break;
  }
  return routes;
}

/** A screenshot name for a route: "/" is "home", "/settings/profile" is "settings-profile". */
export function slugOf(route: string): string {
  const slug = route
    .replace(/^\/+|\/+$/g, "")
    .replace(/[^A-Za-z0-9]+/g, "-")
    .slice(0, 50);
  return slug === "" ? "home" : slug;
}

/** One visit-and-capture flow per route. */
export function routeFlows(routes: readonly string[]): Flow[] {
  return routes.map((route) => ({
    name: `page ${route}`,
    steps: [{ goto: route }, { screenshot: slugOf(route) }],
  }));
}
