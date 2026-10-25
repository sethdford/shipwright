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
# Permissions (#8614, #8581). Every claude call gets the one shared policy, config/agent-permissions.json,
# and the caller cannot widen it. For each claude argument this adds (after the claude word):
#   --settings <policy> --setting-sources user --permission-mode dontAsk   (and --permission-prompts none with -p)
# dontAsk denies, without a prompt, every call the policy does not allow; a deny rule wins over any allow rule
# in every settings scope. --setting-sources user keeps the repo's .claude/settings*.json (agent-writable) out.
# A caller that passes --permission-mode, --settings, --setting-sources, --permission-prompts, or --allowedTools
# (an allow list the policy does not own) is refused, and so is any bypass flag. A bypass flag is allowed only
# for an operator: SHIPWRIGHT_OPERATOR_SKIP_PERMISSIONS=1 set by sw-session --skip-permissions, stdin and stdout
# on a TTY, and no CI, test mode, pipeline or test gate. An agent or a daemon has no TTY and cannot set it.
#
# Also added: --append-system-prompt with the project memory (CLAUDE.md, AGENTS.md, .claude/rules/*.md, read
# from the working directory), since --setting-sources user skips the project scope; and the policy's
# disableAllHooks and blockReadsOutsideWorkingDirectories come from the policy file itself. The memory is capped at
# 64 KiB. A review or audit stage sets SW_MEMORY_REF to a base-branch ref, and the memory is read from that ref, so a
# builder's edits cannot steer it (#8673). Only claude is launched through this wrapper, as the command word (after an
# optional timeout prefix): any other command is refused.
#
# Where the policy comes from: SW_AGENT_POLICY (the pipeline sets it to a read-only copy in RUNNER_TEMP, taken
# from the default branch before any agent runs), else <repo>/config/agent-permissions.json. In CI a policy inside
# the agent's working tree is refused. An agent's own Bash cannot choose a policy: inside an agent run
# (SHIPWRIGHT_IN_TEST_GATE=1 and CLAUDE_AGENT_SDK_CLIENT_APP=shipwright, which agent-exec sets) SW_AGENT_POLICY is refused.
#
# Same-user limit (documented, not closed here): the agent runs as the pipeline's user. It can still write any file
# that user can write unless the Edit/Write deny rules and the sandbox stop it, and it can read and change this
# script and the snapshot in RUNNER_TEMP through Bash. The deny rules cover Edit/Write and the file commands the CLI
# recognizes (sed, tee, redirections), not every program. Closing it needs a separate user or a container.
#
# Proxy values may embed credentials (http://user:pass@proxy). Those are proxy credentials, not GitHub
# credentials, and the agent needs them to reach the API from behind a proxy; they are passed on purpose.
# The Bedrock secret keys are passed only when Bedrock is the selected provider.
#
# Git's saved credentials are reset too, the same way the test gate resets them (test-gate-env.sh):
# every http.*.extraheader and credential.*.helper the repo or user config saves (GHES and path-scoped
# headers included), the github.com-scoped credential.https://github.com.helper, and GIT_TERMINAL_PROMPT=0
# with gh pointed at a missing config dir. The launcher REFUSES to run the agent (exit 1, the message
# names the config scope and a redacted key, never a value) when the config carries credentials: in a
# remote URL or pushurl, in a url.<base>.insteadOf or pushInsteadOf (key or value), or in a saved header or
# helper key. For http(s) only (scheme in any case), default-deny: any userinfo, username alone included
# (https://user@host, percent-encoded @ included), is refused, because no token shape is trusted. The
# message says to remove the username (git uses the credential helper) or use an SSH remote, and never
# prints a value. ssh://, git:// and scp-style remotes are not refused. Keys cannot be reset
# without copying the credential into the environment.
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
#   - The runner's files for later steps. The agent runs as the same user and can write the GITHUB_ENV
#     and GITHUB_PATH files of the job; a value written there (BASH_ENV, PATH, any variable) reaches the
#     later steps that hold GITHUB_TOKEN. The agent env cannot stop that. Only the sandbox or a separate
#     user closes it.
#   - Tools that store a GitHub login in their own config files under $HOME.
#   - Repo config the agent can write (.git/config is in the working tree). The scrub resets
#     credential.helper (the list accumulates across scopes, so every helper is cleared), the
#     github.com-scoped credential.https://github.com.helper, and each saved http./credential. key. The
#     orchestrator's own git ops reset hooks and fsmonitor too (core.hooksPath=/dev/null,
#     core.fsmonitor=false, in the workflows). Still open, because they run code in the orchestrator's
#     git ops, which carry the token: filter.<name>.clean/smudge (run on add and checkout), diff.<name>.
#     external (run on diff), and alias.* (run as commands). The agent can set any of them; a later
#     orchestrator git op in the same repo runs them. Closing them needs isolation (separate user or
#     sandbox) or a clean clone for the orchestrator's git ops.
#   - credential.<url>.helper for any other host is reset by the saved-key list only when the key is
#     saved; the agent can add one under a new URL. The orchestrator's helper answers github.com only, so
#     a helper for another URL receives only the requests git sends to that URL.

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

