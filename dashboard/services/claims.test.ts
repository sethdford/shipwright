import { readFileSync } from "fs";
import { join } from "path";
import { describe, it, expect, vi, beforeEach } from "vitest";

// Any real subprocess call from the modules under test is a bug: fail loudly.
vi.mock("child_process", () => {
  const mocked = {
    execFileSync: vi.fn(() => {
      throw new Error("real subprocess invoked in test");
    }),
    execSync: vi.fn(() => {
      throw new Error("real shell invoked in test");
    }),
  };
  return { ...mocked, default: mocked };
});

import {
  handleClaim,
  handleClaimRelease,
  releaseStaleClaims,
  parseIssueNumber,
  isValidMachineName,
  isValidRepo,
  type CommandRunner,
} from "./claims";
import {
  validateMachineFields,
  sshArgv,
  isSignalablePid,
  signalPid,
} from "./subprocess-guards";

/** Minimal POSIX-ish word splitter for the old shell command strings. */
function shellSplit(cmd: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inWord = false;
  let q: "'" | '"' | null = null;
  for (const ch of cmd) {
    if (q) {
      if (ch === q) q = null;
      else cur += ch;
    } else if (ch === "'" || ch === '"') {
      q = ch;
      inWord = true;
    } else if (ch === " ") {
      if (inWord) out.push(cur);
      cur = "";
      inWord = false;
    } else {
      cur += ch;
      inWord = true;
    }
  }
  if (inWord) out.push(cur);
  return out;
}

type Call = { file: string; args: string[] };

function makeRunner(responses: Array<string | Error> = []) {
  const calls: Call[] = [];
  const run: CommandRunner = (file, args) => {
    calls.push({ file, args: [...args] });
    const r = responses.shift();
    if (r instanceof Error) throw r;
    return r ?? "";
  };
  return { run, calls };
}

const MALICIOUS = [
  "x; touch /tmp/pwned",
  "$(id)",
  "`id`",
  'a" --add-label "x',
  "a'b",
  "a b",
  "a|b",
  "a&&b",
  "a\nb",
  "../../x",
  "",
];

describe("input validation", () => {
  it("parseIssueNumber accepts positive safe integers only", () => {
    expect(parseIssueNumber(42)).toBe(42);
    expect(parseIssueNumber("42")).toBe(42);
    for (const bad of [
      0,
      -1,
      1.5,
      NaN,
      Infinity,
      Number.MAX_SAFE_INTEGER + 1,
      "0",
      "-1",
      "42; id",
      "$(id)",
      "`id`",
      "1e3",
      " 42",
      null,
      undefined,
      {},
      [42],
      true,
    ]) {
      expect(parseIssueNumber(bad)).toBeNull();
    }
  });

  it("isValidMachineName", () => {
    expect(isValidMachineName("local")).toBe(true);
    expect(isValidMachineName("dev-box_01.lan")).toBe(true);
    expect(isValidMachineName("a".repeat(64))).toBe(true);
    expect(isValidMachineName("a".repeat(65))).toBe(false);
    for (const bad of MALICIOUS) expect(isValidMachineName(bad)).toBe(false);
  });

  it("isValidRepo", () => {
    expect(isValidRepo("sethford/shipwright")).toBe(true);
    expect(isValidRepo("my-org/.github")).toBe(true);
    for (const bad of [
      ...MALICIOUS,
      "owner",
      "a/b/c",
      "--repo/x",
      "o/-R",
      "../..",
      "./x",
      "o/r; id",
    ])
      expect(isValidRepo(bad)).toBe(false);
  });
});

