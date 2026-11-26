#!/usr/bin/env bash
# repo-model.sh — the repository world model for agent prompts and tools (ADR-0012).
# The TypeScript command `shipwright repomodel` does the work; this file calls it, adds its brief to prompts and
# attaches its read-only MCP server ("repomodel") to claude calls, so agents query a persistent, incrementally
# updated model (definitions, references, imports, tests, owners) instead of grepping fresh on every run.
# Ablation for paired eval runs: SHIPWRIGHT_REPO_MODEL=off gives no brief and no MCP server, and the plan stage
# keeps the older grep-based architecture context. Every brief and attach records the arm in an event.
# Advice, not a gate: when the model cannot be built, the run goes on without it and an event says so.
[[ -n "${_REPO_MODEL_LOADED:-}" ]] && return 0
_REPO_MODEL_LOADED=1

_REPO_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_repo_model_event() {
    if type emit_event >/dev/null 2>&1; then emit_event "$@" 2>/dev/null || true; fi
    return 0
}

# The same switch values the TypeScript command reads: off, 0, false or no, in any case.
repo_model_enabled() {
    case "$(printf '%s' "${SHIPWRIGHT_REPO_MODEL:-on}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        off|0|false|no) return 1 ;;
    esac
    return 0
}

repo_model_arm() {
    if repo_model_enabled; then echo "on"; else echo "off"; fi
}

_repo_model_cli_path() {
    printf '%s\n' "${SW_TS_CLI:-$(cd "${_REPO_MODEL_DIR}/../.." && pwd)/src/cli.ts}"
}

_repo_model_bun() {
    local bun_bin="${SW_BUN:-bun}"
    command -v "$bun_bin" 2>/dev/null
}

# The repository the agent works in, as an absolute path.
_repo_model_root() {
    local root="${PROJECT_ROOT:-}"
    [[ -n "$root" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    (cd "$root" 2>/dev/null && pwd -P)
}

_repo_model_cli() {
    local bun_bin
    bun_bin="$(_repo_model_bun)" || return 1
    "$bun_bin" "$(_repo_model_cli_path)" repomodel "$@"
}

# repo_model_brief_section <task-text> [--with-tools] — the prompt section for a task, or nothing.
repo_model_brief_section() {
    local task="${1:-}" tools="${2:-}" root tmp out files
    repo_model_enabled || { _repo_model_event "repo_model.brief" "arm=off"; return 0; }
    root="$(_repo_model_root)" || return 0
    tmp="$(mktemp "${TMPDIR:-/tmp}/sw-repo-model-task.XXXXXX")" || return 0
    printf '%s\n' "$task" > "$tmp"
    local args=(brief --root "$root" --task "$tmp" --json)
    [[ "$tools" == "--with-tools" ]] && args+=(--with-tools)
    if out="$(_repo_model_cli "${args[@]}" 2>/dev/null)"; then
        files="$(printf '%s' "$out" | jq -r '[.files[]] | join(",")' 2>/dev/null || true)"
        _repo_model_event "repo_model.brief" "arm=on" "files=${files}" \
            "extracted=$(printf '%s' "$out" | jq -r '.stats.extracted // 0' 2>/dev/null || echo 0)"
        printf '%s' "$out" | jq -r '.brief // ""' 2>/dev/null || true
    else
        _repo_model_event "repo_model.brief_unavailable" "arm=on" "reason=command_failed"
    fi
    rm -f "$tmp"
    return 0
}

# _repo_model_server_cli — the absolute path of the CLI the MCP server would run, or exit 1 when no server can be
# attached: the model is off, Bun is missing, or the CLI lives inside the agent's working tree. An MCP server runs
# outside the agent's sandbox, so code the agent can edit must never be started that way (when shipwright works on
# its own repository, the brief is still given but no server is attached).
_repo_model_server_cli() {
    local root cli
    repo_model_enabled || return 1
    root="$(_repo_model_root)" || return 1
    _repo_model_bun >/dev/null || return 1
    cli="$(_repo_model_cli_path)"
    [[ -f "$cli" ]] || return 1
    cli="$(cd "$(dirname "$cli")" && pwd -P)/$(basename "$cli")"
    case "$cli" in
        "$root"/*) return 1 ;;
    esac
    printf '%s\n' "$cli"
}

# repo_model_tools_available — exit 0 when claude calls get the repomodel MCP server.
repo_model_tools_available() {
    _repo_model_server_cli >/dev/null
}

# repo_model_mcp_config — writes the MCP config that starts the read-only `repomodel` server for this repository
# and prints its path; prints nothing (exit 1) when no server can be attached.
repo_model_mcp_config() {
    local root bun_bin cli dir file tmp
    cli="$(_repo_model_server_cli)" || return 1
    root="$(_repo_model_root)" || return 1
    bun_bin="$(_repo_model_bun)" || return 1
    dir="${REPO_MODEL_MCP_DIR:-${TMPDIR:-/tmp}}"
    dir="${dir%/}"
    # One file per pipeline process, rewritten in place each call (temp file + mv), so iterations do not pile up.
    file="${dir}/sw-repo-model-mcp.$$.json"
    tmp="$(mktemp "${dir}/sw-repo-model-mcp.XXXXXX")" || return 1
    if ! jq -n --arg bun "$bun_bin" --arg cli "$cli" --arg root "$root" \
        '{mcpServers: {repomodel: {type: "stdio", command: $bun, args: [$cli, "repomodel", "mcp", "--root", $root]}}}' \
        > "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
    printf '%s\n' "$file"
}

# repo_model_mcp_flags — `--mcp-config <file>` for a claude call, or nothing. Builds the model first so the
# server's first answer is fast, and records the arm.
repo_model_mcp_flags() {
    local cfg
    if ! cfg="$(repo_model_mcp_config)"; then
        repo_model_enabled && _repo_model_event "repo_model.mcp_skipped" "arm=on"
        return 0
    fi
    _repo_model_cli build --root "$(_repo_model_root)" >/dev/null 2>&1 || true
    _repo_model_event "repo_model.mcp_attached" "arm=on"
    printf -- '--mcp-config %s\n' "$cfg"
}
