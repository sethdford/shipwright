/**
 * The agent permission policy for the SDK runner (#8614, #8581). config/agent-permissions.json is the
 * source of truth: the bash path loads it (scripts/lib/agent-exec.sh). These constants mirror its
 * `permissions` block, and agent-permissions.test.ts fails when the two drift.
 *
 * `permissionMode: "dontAsk"` denies, without a prompt, every call the allow list does not cover. A deny
 * rule wins over any allow rule in every settings scope, so the deny list holds even when a repo or a user
 * file allows more. The runner passes `settingSources: ["user"]`, so the repo's .claude/settings*.json (which
 * the agent can write) is never read. Verdict on #8581: permissionMode is set by the SDK option, and project
 * settings can change it only to a value that is not bypassPermissions/auto (those are ignored from project
 * files since v2.1.257), but project allow rules can widen the allow list, so the runner excludes project.
 */
export const AGENT_PERMISSION_MODE = "dontAsk";

/** settingSources the agent loads: the user's own settings, never the repo's (agent-writable). */
export const AGENT_SETTING_SOURCES = ["user"] as const;

/** Tools and commands an agent may use without a prompt. Anything else is denied in dontAsk. */
export const AGENT_ALLOWED_TOOLS: readonly string[] = [
  "Read",
  "Glob",
  "Grep",
  "Edit",
  "Write",
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

/** Denied for every agent: network and remote git, privilege escalation, and config the agent must not write. */
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
  "Read(~/.config/gh/**)",
  "Read(~/.netrc)",
  "Read(~/.aws/**)",
  "Read(~/.gnupg/**)",
  "Read(~/Library/Keychains/**)",
  "Edit(.claude/settings*.json)",
  "Write(.claude/settings*.json)",
  "Edit(.github/workflows/**)",
  "Write(.github/workflows/**)",
  "Edit(tools/arch/**)",
  "Write(tools/arch/**)",
];