describe("POST /api/claim handler", () => {
  const bodies = (field: "issue" | "machine" | "repo", v: unknown) => {
    const base: Record<string, unknown> = {
      issue: 100,
      machine: "local",
      repo: "owner/repo",
    };
    base[field] = v;
    return base;
  };

  for (const field of ["machine", "repo"] as const) {
    for (const payload of MALICIOUS) {
      if (field === "repo" && payload === "") continue; // empty repo is allowed
      it(`rejects malicious ${field}=${JSON.stringify(payload)} with 400 and no subprocess`, () => {
        const { run, calls } = makeRunner();
        const res = handleClaim(bodies(field, payload), run);
        expect(res.status).toBe(400);
        // no approved:false — the daemon must fall back, not treat it as "claimed"
        expect(res.body).not.toHaveProperty("approved");
        expect(calls).toHaveLength(0);
      });
    }
  }

  for (const payload of [
    "100; touch /tmp/pwned",
    "$(id)",
    "`id`",
    '1" --add-label "x',
    -5,
    0,
    1.5,
    null,
    undefined,
  ]) {
    it(`rejects malicious issue=${JSON.stringify(payload)} with 400 and no subprocess`, () => {
      const { run, calls } = makeRunner();
      const res = handleClaim(bodies("issue", payload), run);
      expect(res.status).toBe(400);
      expect(calls).toHaveLength(0);
    });
  }

  it("rejects machine_name alias with injection", () => {
    const { run, calls } = makeRunner();
    const res = handleClaim({ issue: 1, machine_name: "$(id)" }, run);
    expect(res.status).toBe(400);
    expect(calls).toHaveLength(0);
  });

  it("rejects non-object bodies", () => {
    for (const b of [null, "x", 5, [1, 2]]) {
      const { run, calls } = makeRunner();
      expect(handleClaim(b, run).status).toBe(400);
      expect(calls).toHaveLength(0);
    }
  });

  it("valid claim (with repo) produces the same argv as the old shell commands", () => {
    // responses: view(no labels), label create, edit add, verify view
    const { run, calls } = makeRunner(["", "", "", "claimed:local\nbug\n"]);
    const res = handleClaim(
      { issue: 100, machine: "local", repo: "owner/repo" },
      run,
    );
    expect(res).toEqual({
      status: 200,
      body: { approved: true, claimed_by: "local" },
    });
    const repoFlag = " -R owner/repo";
    const old = [
      `gh issue view 100${repoFlag} --json labels -q '.labels[].name'`,
      `gh label create "claimed:local"${repoFlag} --color EDEDED --description "Claimed by local" --force`,
      `gh issue edit 100${repoFlag} --add-label "claimed:local"`,
      `gh issue view 100${repoFlag} --json labels -q '.labels[].name'`,
    ].map(shellSplit);
    expect(calls.map((c) => [c.file, ...c.args])).toEqual(old);
  });

  it("valid claim (no repo) omits -R, and string issue is accepted", () => {
    const { run, calls } = makeRunner(["", "", "", "claimed:dev-1"]);
    const res = handleClaim({ issue: "7", machine_name: "dev-1" }, run);
    expect(res.status).toBe(200);
    expect(res.body.approved).toBe(true);
    expect(calls.map((c) => [c.file, ...c.args])).toEqual(
      [
        `gh issue view 7 --json labels -q '.labels[].name'`,
        `gh label create "claimed:dev-1" --color EDEDED --description "Claimed by dev-1" --force`,
        `gh issue edit 7 --add-label "claimed:dev-1"`,
        `gh issue view 7 --json labels -q '.labels[].name'`,
      ].map(shellSplit),
    );
  });

  it("already-claimed issue returns approved:false without editing", () => {
    const { run, calls } = makeRunner(["claimed:other\n"]);
    const res = handleClaim({ issue: 5, machine: "local" }, run);
    expect(res).toEqual({
      status: 200,
      body: { approved: false, claimed_by: "other" },
    });
    expect(calls).toHaveLength(1);
  });

  it("lost race removes our label (same argv as before)", () => {
    const { run, calls } = makeRunner([
      "",
      "",
      "",
      "claimed:local\nclaimed:other",
      "",
    ]);
    const res = handleClaim({ issue: 9, machine: "local" }, run);
    expect(res.body).toMatchObject({ approved: false, error: "Claim race lost" });
    expect([calls[4].file, ...calls[4].args]).toEqual(
      shellSplit(`gh issue edit 9 --remove-label "claimed:local"`),
    );
  });

  it("failed add-label returns 500", () => {
    const { run } = makeRunner(["", "", new Error("boom")]);
    const res = handleClaim({ issue: 9, machine: "local" }, run);
    expect(res.status).toBe(500);
    expect(res.body.error).toBe("Failed to set label");
  });

  it("gh is always invoked as a file + argv (never through a shell)", () => {
    const { run, calls } = makeRunner(["", "", "", "claimed:local"]);
    handleClaim({ issue: 1, machine: "local" }, run);
    for (const c of calls) expect(c.file).toBe("gh");
  });
});

describe("POST /api/claim/release handler", () => {
  for (const payload of MALICIOUS.filter((p) => p !== "")) {
    it(`rejects malicious machine=${JSON.stringify(payload)}`, () => {
      const { run, calls } = makeRunner();
      const res = handleClaimRelease({ issue: 1, machine: payload }, run);
      expect(res.status).toBe(400);
      expect(res.body.ok).toBe(false);
      expect(calls).toHaveLength(0);
    });
    it(`rejects malicious repo=${JSON.stringify(payload)}`, () => {
      const { run, calls } = makeRunner();
      const res = handleClaimRelease(
        { issue: 1, machine: "local", repo: payload },
        run,
      );
      expect(res.status).toBe(400);
      expect(calls).toHaveLength(0);
    });
  }

  it("rejects malicious issue", () => {
    const { run, calls } = makeRunner();
    expect(handleClaimRelease({ issue: "1;id", machine: "x" }, run).status).toBe(
      400,
    );
    expect(calls).toHaveLength(0);
  });

  it("with machine: same argv as before", () => {
    const { run, calls } = makeRunner([""]);
    const res = handleClaimRelease(
      { issue: 100, machine: "local", repo: "o/r" },
      run,
    );
    expect(res).toEqual({ status: 200, body: { ok: true } });
    expect(calls.map((c) => [c.file, ...c.args])).toEqual([
      shellSplit(`gh issue edit 100 -R o/r --remove-label "claimed:local"`),
    ]);
  });

  it("without machine: looks up the claimed label, then removes it", () => {
    const { run, calls } = makeRunner(["bug\nclaimed:box-2\n", ""]);
    const res = handleClaimRelease({ issue: 3 }, run);
    expect(res.status).toBe(200);
    expect(calls.map((c) => [c.file, ...c.args])).toEqual(
      [
        `gh issue view 3 --json labels -q '.labels[].name'`,
        `gh issue edit 3 --remove-label "claimed:box-2"`,
      ].map(shellSplit),
    );
  });

  it("a hostile label name read back from GitHub stays a single argv element", () => {
    const evil = 'claimed:x"; touch /tmp/pwned; echo "';
    const { run, calls } = makeRunner([evil, ""]);
    handleClaimRelease({ issue: 3 }, run);
    expect(calls[1].args).toEqual(["issue", "edit", "3", "--remove-label", evil]);
  });
});

