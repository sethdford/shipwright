#!/usr/bin/env bash
# scripts/ci/git-token-credential.sh — git credential helper for the pipeline's own git network
# operations (#8624). The pipeline job's checkout does not persist a token (persist-credentials:
# false), so no git config carries one. Instead git asks this helper, which answers github.com from
# GITHUB_TOKEN (or GH_TOKEN), for that one operation. Agents never see it: agent-exec.sh builds their
# environment from an allowlist and drops GITHUB_TOKEN, GH_TOKEN and this helper's configuration.
#
#   GIT_CONFIG_COUNT=1
#   GIT_CONFIG_KEY_0=credential.helper
#   GIT_CONFIG_VALUE_0='!bash "$GITHUB_WORKSPACE/scripts/ci/git-token-credential.sh"'
#
# It answers only the `get` operation, only for host github.com, and only when a token is set. Any
# other request gets no answer, so git cannot send the token to another host.
set -euo pipefail

[[ "${1:-}" == "get" ]] || exit 0

host=""
while IFS= read -r line; do
    [[ -n "$line" ]] || break
    if [[ "$line" == host=* ]]; then
        host="${line#host=}"
    fi
done

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ "$host" == "github.com" && -n "$token" ]]; then
    printf 'username=x-access-token\npassword=%s\n' "$token"
fi
