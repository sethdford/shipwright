import type { Options } from "@anthropic-ai/claude-agent-sdk";

/**
 * The agent permission policy for the SDK runner (#8614, #8581). config/agent-permissions.json is the
 * source of truth: the bash path loads it (scripts/lib/agent-exec.sh). These constants mirror it, and
 * agent-permissions.test.ts fails when the two drift.
 *
 * What the SDK runner sends (the same policy the bash path sends):
 *   - `settings`: an inline object with disableAllHooks and the permissions block. The SDK puts it in
 *     the flag layer, above user settings, so user hooks never run for an agent and a user allow cannot
 *     beat a policy deny.
 *   - `sandbox`: the Bash sandbox, with failIfUnavailable (the SDK default, set explicitly here).
 *   - `permissionMode: "dontAsk"`, `settingSources: ["user"]`: no repo settings (agent-writable).
 *
 * Verdict on #8581: the project scope is not loaded, so a repo's .claude/settings*.json cannot widen
 * the policy. The SDK's permissionMode option is a flag, and project files cannot set bypass or auto.
 */
type SdkSettings = Exclude<Options["settings"], string | undefined>;
type SdkSandbox = NonNullable<Options["sandbox"]>;

export const AGENT_PERMISSION_MODE = "dontAsk";

/** settingSources the agent loads: the user's own settings, never the repo's (agent-writable). */
export const AGENT_SETTING_SOURCES = ["user"] as const;

/** Tools and commands an agent may use without a prompt. Anything else is denied in dontAsk. */
export const AGENT_ALLOWED_TOOLS: readonly string[] = [
  "Read",
  "Glob",
  "Grep",
  "Edit(./**)",
  "Write(./**)",
  "Bash(git status)",
  "Bash(git status *)",
  "Bash(git diff)",
  "Bash(git diff *)",
  "Bash(git log *)",
  "Bash(git show *)",
  "Bash(git rev-parse *)",
  "Bash(git ls-files *)",
  "Bash(git add *)",
  "Bash(git commit *)",
  "Bash(git mv *)",
  "Bash(git rm *)",
  "Bash(git restore *)",
  "Bash(mkdir *)",
  "Bash(chmod +x *)",
  "Bash(shellcheck *)",
  "Bash(jq *)",
  "Bash(bash scripts/*-test.sh)",
  "Bash(bash scripts/*-test.sh *)",
  "Bash(bun test)",
  "Bash(bun test *)",
  "Bash(bun run *)",
  "Bash(npm test)",
  "Bash(npm test *)",
  "Bash(npm run *)",
  "Bash(pytest)",
  "Bash(pytest *)",
  "Bash(go test *)",
  "Bash(cargo test)",
  "Bash(cargo test *)",
  "Bash(make test)",
  "Bash(make test *)",
];

/** Denied for every agent: network and remote git, privilege escalation, secrets, and the policy itself. */
export const AGENT_DENIED_TOOLS: readonly string[] = [
  "Bash(curl *)",
  "Bash(wget *)",
  "Bash(gh *)",
  "Bash(ssh *)",
  "Bash(scp *)",
  "Bash(sftp *)",
  "Bash(nc *)",
  "Bash(ncat *)",
  "Bash(telnet *)",
  "Bash(sudo *)",
  "Bash(doas *)",
  "Bash(git push *)",
  "Bash(git fetch *)",
  "Bash(git pull *)",
  "Bash(git remote *)",
  "Bash(git config *)",
  "Bash(git clone *)",
  "Bash(git submodule *)",
  "Bash(git credential *)",
  "Bash(git -c *)",
  "Bash(rm -rf /*)",
  "Bash(rm -rf ~*)",
  "Bash(rm -rf $HOME*)",
  "Bash(rm -fr /*)",
  "Bash(rm -fr ~*)",
  "Read(~/.ssh/**)",
  "Edit(~/.ssh/**)",
  "Write(~/.ssh/**)",
  "Read(~/.config/**)",
  "Edit(~/.config/**)",
  "Write(~/.config/**)",
  "Read(~/.aws/**)",
  "Read(~/.netrc)",
  "Read(~/.gnupg/**)",
  "Read(~/Library/Keychains/**)",
  "Edit(//home/runner/work/_temp/**)",
  "Write(//home/runner/work/_temp/**)",
  "Edit(.claude/settings*.json)",
  "Write(.claude/settings*.json)",
  "Edit(config/agent-permissions.json)",
  "Write(config/agent-permissions.json)",
  "Edit(scripts/lib/agent-exec.sh)",
  "Write(scripts/lib/agent-exec.sh)",
  "Edit(scripts/lib/agent-sandbox.sh)",
  "Write(scripts/lib/agent-sandbox.sh)",
  "Edit(scripts/ci/**)",
  "Write(scripts/ci/**)",
  "Edit(config/models.json)",
  "Write(config/models.json)",
  "Edit(tools/models/**)",
  "Write(tools/models/**)",
  "Edit(scripts/lib/test-gate-env.sh)",
  "Write(scripts/lib/test-gate-env.sh)",
  "Edit(.github/**)",
  "Write(.github/**)",
  "Edit(tools/arch/**)",
  "Write(tools/arch/**)",
];

/** The Bash sandbox: no network domains, fail closed when the sandbox cannot start (mirrors the JSON). */
export const AGENT_SANDBOX: SdkSandbox = {
  enabled: true,
  failIfUnavailable: true,
  allowUnsandboxedCommands: false,
  autoAllowBashIfSandboxed: false,
  network: { allowedDomains: [] },
  filesystem: {
    denyRead: ["~/.ssh", "~/.config/gh", "~/.netrc", "~/.aws", "~/.gnupg", "~/Library/Keychains"],
  },
};

/** The inline settings the runner sends: hooks off, and the permissions block. */
export const AGENT_SETTINGS: SdkSettings = {
  disableAllHooks: true,
  permissions: {
    defaultMode: "dontAsk",
    blockReadsOutsideWorkingDirectories: true,
    allow: [...AGENT_ALLOWED_TOOLS],
    deny: [...AGENT_DENIED_TOOLS],
  },
};

/**
 * Scopes bare file-tool allows to the working tree: a caller's `Edit` or `Write` would match any path,
 * so it becomes `Edit(./**)` or `Write(./**)`. Other entries pass through unchanged.
 */
export function scopeAllowedTools(tools: readonly string[]): string[] {
  return tools.map((t) => (t === "Edit" ? "Edit(./**)" : t === "Write" ? "Write(./**)" : t));
}
