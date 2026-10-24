#!/usr/bin/env bash
# CI: snapshot the agent permission policy to RUNNER_TEMP before any agent runs (#8614 review).
#
# The copy comes from the default branch (origin/main), not the checkout, so a pull request cannot widen
# the policy its own agent runs under. The copy is read-only and lives outside the agent's working tree,
# and SW_AGENT_POLICY points agent-exec at it (agent-exec refuses a policy inside the tree in CI).
#
# Fallback: until config/agent-permissions.json is on the default branch, the checkout's copy is used, with a
# warning. After the policy merges to main this fallback is never taken.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set (GitHub Actions)}"
: "${GITHUB_ENV:?GITHUB_ENV must be set (GitHub Actions)}"
dest="$RUNNER_TEMP/agent-permissions.json"

git fetch --no-tags --depth=1 origin main
if git cat-file -e "FETCH_HEAD:config/agent-permissions.json" 2>/dev/null; then
    git show "FETCH_HEAD:config/agent-permissions.json" > "$dest"
    echo "agent policy: snapshot from origin/main"
else
    echo "::warning::config/agent-permissions.json is not on origin/main yet; snapshotting the checkout's copy"
    cp config/agent-permissions.json "$dest"
fi
chmod 0444 "$dest"
echo "SW_AGENT_POLICY=$dest" >> "$GITHUB_ENV"