# ─── Permission policy (#8614, #8581) ───────────────────────────────────────
# Where the policy comes from. In CI the workflow snapshots config/agent-permissions.json to $RUNNER_TEMP
# before any agent runs and sets SW_AGENT_POLICY to that copy. A policy inside the agent's working tree
# is refused in CI: the agent can write there.
_sw_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_sw_agent_policy="${SW_AGENT_POLICY:-$_sw_repo_root/config/agent-permissions.json}"
# Inside an agent run (agent-exec sets these in every agent's environment). A nested agent may not choose
# its own policy.
_sw_inside_agent=false
if [[ "${SHIPWRIGHT_IN_TEST_GATE:-}" == "1" && "${CLAUDE_AGENT_SDK_CLIENT_APP:-}" == "shipwright" ]]; then
    _sw_inside_agent=true
fi

_sw_is_bypass_flag() {
    # A flag (starts with --) that names a permission bypass. A glob, so this file spells no bypass
    # flag and the F9 bash rule has nothing to flag here. Broader than the rule on purpose.
    case "$1" in
        --*[Dd]angerously*|--*[Bb]ypass*|--*[Ss]kip*[Pp]ermission*) return 0 ;;
    esac
    return 1
}
_sw_operator_bypass_ok() {
    [[ "${SHIPWRIGHT_OPERATOR_SKIP_PERMISSIONS:-}" == "1" && -t 0 && -t 1 ]] \
        && [[ -z "${CI:-}" && -z "${SHIPWRIGHT_TEST_MODE:-}" && -z "${SHIPWRIGHT_PIPELINE_ID:-}" && -z "${SHIPWRIGHT_IN_TEST_GATE:-}" ]]
}
# Absolute, symlink-resolved path of a file's directory plus its name.
_sw_abs_path() {
    local dir
    dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s\n' "$dir" "$(basename "$1")"
}
# The project memory the CLI would have loaded from the project scope (CLAUDE.md, AGENTS.md and
# .claude/rules/*.md). `--setting-sources user` skips the project scope, so the same text is passed through
# --append-system-prompt. Settings are NOT read from the project.
# Source: the working directory (the build stage edits that tree). When SW_MEMORY_REF is set, the files come
# from that git ref instead (#8673): review and audit stages read the base branch, so a builder cannot steer them.
_SW_MEMORY_CAP=65536
_sw_memory_files() {
    local f
    if [[ -n "${SW_MEMORY_REF:-}" ]]; then
        for f in CLAUDE.md AGENTS.md .claude/CLAUDE.md; do
            git cat-file -e "$SW_MEMORY_REF:$f" 2>/dev/null && printf '%s\n' "$f"
        done
        # Top level only, like the working-tree branch below and the TypeScript reader (#8673).
        git ls-tree -r --name-only "$SW_MEMORY_REF" -- .claude/rules | sed -n '/^\.claude\/rules\/[^/]*\.md$/p'
    else
        for f in CLAUDE.md AGENTS.md .claude/CLAUDE.md; do
            [[ -f "$f" ]] && printf '%s\n' "$f"
        done
        for f in .claude/rules/*.md; do
            [[ -f "$f" ]] && printf '%s\n' "$f"
        done
    fi
    return 0
}
_sw_read_memory_file() {
    if [[ -n "${SW_MEMORY_REF:-}" ]]; then
        git show "$SW_MEMORY_REF:$1" 2>/dev/null
    else
        cat "$1"
    fi
}
# Fails closed: a memory file that cannot be read makes the launcher refuse to run, never a silent partial memory.
_sw_project_memory() {
    local out="" f body
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        body="$(_sw_read_memory_file "$f")" || {
            echo "agent-exec: cannot read project memory $f; not running" >&2
            return 1
        }
        out+=$'\n\n'"# $f"$'\n\n'"$body"
    done < <(_sw_memory_files)
    printf '%s' "$out"
}
# At most 64 KiB of project memory. A longer argument would hit the kernel's 128 KiB per-argument limit (E2BIG),
# so the text is cut at the cap and a marker says so. Shorter text is returned unchanged.
_sw_cap_memory() {
    local text="$1" bytes marker
    bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
    if [[ "$bytes" -le "$_SW_MEMORY_CAP" ]]; then
        printf '%s' "$text"
        return 0
    fi
    marker=$'\n\n[project memory truncated at 64 KiB by agent-exec (#8673); the rest was not passed]'
    # iconv -c drops the partial multi-byte character a byte cut can leave at the end.
    printf '%s' "$text" | LC_ALL=C head -c "$((_SW_MEMORY_CAP - ${#marker}))" | iconv -c -f UTF-8 -t UTF-8
    printf '%s' "$marker"
}

_sw_has_print=false
_sw_has_bypass=false
for _sw_arg in "$@"; do
    case "$_sw_arg" in
        -p|--print) _sw_has_print=true ;;
    esac
    case "$_sw_arg" in
        --permission-mode|--permission-mode=*|--settings|--settings=*|--setting-sources|--setting-sources=*|\
--permission-prompts|--permission-prompts=*|--allowedTools|--allowedTools=*|--allowed-tools|--allowed-tools=*)
            echo "agent-exec: refusing $_sw_arg; the permission policy is set here (config/agent-permissions.json)" >&2
            exit 1 ;;
    esac
    if _sw_is_bypass_flag "$_sw_arg"; then _sw_has_bypass=true; fi
done

# Only claude is launched through this wrapper, and claude must be the command itself: the first word, after an
# optional `timeout N` or `gtimeout N` prefix. A claude word later in argv does not count, so
# `/bin/echo NOT-CLAUDE claude` is refused (#8673). Anything else would run outside the policy.
_sw_cmd_idx=0
_sw_duration_re='^[0-9]+(\.[0-9]+)?[smhd]?$'
if [[ "${1:-}" == timeout || "${1:-}" == gtimeout ]]; then
    if [[ "${2:-}" =~ $_sw_duration_re ]]; then _sw_cmd_idx=2; else _sw_cmd_idx=-1; fi
fi
_sw_cmd=""
_sw_i=0
for _sw_arg in "$@"; do
    if [[ "$_sw_i" -eq "$_sw_cmd_idx" ]]; then _sw_cmd="$_sw_arg"; break; fi
    _sw_i=$((_sw_i + 1))
done
if [[ "$_sw_cmd_idx" -lt 0 || -z "$_sw_cmd" || "${_sw_cmd##*/}" != claude ]]; then
    echo "agent-exec: refusing to run ${1:-nothing}: only claude is launched through this wrapper, as the command (F9)" >&2
    exit 1
