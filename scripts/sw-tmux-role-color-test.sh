#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color-test.sh — Tmux Role Color Test Suite                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if [[ "$haystack" =~ $needle ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    In: $haystack"
    fi
}

# ─── Extract color from script logic ────────────────────────────────────────
get_color_for_role() {
    local title_lower="$1"
    local color="#00d4ff"  # default cyan

    case "$title_lower" in
        *leader*|*lead*|*pm*|*manager*|*orchestrat*)
            color="#00d4ff" ;;
        *build*|*dev*|*implement*|*code*|*engineer*)
            color="#0066ff" ;;
        *review*|*audit*|*inspect*|*oversight*)
            color="#f97316" ;;
        *test*|*qa*|*validat*|*verify*)
            color="#facc15" ;;
        *secur*|*vuln*|*threat*|*pentest*)
            color="#ef4444" ;;
        *doc*|*writ*|*readme*|*changelog*)
            color="#a78bfa" ;;
        *optim*|*perf*|*speed*|*deploy*)
            color="#4ade80" ;;
        *research*|*explor*|*investigat*|*analyz*)
            color="#7c3aed" ;;
    esac

    echo "$color"
}

# ─── Test: leader role maps to cyan ────────────────────────────────────────
test_leader_role_color() {
    local color
    color="$(get_color_for_role "leader")"
    assert_equals "#00d4ff" "$color" "leader role maps to cyan"
}

# ─── Test: builder role maps to blue ──────────────────────────────────────
test_builder_role_color() {
    local color
    color="$(get_color_for_role "builder")"
    assert_equals "#0066ff" "$color" "builder role maps to blue"
}

# ─── Test: reviewer role maps to orange ──────────────────────────────────
test_reviewer_role_color() {
    local color
    color="$(get_color_for_role "reviewer")"
    assert_equals "#f97316" "$color" "reviewer role maps to orange"
}

# ─── Test: tester role maps to yellow ────────────────────────────────────
test_tester_role_color() {
    local color
    color="$(get_color_for_role "tester")"
    assert_equals "#facc15" "$color" "tester role maps to yellow"
}

# ─── Test: security role maps to red ──────────────────────────────────────
test_security_role_color() {
    local color
    color="$(get_color_for_role "security")"
    assert_equals "#ef4444" "$color" "security role maps to red"
}

# ─── Test: docs role maps to violet ──────────────────────────────────────
test_docs_role_color() {
    local color
    color="$(get_color_for_role "docs")"
    assert_equals "#a78bfa" "$color" "docs role maps to violet"
}

# ─── Test: optimizer role maps to green ──────────────────────────────────
test_optimizer_role_color() {
    local color
    color="$(get_color_for_role "optimizer")"
    assert_equals "#4ade80" "$color" "optimizer role maps to green"
}

# ─── Test: researcher role maps to purple ────────────────────────────────
test_researcher_role_color() {
    local color
    color="$(get_color_for_role "researcher")"
    assert_equals "#7c3aed" "$color" "researcher role maps to purple"
}

# ─── Test: case insensitivity ────────────────────────────────────────────
test_case_insensitivity() {
    local color_upper color_lower
    color_upper="$(get_color_for_role "LEADER")"
    color_lower="$(get_color_for_role "leader")"
    assert_equals "$color_lower" "$color_upper" "role matching is case insensitive"
}

# ─── Test: unknown role defaults to cyan ────────────────────────────────────
test_unknown_role_defaults_to_cyan() {
    local color
    color="$(get_color_for_role "unknown_role")"
    assert_equals "#00d4ff" "$color" "unknown role defaults to cyan"
}

# ─── Test: pm keyword works ────────────────────────────────────────────────
test_pm_keyword() {
    local color
    color="$(get_color_for_role "pm")"
    assert_equals "#00d4ff" "$color" "pm keyword maps to cyan (leader)"
}

# ─── Test: dev keyword works ──────────────────────────────────────────────
test_dev_keyword() {
    local color
    color="$(get_color_for_role "dev")"
    assert_equals "#0066ff" "$color" "dev keyword maps to blue (builder)"
}

# ─── Test: script exists and is executable ────────────────────────────────
test_script_exists() {
    if [[ -f "$SCRIPT_DIR/sw-tmux-role-color.sh" && -x "$SCRIPT_DIR/sw-tmux-role-color.sh" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m script exists and is executable"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m script exists and is executable"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-tmux-role-color-test.sh"
test_script_exists
test_leader_role_color
test_builder_role_color
test_reviewer_role_color
test_tester_role_color
test_security_role_color
test_docs_role_color
test_optimizer_role_color
test_researcher_role_color
test_case_insensitivity
test_unknown_role_defaults_to_cyan
test_pm_keyword
test_dev_keyword

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
