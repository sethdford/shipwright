// Files from the package's .claude/ that npm postinstall installs into the user's ~/.claude.
// Dev-only files in .claude/ (Shipwright's own reviewer/verifier/porter subagents, the
// check:fast Stop hook, ...) must not be installed into users' ~/.claude: list only
// user-facing files here, never copy the directories wholesale.

/** User-facing agent definitions → ~/.claude/agents/ */
export const USER_AGENTS = Object.freeze(["doc-fleet-agent.md"]);

/** User-facing hook scripts → ~/.claude/hooks/ */
export const USER_HOOKS = Object.freeze([
  "agent-crash-capture.sh",
  "post-tool-use.sh",
  "pre-tool-use.sh",
  "session-started.sh",
]);
