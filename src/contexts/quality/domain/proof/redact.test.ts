import { expect, test } from "bun:test";
import { REDACTED, redact, tail } from "./redact";

test("tokens, keys and credentials in URLs are removed", () => {
  const text = [
    "token ghp_abcdefghijklmnopqrstuvwxyz123456",
    "anthropic sk-ant-api03-abcdefghijklmnopqrstuvwx",
    "aws AKIAABCDEFGHIJKLMNOP",
    "DATABASE_PASSWORD=hunter2",
    'API_KEY: "s3cret value"',
    "db postgres://admin:pw@localhost:5432/x",
    "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----",
  ].join("\n");
  const out = redact(text);
  for (const secret of [
    "ghp_abc",
    "sk-ant-api03",
    "AKIAABCD",
    "hunter2",
    "s3cret",
    "admin:pw",
    "BEGIN RSA",
  ])
    expect(out).not.toContain(secret);
  expect(out).toContain(`DATABASE_PASSWORD=${REDACTED}`);
  expect(out).toContain(`postgres://${REDACTED}@localhost`);
});

test("ordinary output is untouched", () => {
  const text = "ready on http://127.0.0.1:3000\nGET / 200 12ms";
  expect(redact(text)).toBe(text);
});

test("tail keeps the last lines", () => {
  expect(tail("short", 100)).toBe("short");
  expect(tail("line1\nline2\nline3", 8)).toBe("…\nline3");
});
