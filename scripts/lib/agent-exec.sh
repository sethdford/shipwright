#!/usr/bin/env bash
# lib/agent-exec.sh — run an agent CLI (claude) without GitHub credentials (#8614, #8580, F9).
#
# An agent runs tools in the working tree with the pipeline's environment. A GitHub token there
# would let it write to GitHub directly, and GitHub writes belong to the pipeline. So the agent gets
# none: GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN and the fleet token are
# removed, gh is pointed at a missing config dir, and git's saved credentials are reset (globally
# and per configured remote URL, as the test gate does). The Claude login (CLAUDE_CODE_OAUTH_TOKEN,
# ANTHROPIC_API_KEY) is kept, because the agent needs it. The test gate's own marker is not set.
#
#   "$SW_AGENT_EXEC" claude -p "$prompt"
#   "$SW_AGENT_EXEC" $TIMEOUT_CMD "$secs" claude -p "$prompt"
#
# It is a script, not a shell function, and it execs the command: the process the caller starts
# (and signals, e.g. loop-iteration's CHILD_PID) is the agent itself. Fails closed: if the reset
# cannot complete, the command does not run.
#
# Not covered (#8616): the Claude login itself (kept on purpose; on macOS it lives in the keychain),
# and ~/.netrc, which curl reads from $HOME with no environment variable to redirect it. A tool
# that stores a GitHub login in its own config file is not covered either.

# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"

if [[ $# -eq 0 ]]; then
    echo "usage: agent-exec.sh <command> [args...]" >&2
    exit 2
fi
if ! _sw_scrub_github_creds; then
    echo "agent-exec: could not remove GitHub credentials; not running $1" >&2
    exit 1
fi
exec "$@"