describe("stale-claim reaper", () => {
  it("skips invalid machine names without running anything", () => {
    for (const bad of MALICIOUS) {
      const { run, calls } = makeRunner();
      expect(releaseStaleClaims(bad, run)).toEqual([]);
      expect(calls).toHaveLength(0);
    }
  });

  it("valid name: same argv as before; ignores non-numeric issue lines", () => {
    const { run, calls } = makeRunner(["12\n$(id)\n34\n", "", ""]);
    expect(releaseStaleClaims("box-1", run)).toEqual([12, 34]);
    expect(calls.map((c) => [c.file, ...c.args])).toEqual(
      [
        `gh issue list --label "claimed:box-1" --state open --json number -q '.[].number'`,
        `gh issue edit 12 --remove-label "claimed:box-1"`,
        `gh issue edit 34 --remove-label "claimed:box-1"`,
      ].map(shellSplit),
    );
  });
});

describe("subprocess guards", () => {
  it("validateMachineFields rejects shell metacharacters", () => {
    expect(
      validateMachineFields({ host: "10.0.0.5", ssh_user: "deploy", max_workers: 4 }),
    ).toBeNull();
    expect(validateMachineFields({ shipwright_path: "~/bin/shipwright" })).toBeNull();
    expect(validateMachineFields({ ssh_user: undefined, max_workers: null })).toBeNull();
    expect(validateMachineFields({ host: "h; id" })).toMatch(/host/);
    expect(validateMachineFields({ host: "-oProxyCommand=id" })).toMatch(/host/);
    expect(validateMachineFields({ ssh_user: "$(id)" })).toMatch(/ssh_user/);
    expect(validateMachineFields({ ssh_user: "-oProxyCommand=id" })).toMatch(
      /ssh_user/,
    );
    expect(validateMachineFields({ shipwright_path: 'sw"; id; "' })).toMatch(
      /shipwright_path/,
    );
    expect(validateMachineFields({ shipwright_path: "sw ps" })).toMatch(
      /shipwright_path/,
    );
    expect(validateMachineFields({ max_workers: "4; id" })).toMatch(/max_workers/);
  });

  it("sshArgv matches the old ssh command words", () => {
    expect(["ssh", ...sshArgv("u", "h", "shipwright daemon scale 4")]).toEqual(
      shellSplit(`ssh -o ConnectTimeout=5 u@h "shipwright daemon scale 4"`),
    );
  });

  it("signalPid refuses non-positive / non-integer / group pids", () => {
    const kill = vi.spyOn(process, "kill").mockImplementation(() => true);
    try {
      for (const bad of [0, 1, -1, -1234, 1.5, "123", "1; id", null, NaN]) {
        expect(isSignalablePid(bad)).toBe(false);
        expect(() => signalPid(bad, "SIGSTOP")).toThrow();
      }
      expect(kill).not.toHaveBeenCalled();
      signalPid(4242, "SIGCONT");
      expect(kill).toHaveBeenCalledWith(4242, "SIGCONT");
    } finally {
      kill.mockRestore();
    }
  });
});

describe("server.ts regression guard", () => {
  it("has no shell-string exec with ${} interpolation and no Bun.$", () => {
    const src = readFileSync(join(__dirname, "..", "server.ts"), "utf-8");
    // template-literal interpolation: exec(`... ${x}`)
    const templ = src.match(/\bexec(?:Sync)?\(\s*`[^`]*\$\{/g) || [];
    // string concatenation: exec("kill " + pid)
    const concat =
      src.match(/\bexec(?:Sync)?\(\s*(?:"[^"]*"|'[^']*'|`[^`]*`)\s*\+/g) || [];
    // non-literal first argument: exec(cmd)
    const dynamic = src.match(/\bexec(?:Sync)?\(\s*[A-Za-z_$][\w$.]*\s*[,)]/g) || [];
    expect([...templ, ...concat, ...dynamic]).toEqual([]);
    expect(src).not.toMatch(/Bun\.\$/);
  });
});

beforeEach(() => {
  vi.clearAllMocks();
});
