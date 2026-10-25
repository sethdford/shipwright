import { expect, test } from "bun:test";
import { scanText } from "./no-cdn";

// Each case is [file, source]. FLAG cases must report at least one external origin.
const FLAG: Array<[string, string]> = [
  // Round 1: loads through tags, CSS, JS and templates.
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
  // Comments with external origins are flagged: the allowlist has no comment exemption.
  ["a.ts", "// see https://example.com/spec"],

  // Round 2: parser and encoding evasions.
  ["a.html", '<script src="https://github.com.evil.io/x.js"></script>'],
  ["a.html", '<script src="https://evil.io/github.com/x.js"></script>'],
  ["a.html", '<script src="http://localhost.evil.io/x.js"></script>'],
  ["a.html", '<script src="http://127.0.0.1.nip.io/x.js"></script>'],
  ["a.html", '<script src="https://github.com@evil.io/x.js"></script>'],
  ["a.html", '<script src="http://localhost@evil.io/x.js"></script>'],
  ["a.html", '<script src="https://github.com:443@evil.io/x.js"></script>'],
  ["a.html", '<img src="https://github.com/evil/repo/raw/main/pixel.png">'],
  ["a.html", '<link rel="canonical stylesheet" href="https://evil.io/a.css">'],
  ["a.html", '<link rel="stylesheet" data-x="rel=canonical" href="https://evil.io/a.css">'],
  ["a.html", '<link rel=canonical href="https://evil.io/a.css" rel=stylesheet>'],
  ["a.html", '<meta http-equiv="refresh" content="0;url=https://evil.io/">'],
  ["a.html", "<link rel=preload href=//x.io/f.woff2 as=font>"],
  ["a.html", "<link rel=preload href=//x>"],
  ["a.ts", "await import(`//evil.io/x.js`)"],
  ["a.ts", 's.src = "\\/\\/evil.io/x.js"'],
  ["a.ts", 's.src = "https:\\/\\/evil.io/x.js"'],
  ["a.ts", 's.src = "https://" + "evil.io/x.js"'],
  ["a.ts", 's.src = "https://évil.io/x.js"'],
  ["a.ts", 's.src = "https://_x.evil.io/x.js"'],
  ["a.ts", 's.src = "https://[2001:db8::1]/x.js"'],
  ["a.html", '<script src="https:/evil.io/x.js"></script>'],
  ["a.html", '<script src="https:\\\\evil.io\\x.js"></script>'],
  ["a.html", '<script src=https://evil.io/x.js placeholder="'],
  ["a.ts", 'const t = "<meta"; s.src = "https://evil.io/x.js"; const f = () => 1;'],
  ["a.css", "@import url(//evil.io/a.css)"],
  ["a.css", ".x{background:url(//evil.io/p.png)}"],
  ["a.html", "<object data=//evil.io/x.swf>"],
  ["a.html", "<script src=//evil.io/x.js></script>"],
  ["a.html", "<link rel=stylesheet href=//evil.io/a.css>"],
  ["a.html", '<script src="&#104;ttps://evil.io/x.js"></script>'],

  // Project host in a load position is still a load.
  ["a.css", '@import "https://github.com/evil/x.css";'],
  ["a.css", ".x{background:url(https://github.com/evil/p.png)}"],
  ["a.ts", 'import x from "https://github.com/evil/x.js";'],
  ["a.ts", 'import("https://github.com/evil/x.js")'],

  // Schemes other than http(s) are not allowed, and a WebSocket template fails closed.
  ["a.ts", "const ws = new WebSocket(`ws://${location.host}/ws`)"],
  ["a.ts", 'const ws = new WebSocket("wss://evil.io/ws")'],
];

// ALLOW cases must report nothing.
const ALLOW: Array<[string, string]> = [
  ["a.ts", 'const docs = "https://github.com/sethdford/shipwright";'],
  ["a.html", '<a href="https://github.com/x">x</a>'],
  ["a.html", '<p>See <a href="https://github.com/sethdford/shipwright">the repo</a>.</p>'],
  ["a.css", 'background: url("/img/x.png")'],
  ["a.css", 'background: url(data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg"/>)'],
  ["a.html", '<link rel="canonical" href="https://shipwright.dev/">'],
  ["a.html", '<meta property="og:url" content="https://shipwright.dev/">'],
  ["a.html", '<meta name="description" content="Docs at https://shipwright.dev/">'],
  ["a.html", '<input placeholder="https://hooks.example.com/services/...">'],
  ["a.html", '<script src="/dist/main.js"></script>'],
  ["a.html", '<a href="http://localhost:3000/">local</a>'],
  ["a.html", '<svg xmlns="http://www.w3.org/2000/svg"></svg>'],
  ["a.ts", 'const local = "http://localhost:9999/api";'],
];

for (const [file, text] of FLAG) {
  test(`flags: ${JSON.stringify(text).slice(0, 80)}`, () => {
    expect(scanText(file, text).length).toBeGreaterThan(0);
  });
}

for (const [file, text] of ALLOW) {
  test(`allows: ${JSON.stringify(text).slice(0, 80)}`, () => {
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

test("a canonical link does not exempt a second rel", () => {
  expect(
    scanText("a.html", '<link rel="canonical" rel="stylesheet" href="https://evil.io/a.css">')
      .length,
  ).toBeGreaterThan(0);
});

test("a regex literal with // after an opening paren is not a URL", () => {
  expect(scanText("a.ts", 'const x = block.replace(//n?/g, "");')).toEqual([]);
});
