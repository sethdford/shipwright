import { expect, test } from "bun:test";
import { scanText } from "./no-cdn";

test("flags external scripts, stylesheets, CSS imports and font urls", () => {
  const html = [
    '<script src="https://cdn.example.com/lib.js"></script>',
    '<link rel="stylesheet" href="https://fonts.example.com/css">',
  ].join("\n");
  expect(scanText("index.html", html).map((f) => f.line)).toEqual([1, 2]);
  expect(scanText("a.css", '@import url("https://x.example.com/a.css");')).toHaveLength(1);
  expect(scanText("a.css", "@font-face { src: url(https://x.example.com/f.woff2); }")).toHaveLength(
    1,
  );
  expect(scanText("main.ts", 'await import("https://x.example.com/m.js")')).toHaveLength(1);
});

test("allows same-origin loads, plain links and namespace URIs", () => {
  const ok = [
    '<script src="/dist/main.js"></script>',
    '<link rel="stylesheet" href="/styles.css">',
    '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
    '<link rel="icon" href="data:image/svg+xml,<svg xmlns=\'http://www.w3.org/2000/svg\'/>">',
    'const docs = "https://github.com/sethdford/shipwright";',
    '<input placeholder="https://hooks.example.com/services/...">',
  ].join("\n");
  expect(scanText("index.html", ok)).toEqual([]);
});

test("allows same-origin font loads from /fonts/", () => {
  expect(
    scanText("fonts.css", 'src: url("/fonts/PlusJakartaSans-latin.woff2") format("woff2");'),
  ).toEqual([]);
});
