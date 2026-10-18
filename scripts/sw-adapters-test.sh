#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adapters test — Structural/smoke tests for terminal & deploy║
# ║  Tests: tmux, iterm2, wezterm, docker, fly, vercel, railway              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "sw-adapters Tests"

setup_test_env "sw-adapters-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# Adapter lists
TERMINAL_ADAPTERS=(tmux-adapter.sh iterm2-adapter.sh wezterm-adapter.sh)
DEPLOY_ADAPTERS=(docker-deploy.sh fly-deploy.sh vercel-deploy.sh railway-deploy.sh)
TERMINAL_FUNCS=(spawn_agent list_agents kill_agent focus_agent)
DEPLOY_FUNCS=(detect_platform get_staging_cmd get_production_cmd get_rollback_cmd get_health_url get_smoke_cmd)

# ═══════════════════════════════════════════════════════════════════════════════
# 1. All adapter files exist and are executable
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Adapter files exist and executable"

for adapter in "${TERMINAL_ADAPTERS[@]}" "${DEPLOY_ADAPTERS[@]}"; do
    fp="$ADAPTERS_DIR/$adapter"
    assert_file_exists "adapter exists: $adapter" "$fp"
    if [[ -f "$fp" ]] && [[ -x "$fp" ]]; then
        assert_pass "adapter executable: $adapter"
    else
        assert_fail "adapter executable: $adapter"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Each adapter can be sourced without errors (in subshell)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Adapters source cleanly in subshell"

# Deploy adapters source without env checks — test directly
for adapter in "${DEPLOY_ADAPTERS[@]}"; do
    fp="$ADAPTERS_DIR/$adapter"
    td=$(mktemp -d "$TEST_TEMP_DIR/source-${adapter%.sh}.XXXXXX")
    # shellcheck disable=SC1090
    (cd "$td" && source "$fp" 2>/dev/null) && assert_pass "$adapter sources in subshell" || assert_fail "$adapter sources in subshell"
done

# Terminal adapters need mocks (tmux/wezterm exit if binary missing; iterm2 exits if not Darwin)
mock_binary "tmux" 'case "${1:-}" in list-windows|list-panes) echo "" ;; new-window|split-window) echo "%0" ;; *) exit 0 ;; esac'
mock_binary "wezterm" 'echo "0"; exit 0'
mock_binary "osascript" 'echo ""; exit 0'

export WINDOW_NAME="shipwright-test-$$"
for adapter in tmux-adapter.sh wezterm-adapter.sh; do
    fp="$ADAPTERS_DIR/$adapter"
    # shellcheck disable=SC1090
    (source "$fp" 2>/dev/null) && assert_pass "$adapter sources in subshell" || assert_fail "$adapter sources in subshell"
done

if [[ "$(uname)" == "Darwin" ]]; then
    (source "$ADAPTERS_DIR/iterm2-adapter.sh" 2>/dev/null) && assert_pass "iterm2-adapter.sh sources in subshell" || assert_fail "iterm2-adapter.sh sources in subshell"
else
    assert_pass "iterm2 skip on non-macOS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Adapter functions exist after sourcing (type -t)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Terminal adapters define expected functions"

td=$(mktemp -d "$TEST_TEMP_DIR/tmux.XXXXXX")
cd "$td" || exit 1
source "$ADAPTERS_DIR/tmux-adapter.sh" 2>/dev/null || true
for fn in "${TERMINAL_FUNCS[@]}"; do
    if type -t "$fn" &>/dev/null && [[ "$(type -t "$fn")" == "function" ]]; then
        assert_pass "tmux defines $fn"
    else
        assert_fail "tmux defines $fn"
    fi
done
cd - >/dev/null || true

td=$(mktemp -d "$TEST_TEMP_DIR/wezterm.XXXXXX")
cd "$td" || exit 1
source "$ADAPTERS_DIR/wezterm-adapter.sh" 2>/dev/null || true
for fn in "${TERMINAL_FUNCS[@]}"; do
    if type -t "$fn" &>/dev/null && [[ "$(type -t "$fn")" == "function" ]]; then
        assert_pass "wezterm defines $fn"
    else
        assert_fail "wezterm defines $fn"
    fi
