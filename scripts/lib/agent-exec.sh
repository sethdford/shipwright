#!/usr/bin/env bash
# lib/agent-exec.sh — run an agent CLI (claude) without GitHub credentials (#8614, #8580, F9).
#
# An agent runs tools in the working tree. A GitHub token there would let it write to GitHub
# directly, and GitHub writes belong to the pipeline. So the agent's environment is built from an
# allowlist with `env -i`, not the caller's environment minus a blocklist. Anything not listed is
# dropped by construction (SSH_AUTH_SOCK, GIT_ASKPASS, GITHUB_PAT, GH_*/GITHUB_* tokens, FOO_TOKEN …).
# The Claude-side list mirrors ENV_ALLOWLIST in src/adapters/agent/agent-sdk-runner.ts (keep both in step).
#
#   PATH HOME USER LOGNAME SHELL TERM LANG LC_* TMPDIR TZ CI XDG_CONFIG_HOME   the process basics
#   CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR
#   ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL
#   CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX AWS_REGION AWS_PROFILE CLOUD_ML_REGION
#   ANTHROPIC_VERTEX_PROJECT_ID                                              the provider selectors
#   AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN   ONLY when CLAUDE_CODE_USE_BEDROCK=1
#   HTTPS_PROXY HTTP_PROXY NO_PROXY and lowercase forms                      proxies (see note below)
#   NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR                           CA bundles
#   SHIPWRIGHT_DIR SHIPWRIGHT_HOME SHIPWRIGHT_STATE_DIR SHIPWRIGHT_INTELLIGENCE_CACHE
#   SHIPWRIGHT_PIPELINE_ID SHIPWRIGHT_PIPELINE SHIPWRIGHT_REPO_PATH SHIPWRIGHT_REPO_DIR
#   SHIPWRIGHT_SCRIPTS SHIPWRIGHT_GITHUB_REPO SHIPWRIGHT_FORCE_COLOR        the run variables agents read
#   CLAUDE_AGENT_SDK_CLIENT_APP=shipwright, SHIPWRIGHT_IN_TEST_GATE=1  (real-service suites refuse)
#
# Proxy values may embed credentials (http://user:pass@proxy). Those are proxy credentials, not GitHub
# credentials, and the agent needs them to reach the API from behind a proxy; they are passed on purpose.
# The Bedrock secret keys are passed only when Bedrock is the selected provider.
#
# Git's saved credentials are reset too, the same way the test gate resets them (test-gate-env.sh):
# every http.*.extraheader and credential.*.helper the repo or user config saves (GHES and path-scoped
# headers included), the remote URLs (with their userinfo removed, so no token is copied into the
# agent's environment), and GIT_TERMINAL_PROMPT=0 with gh pointed at a missing config dir. A
# url.<base>.insteadOf whose base embeds a credential cannot be reset without repeating the credential
# in the environment, so the launcher refuses to run the agent while one is configured.
#
#   "$SW_AGENT_EXEC" claude -p "$prompt"
#   "$SW_AGENT_EXEC" $TIMEOUT_CMD "$secs" claude -p "$prompt"
#
# It is a script, not a shell function, and it execs the command: the process the caller starts
# (and signals, e.g. loop-iteration's CHILD_PID) is the agent itself. Fails closed: if the reset
# cannot complete, the command does not run.
#
# What this does NOT stop (real isolation is a separate user or a sandbox, not this script):
#   - Same user, same machine. The agent runs as the pipeline's own user, so it can read the files
#     that user can read (~/.netrc, ~/.gitconfig, ~/.config/gh, keychain items the user may unlock).
#     A GitHub login stored in any of those is reachable. Only a separate user or a sandbox changes
#     that: the sandbox and credentials work is in the Wave 1c plan (docs/superpowers/plans/
#     2026-10-14-wave-1a-safety.md, ADR-0006), the spec's §5 "Permissions and sandbox", and the M2/M3
#     one-container-per-run design. No open Wave 2 issue (#8589-#8607) covers it.
#   - Orchestrator scripts run from the agent-writable workspace. The pipeline runs `npm link` and then
#     the scripts in the checkout, which the agent can edit. Any such script that a later orchestrator
#     step runs (with GITHUB_TOKEN in its environment) can therefore carry the token out. Same class of
#     problem as above; it needs the same isolation (run the orchestrator from a copy the agent cannot
#     write, or a separate user). The credential helper in the pipeline workflow is inlined for this reason.
#   - On Linux, the agent runs as a child of the pipeline process, which holds the full environment
#     (GitHub tokens included). Same-user processes may read each other's environment, so the agent
#     can read /proc/$PPID/environ and get those tokens. The allowlist protects the agent's own
#     environment, not its parent's.
#   - The Claude login itself (kept on purpose; on macOS it lives in the keychain).
#   - Tools that store a GitHub login in their own config files under $HOME.

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

# Pairs of NAME=VALUE for env -i, built only from names listed here.
_sw_agent_pairs=()
_sw_agent_pass() {
    local name
    for name in "$@"; do
        if [[ -n "${!name+x}" ]]; then
            _sw_agent_pairs+=("$name=${!name}")
        fi
    done
}
_sw_agent_pass PATH HOME USER LOGNAME SHELL TERM LANG TMPDIR TZ CI XDG_CONFIG_HOME \
    CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR \
    ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX AWS_REGION AWS_PROFILE \
    CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID \
    HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy \
    NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR \
    SHIPWRIGHT_DIR SHIPWRIGHT_HOME SHIPWRIGHT_STATE_DIR SHIPWRIGHT_INTELLIGENCE_CACHE \
    SHIPWRIGHT_PIPELINE_ID SHIPWRIGHT_PIPELINE SHIPWRIGHT_REPO_PATH SHIPWRIGHT_REPO_DIR \
    SHIPWRIGHT_SCRIPTS SHIPWRIGHT_GITHUB_REPO SHIPWRIGHT_FORCE_COLOR
if [[ "${CLAUDE_CODE_USE_BEDROCK:-}" == "1" ]]; then
    _sw_agent_pass AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi
for _sw_name in $(compgen -e); do
    case "$_sw_name" in
        LC_*) _sw_agent_pass "$_sw_name" ;;
    esac
done
# The git and gh overrides written by the scrub above (GIT_CONFIG_COUNT entries only).
_sw_agent_pass GIT_TERMINAL_PROMPT GH_CONFIG_DIR
_sw_agent_i=0
while [[ "$_sw_agent_i" -lt "${GIT_CONFIG_COUNT:-0}" ]]; do
    _sw_agent_pass "GIT_CONFIG_KEY_$_sw_agent_i" "GIT_CONFIG_VALUE_$_sw_agent_i"
    _sw_agent_i=$((_sw_agent_i + 1))
done
_sw_agent_pairs+=("GIT_CONFIG_COUNT=${GIT_CONFIG_COUNT:-0}")
_sw_agent_pairs+=("CLAUDE_AGENT_SDK_CLIENT_APP=shipwright" "SHIPWRIGHT_IN_TEST_GATE=1")

exec env -i ${_sw_agent_pairs[@]+"${_sw_agent_pairs[@]}"} "$@"
