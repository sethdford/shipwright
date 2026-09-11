#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright integration-claude test — Budget-limited real Claude smoke   ║
# ║  One minimal API call · Target ~$0.25/PR · Runs in PR gate when secret set║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC2034
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
    if command -v gtimeout &>/dev/null; then
        gtimeout "$SCRIPT_TIMEOUT" claude -p "Reply with exactly: OK" --max-turns 1 2>"$err_file" | head -c 4096 > "$out_file"
    elif command -v timeout &>/dev/null; then
        timeout "$SCRIPT_TIMEOUT" claude -p "Reply with exactly: OK" --max-turns 1 2>"$err_file" | head -c 4096 > "$out_file"
    else
        claude -p "Reply with exactly: OK" --max-turns 1 2>"$err_file" | head -c 4096 > "$out_file"
    fi
}
# `if ! run_claude; then exit_code=$?` captures the status of the `!` negation,
# which is 0 whenever the branch is taken — so every failure reported
# "Claude call failed (exit 0)" and the real cause was unrecoverable. Run it
# outside the condition and read $? directly.
set +e
run_claude
exit_code=$?
set -e

# ─── Quota exhaustion is environmental, not a regression ─────────────────────
# This gate exists to catch "a real Claude call broke". Account-level quota is
# a different thing: it says nothing about the commit, it resolves on a clock
# rather than on a fix, and failing hard on it makes every PR in the queue
# hostage to usage limits. Treat it the way a missing credential is already
# treated — skip loudly, exit 0 — while every other non-zero exit still fails.
# Matching is on specific quota phrases only, so a genuine error is never
# swallowed.
combined_output="$(cat "$out_file" "$err_file" 2>/dev/null || true)"
if [[ "$exit_code" -ne 0 ]] && printf '%s' "$combined_output" \
        | grep -iE 'weekly limit|usage limit|rate limit|rate_limit_error|overloaded_error' >/dev/null; then
    echo "SKIP: Claude account quota reached, not a code failure — the gate cannot"
    echo "      run until it resets. Reported by the CLI as:"
    printf '        %s\n' "$combined_output"
    exit 0
fi

if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$exit_code" -eq 124 ]]; then
        echo "FAIL: Claude smoke timed out after ${SCRIPT_TIMEOUT}s"
    else
        echo "FAIL: Claude call failed (exit $exit_code)"
        # Dump BOTH streams. The CLI reports most failures — expired
        # credentials, rate limits, bad flags — on stdout, so printing only
        # stderr left CI showing a bare "exit 1" with nothing to act on. That
        # is what made this job's real cause invisible across several runs and
        # sent an earlier fix after the sandbox warning, which turned out to be
        # unrelated noise rather than the failure.
        if [[ -s "$err_file" ]]; then
            echo "--- stderr ---" >&2
            cat "$err_file" >&2
        fi
        if [[ -s "$out_file" ]]; then
            echo "--- stdout ---" >&2
            cat "$out_file" >&2
        fi
        if [[ ! -s "$err_file" && ! -s "$out_file" ]]; then
            echo "--- both streams empty; the CLI exited without reporting a reason ---" >&2
            echo "Most likely an auth problem: check that CLAUDE_CODE_OAUTH_TOKEN is" >&2
            echo "still valid (they expire) or that ANTHROPIC_API_KEY is set." >&2
        fi
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
