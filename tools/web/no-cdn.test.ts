import { expect, test } from "bun:test";
import { scanText } from "./no-cdn";

const FLAG: Array<[string, string]> = [
  ["a.html", '<script src="//cdn.example.com/x.js"></script>'],
  ["a.css", '@import "//cdn.example.com/a.css";'],
  ["a.css", "@import url(//cdn.example.com/a.css);"],
  ["a.css", "src: url(//fonts.gstatic.com/x.woff2)"],
  ["a.css", '@import "https://cdn.example.com/a.css";'],
  ["a.css", "@IMPORT URL(HTTPS://cdn.example.com/a.css);"],
  ["a.html", '<SCRIPT SRC="HTTPS://cdn.example.com/x.js"></SCRIPT>'],
  ["a.ts", 'import x from "HTTPS://esm.sh/x";'],
  ["a.ts", "await import(`https://esm.sh/x`)"],
  ["a.ts", 'const s=document.createElement("script"); s.src = "https://cdn.example.com/x.js";'],
  ["a.ts", 'el.innerHTML = `<script src="https://cdn.example.com/x.js"></script>`'],
  ["a.ts", 'el.innerHTML = `<link rel=stylesheet href=${"https://cdn.x/a.css"}>`'],
  ["a.ts", 'new FontFace("X", "url(https://fonts.example.com/x.woff2)")'],
  ["a.html", '<script\n  src="https://cdn.example.com/x.js"></script>'],
  ["a.html", "<script src='https://cdn.example.com/x.js'></script>"],
  ["a.html", '<link rel="preload" href="https://fonts.gstatic.com/x.woff2" as="font">'],
  ["a.html", '<img src="https://cdn.example.com/x.png">'],
  ["a.html", '<iframe src="https://evil.example.com/">'],
  ["a.ts", 'const u="https://cdn.example.com"; s.src=u+"/x.js";'],
  ["a.ts", 'fetch("https://api.example.com/x")'],
  ["a.ts", 'navigator.sendBeacon("https://t.example.com")'],
  // Comments are flagged too: the allowlist has no comment exemption.
  ["a.ts", "// see https://example.com/spec"],
];

const ALLOW: Array<[string, string]> = [
  ["a.ts", 'const docs = "https://github.com/sethdford/shipwright";'],
  ["a.html", '<a href="https://github.com/x">x</a>'],
  ["a.ts", "const ws = new WebSocket(`ws://${location.host}/ws`)"],
  ["a.css", 'background: url("/img/x.png")'],
  ["a.css", 'background: url(data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg"/>)'],
  ["a.html", '<link rel="canonical" href="https://shipwright.dev/">'],
  ["a.html", '<meta property="og:url" content="https://shipwright.dev/">'],
  ["a.html", '<input placeholder="https://hooks.example.com/services/...">'],
  ["a.html", '<script src="/dist/main.js"></script>'],
  ["a.html", '<a href="http://localhost:3000/">local</a>'],
];

for (const [file, text] of FLAG) {
  test(`flags external origin: ${text.slice(0, 60)}`, () => {
    expect(scanText(file, text).length).toBeGreaterThan(0);
  });
}

for (const [file, text] of ALLOW) {
  test(`allows: ${text.slice(0, 60)}`, () => {
    expect(scanText(file, text)).toEqual([]);
  });
}

test("reports the line of a multi-line tag", () => {
  const found = scanText(
    "a.html",
    '<p>ok</p>\n<script\n  src="https://cdn.example.com/x.js"></script>',
  );
  expect(found.map((f) => f.line)).toEqual([3]);
});
