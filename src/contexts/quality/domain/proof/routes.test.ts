import { expect, test } from "bun:test";
import { changedRoutes, MAX_ROUTES, routeFlows, slugOf } from "./routes";

test("Next.js app and pages routers map files to pages", () => {
  expect(
    changedRoutes("next", [
      "app/settings/page.tsx",
      "src/app/(marketing)/pricing/page.tsx",
      "app/page.tsx",
      "pages/about/index.tsx",
      "pages/api/users.ts",
      "pages/_app.tsx",
      "lib/util.ts",
    ]),
  ).toEqual(["/", "/settings", "/pricing", "/about"]);
});

test("dynamic segments are skipped: there is no data to fill them", () => {
  expect(changedRoutes("next", ["app/users/[id]/page.tsx"])).toEqual(["/"]);
  expect(changedRoutes("remix", ["app/routes/users.$id.tsx"])).toEqual(["/"]);
});

test("SvelteKit, Astro, Nuxt and Remix", () => {
  expect(changedRoutes("sveltekit", ["src/routes/blog/+page.svelte"])).toEqual(["/", "/blog"]);
  expect(changedRoutes("astro", ["src/pages/docs/intro.md"])).toEqual(["/", "/docs/intro"]);
  expect(changedRoutes("nuxt", ["pages/cart.vue"])).toEqual(["/", "/cart"]);
  expect(
    changedRoutes("remix", ["app/routes/settings.profile.tsx", "app/routes/_index.tsx"]),
  ).toEqual(["/", "/settings/profile"]);
});

test("frameworks without file routes, and too many pages", () => {
  expect(changedRoutes("vite", ["src/pages/a.tsx"])).toEqual(["/"]);
  const many = Array.from({ length: 20 }, (_, i) => `app/p${i}/page.tsx`);
  expect(changedRoutes("next", many)).toHaveLength(MAX_ROUTES);
});

test("flows visit and capture each route", () => {
  expect(slugOf("/")).toBe("home");
  expect(slugOf("/settings/profile")).toBe("settings-profile");
  expect(routeFlows(["/", "/a"])).toEqual([
    { name: "page /", steps: [{ goto: "/" }, { screenshot: "home" }] },
    { name: "page /a", steps: [{ goto: "/a" }, { screenshot: "a" }] },
  ]);
});