fi

if [[ -n "${SW_AGENT_POLICY:-}" && "$_sw_inside_agent" == true ]]; then
    echo "agent-exec: refusing SW_AGENT_POLICY inside an agent run; the policy is set by the pipeline" >&2
    exit 1
fi
if [[ -n "${SW_MEMORY_REF:-}" ]]; then
    if [[ "$_sw_inside_agent" == true ]]; then
        echo "agent-exec: refusing SW_MEMORY_REF inside an agent run; the project memory is set by the pipeline" >&2
        exit 1
    fi
    # Pinned to a SHA once, so a later move of the ref (the agent can write .git) cannot change what is read.
    if ! _sw_memory_sha="$(git rev-parse --verify --quiet "$SW_MEMORY_REF^{commit}" 2>/dev/null)"; then
        echo "agent-exec: SW_MEMORY_REF does not name a commit; not running $_sw_cmd" >&2
        exit 1
    fi
    SW_MEMORY_REF="$_sw_memory_sha"
fi
if [[ "${CI:-}" != "" ]]; then
    _sw_policy_abs="$(_sw_abs_path "$_sw_agent_policy" 2>/dev/null || echo "$_sw_agent_policy")"
    _sw_cwd_abs="$(pwd -P)"
    case "$_sw_policy_abs" in
        "$_sw_cwd_abs"/*)
            echo "agent-exec: in CI the policy must not live in the agent's working tree ($_sw_policy_abs); the pipeline snapshots it to RUNNER_TEMP (#8614)" >&2
            exit 1 ;;
    esac
fi

_sw_argv=()
if [[ "$_sw_has_bypass" == true ]]; then
    if ! _sw_operator_bypass_ok; then
        echo "agent-exec: refusing a permission bypass flag; agents run under config/agent-permissions.json (F9)" >&2
        exit 1
    fi
    # The operator's own terminal session: the caller's flags pass through unchanged.
    _sw_argv=("$@")
else
    if [[ ! -f "$_sw_agent_policy" || ! -r "$_sw_agent_policy" ]]; then
        echo "agent-exec: permission policy missing or unreadable ($_sw_agent_policy); not running $1" >&2
        exit 1
    fi
    _sw_memory="$(_sw_project_memory)" || exit 1
    _sw_memory="$(_sw_cap_memory "$_sw_memory")"
    _sw_i=0
    for _sw_arg in "$@"; do
        _sw_argv+=("$_sw_arg")
        # Options go right after the claude command word, never after a later argument that happens to be "claude".
        if [[ "$_sw_i" -eq "$_sw_cmd_idx" ]]; then
            _sw_argv+=(--settings "$_sw_agent_policy" --setting-sources user --permission-mode dontAsk)
            if [[ "$_sw_has_print" == true ]]; then
                _sw_argv+=(--permission-prompts none)
            fi
            if [[ -n "$_sw_memory" ]]; then
                _sw_argv+=(--append-system-prompt "$_sw_memory")
            fi
        fi
        _sw_i=$((_sw_i + 1))
    done
fi

exec env -i ${_sw_agent_pairs[@]+"${_sw_agent_pairs[@]}"} ${_sw_argv[@]+"${_sw_argv[@]}"}
