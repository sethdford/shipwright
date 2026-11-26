import { describe, expect, test } from "bun:test";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GitRepoDocs } from "./git-repo-docs";

const SHA = "a".repeat(40);

describe("GitRepoDocs", () => {
  test("working tree: lists tracked files and reads them from disk", async () => {
    const runner = new FakeProcessRunner([
      {
        prefix: ["git", "ls-files"],
        result: { exitCode: 0, stdout: "docs/adr/1.md\0docs/policies/x.md\0", stderr: "" },
      },
    ]);
    const docs = new GitRepoDocs(runner, new FakeFileReader({ "/repo/docs/adr/1.md": "# One" }));
    const listed = await docs.list({ root: "/repo" }, ["docs/adr/"]);
    expect(listed).toEqual({ ok: true, value: ["docs/adr/1.md", "docs/policies/x.md"] });
    expect(runner.calls[0]?.argv).toEqual(["git", "ls-files", "-z", "--", "docs/adr/"]);
    expect(await docs.read({ root: "/repo" }, "docs/adr/1.md")).toEqual({
      ok: true,
      value: "# One",
    });
  });

  test("a ref is resolved to one commit, and every list and read uses that commit", async () => {
    const runner = new FakeProcessRunner([
      { prefix: ["git", "rev-parse"], result: { exitCode: 0, stdout: `${SHA}\n`, stderr: "" } },
      {
        prefix: ["git", "ls-tree"],
        result: { exitCode: 0, stdout: "docs/adr/1.md\0", stderr: "" },
      },
      { prefix: ["git", "show"], result: { exitCode: 0, stdout: "# One", stderr: "" } },
    ]);
    const docs = new GitRepoDocs(runner, new FakeFileReader({}));
    const source = { root: "/repo", ref: "origin/main" };
    await docs.list(source, ["docs/adr/"]);
    expect(await docs.read(source, "docs/adr/1.md")).toEqual({ ok: true, value: "# One" });
    const argvs = runner.calls.map((c) => c.argv.join(" "));
    expect(argvs.filter((a) => a.startsWith("git rev-parse"))).toHaveLength(1);
    expect(argvs).toContain(`git show ${SHA}:docs/adr/1.md`);
  });

  test("refuses paths outside the repository and option-like refs without running git", async () => {
    const runner = new FakeProcessRunner([]);
    const docs = new GitRepoDocs(runner, new FakeFileReader({}));
    expect((await docs.read({ root: "/r" }, "../etc/passwd")).ok).toBe(false);
    expect((await docs.read({ root: "/r" }, "/etc/passwd")).ok).toBe(false);
    expect((await docs.list({ root: "/r", ref: "--output=x" }, ["docs/"])).ok).toBe(false);
    expect(runner.calls).toHaveLength(0);
  });

  test("an unknown ref is not_found", async () => {
    const runner = new FakeProcessRunner([
      { prefix: ["git", "rev-parse"], result: { exitCode: 1, stdout: "", stderr: "" } },
    ]);
    const r = await new GitRepoDocs(runner, new FakeFileReader({})).list(
      { root: "/r", ref: "nope" },
      ["docs/"],
    );
    expect(r.ok ? "ok" : r.error.kind).toBe("not_found");
  });
});
