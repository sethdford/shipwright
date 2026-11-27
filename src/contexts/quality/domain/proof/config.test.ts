import { expect, test } from "bun:test";
import { NO_CONFIG, parseProofConfig } from "./config";

test("no file is the empty config", () => {
  expect(parseProofConfig(null)).toEqual({ ok: true, config: NO_CONFIG });
});

test("a full config parses, with defaults filled in", () => {
  const r = parseProofConfig(
    JSON.stringify({
      web: {
        start: ["npm", "run", "dev"],
        port: 3000,
        allowHosts: ["*.googleapis.com"],
        flows: [
          {
            name: "login",
            steps: [
              { goto: "/login" },
              { fill: { selector: "#email", value: "a@b.co" } },
              { press: { key: "Enter" } },
              { expectText: "Welcome" },
              { screenshot: "signed-in" },
            ],
          },
        ],
      },
      cli: { runs: [{ name: "help", argv: ["node", "bin/x.js", "--help"] }] },
    }),
  );
  expect(r.ok).toBe(true);
  if (!r.ok) return;
  expect(r.config.enabled).toBe(true);
  expect(r.config.cli?.runs[0]?.expectExit).toBe(0);
  expect(r.config.web?.flows?.[0]?.steps).toHaveLength(5);
});

test("every problem is listed: bad JSON, unknown keys, remote URLs, code-like steps", () => {
  expect(parseProofConfig("{")).toEqual({
    ok: false,
    problems: [".shipwright/proof.json is not valid JSON"],
  });
  const r = parseProofConfig(
    JSON.stringify({
      web: {
        url: "https://evil.example.com",
        flows: [{ name: "x", steps: [{ evaluate: "fetch('//evil')" }] }],
        port: 80,
      },
      extra: 1,
    }),
  );
  expect(r.ok).toBe(false);
  if (r.ok) return;
  expect(r.problems.join("\n")).toContain("web.url");
  expect(r.problems.join("\n")).toContain("web.port");
  expect(r.problems.join("\n")).toContain("web.flows.0.steps.0");
  expect(r.problems.join("\n")).toContain("extra");
});

test("screenshot names are file-safe", () => {
  const r = parseProofConfig(
    JSON.stringify({ web: { flows: [{ name: "a", steps: [{ screenshot: "../../etc" }] }] } }),
  );
  expect(r.ok).toBe(false);
});
