#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright integration-claude test — Budget-limited real Claude smoke   ║
# ║  One minimal API call · Target ~$0.25/PR · Runs in PR gate when secret set║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUDGET_TARGET_USD="0.25"
SCRIPT_TIMEOUT=120

# ─── Skip when no Claude auth (CI without secret, local dev) ─────────────────
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "Skipping integration-claude: no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY (budget-limited PR gate runs only when secret is set)"
    exit 0
fi

if ! command -v claude &>/dev/null; then
    echo "Skipping integration-claude: claude CLI not found (install with: npm install -g @anthropic-ai/claude-code)"
    exit 0
fi

# ─── Single minimal Claude call (tiny prompt, one turn) ────────────────────────
# Target: stay under ~$0.25; one short exchange is well under that.
echo "Running budget-limited Claude smoke (target ~\$${BUDGET_TARGET_USD}/run, one minimal request)..."
out_file=$(mktemp "${TMPDIR:-/tmp}/sw-claude-smoke.XXXXXX")
err_file=$(mktemp "${TMPDIR:-/tmp}/sw-claude-smoke-err.XXXXXX")
cleanup() { rm -f "$out_file" "$err_file"; }
trap cleanup EXIT

run_claude() {
    if command -v timeout &>/dev/null; then
        timeout "$SCRIPT_TIMEOUT" claude -p "Reply with exactly: OK" --max-turns 1 2>"$err_file" | head -c 4096 > "$out_file"
    else
        claude -p "Reply with exactly: OK" --max-turns 1 2>"$err_file" | head -c 4096 > "$out_file"
    fi
}
if ! run_claude; then
    exit_code=$?
    if [[ "$exit_code" -eq 124 ]]; then
        echo "FAIL: Claude smoke timed out after ${SCRIPT_TIMEOUT}s"
    else
        echo "FAIL: Claude call failed (exit $exit_code)"
        cat "$err_file" >&2
    fi
    exit 1
fi

if ! grep -q "OK" "$out_file" 2>/dev/null; then
    echo "FAIL: Unexpected response (expected to contain OK):"
    head -20 "$out_file"
    exit 1
fi

echo "PASS: integration-claude smoke completed"
exit 0