done
cd - >/dev/null || true

if [[ "$(uname)" == "Darwin" ]]; then
    source "$ADAPTERS_DIR/iterm2-adapter.sh" 2>/dev/null || true
    for fn in "${TERMINAL_FUNCS[@]}"; do
        if type -t "$fn" &>/dev/null && [[ "$(type -t "$fn")" == "function" ]]; then
            assert_pass "iterm2 defines $fn"
        else
            assert_fail "iterm2 defines $fn"
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. tmux adapter: key functions (pane creation helpers, safety checks)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "tmux adapter key functions"

td=$(mktemp -d "$TEST_TEMP_DIR/tmux-key.XXXXXX")
cd "$td" || exit 1
source "$ADAPTERS_DIR/tmux-adapter.sh" 2>/dev/null || true
# spawn_agent is the pane creation helper
if type -t spawn_agent &>/dev/null; then
    assert_pass "tmux has pane creation helper (spawn_agent)"
else
    assert_fail "tmux has pane creation helper (spawn_agent)"
fi
# Safety: uses pane IDs via _TMUX_PANE_MAP; kill_agent/focus_agent have fallbacks
if [[ -n "${_TMUX_PANE_MAP:-}" ]] && [[ "$_TMUX_PANE_MAP" == *"shipwright-tmux"* ]]; then
    assert_pass "tmux uses pane map for stable IDs"
else
    assert_fail "tmux uses pane map for stable IDs"
fi
cd - >/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Deploy adapters: expected functions and command output
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Deploy adapters export expected functions"

test_deploy_adapter() {
    local name="$1"
    local adapter_file="$2"
    local detect_file="$3"
    local pattern="$4"

    td=$(mktemp -d "$TEST_TEMP_DIR/deploy-${name}.XXXXXX")
    cd "$td" || exit 1
    [[ -n "$detect_file" ]] && touch "$detect_file" 2>/dev/null || true
    [[ "$detect_file" == "fly.toml" ]] && echo 'app = "test"' > fly.toml

    # shellcheck disable=SC1090
    source "$adapter_file" 2>/dev/null || true

    for fn in "${DEPLOY_FUNCS[@]}"; do
        if type -t "$fn" &>/dev/null && [[ "$(type -t "$fn")" == "function" ]]; then
            assert_pass "$name defines $fn"
        else
            assert_fail "$name defines $fn"
        fi
    done

    cmd=$(get_staging_cmd 2>/dev/null || echo "")
    assert_contains "$name get_staging_cmd contains $pattern" "$cmd" "$pattern"

    cmd=$(get_production_cmd 2>/dev/null || echo "")
    assert_gt "$name get_production_cmd non-empty" "${#cmd}" 0

    cmd=$(get_rollback_cmd 2>/dev/null || echo "")
    assert_gt "$name get_rollback_cmd non-empty" "${#cmd}" 0

    cd - >/dev/null || true
}

test_deploy_adapter "docker" "$ADAPTERS_DIR/docker-deploy.sh" "Dockerfile" "docker"
test_deploy_adapter "fly" "$ADAPTERS_DIR/fly-deploy.sh" "fly.toml" "fly"
test_deploy_adapter "vercel" "$ADAPTERS_DIR/vercel-deploy.sh" "vercel.json" "vercel"
test_deploy_adapter "railway" "$ADAPTERS_DIR/railway-deploy.sh" "railway.toml" "railway"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. No hardcoded paths in adapters
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "No hardcoded user paths in adapters"

found_bad=0
for adapter in "$ADAPTERS_DIR"/*.sh; do
    [[ -f "$adapter" ]] || continue
    if grep -qE '/Users/[a-zA-Z0-9]|/home/[a-zA-Z0-9]' "$adapter" 2>/dev/null; then
        assert_fail "$(basename "$adapter"): contains hardcoded path"; found_bad=1
    fi
done
[[ "$found_bad" -eq 0 ]] && assert_pass "adapters have no hardcoded user paths"

print_test_results
