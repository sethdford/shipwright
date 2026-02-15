#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright otel test — OpenTelemetry observability                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-otel-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"status":"ok"}'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/curl"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
    # Unset webhook URL to avoid side effects
    unset OTEL_WEBHOOK_URL 2>/dev/null || true
    unset OTEL_EXPORTER_OTLP_ENDPOINT 2>/dev/null || true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright OTel Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-otel.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows metrics" "$output" "metrics"
assert_contains "help shows trace" "$output" "trace"
assert_contains "help shows export" "$output" "export"
assert_contains "help shows webhook" "$output" "webhook"
assert_contains "help shows dashboard" "$output" "dashboard"

# ─── Test 2: Metrics text format (empty events) ──────────────────────────
echo ""
echo -e "${BOLD}  Metrics${RESET}"
output=$(bash "$SCRIPT_DIR/sw-otel.sh" metrics 2>&1) || true
assert_contains "metrics text has pipelines_total" "$output" "shipwright_pipelines_total"
assert_contains "metrics text has active_pipelines" "$output" "shipwright_active_pipelines"
assert_contains "metrics text has cost" "$output" "shipwright_cost_total_usd"
assert_contains "metrics text has queue depth" "$output" "shipwright_queue_depth"

# ─── Test 3: Metrics JSON format ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-otel.sh" metrics json 2>&1) || true
assert_contains "metrics json has metrics key" "$output" '"metrics"'
assert_contains "metrics json has pipelines_total" "$output" "pipelines_total"
# Validate it's valid JSON
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "metrics json is valid JSON"
else
    assert_fail "metrics json is valid JSON" "invalid JSON output"
fi

# ─── Test 4: Trace output ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Trace${RESET}"
output=$(bash "$SCRIPT_DIR/sw-otel.sh" trace 2>&1) || true
assert_contains "trace has resourceSpans" "$output" "resourceSpans"
assert_contains "trace has service.name" "$output" "shipwright"
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "trace output is valid JSON"
else
    assert_fail "trace output is valid JSON" "invalid JSON output"
fi

# ─── Test 5: Dashboard output ────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Dashboard${RESET}"
output=$(bash "$SCRIPT_DIR/sw-otel.sh" dashboard 2>&1) || true
assert_contains "dashboard has dashboard key" "$output" "dashboard"
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "dashboard output is valid JSON"
else
    assert_fail "dashboard output is valid JSON" "invalid JSON output"
fi

# ─── Test 6: Report ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Report${RESET}"
output=$(bash "$SCRIPT_DIR/sw-otel.sh" report 2>&1) || true
assert_contains "report shows header" "$output" "Observability Health Report"
assert_contains "report shows events section" "$output" "Events:"
assert_contains "report shows pipeline metrics" "$output" "Pipeline Metrics:"
assert_contains "report shows recommendations" "$output" "Recommendations:"

# ─── Test 7: Webhook without env var ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Webhook${RESET}"
output=$(OTEL_WEBHOOK_URL="" bash "$SCRIPT_DIR/sw-otel.sh" webhook send 2>&1) && rc=0 || rc=$?
assert_eq "webhook without URL exits non-zero" "1" "$rc"
assert_contains "webhook without URL shows error" "$output" "OTEL_WEBHOOK_URL"

# ─── Test 8: Metrics with events data ────────────────────────────────────
echo ""
echo -e "${BOLD}  Metrics With Events${RESET}"
# Write some events
events_file="$HOME/.shipwright/events.jsonl"
cat > "$events_file" <<'EVENTS'
{"ts":"2026-01-15T10:00:00Z","type":"pipeline_start","issue":1}
{"ts":"2026-01-15T10:05:00Z","type":"pipeline_complete","issue":1}
{"ts":"2026-01-15T10:10:00Z","type":"pipeline_start","issue":2}
{"ts":"2026-01-15T10:15:00Z","type":"pipeline_failed","issue":2}
EVENTS
output=$(bash "$SCRIPT_DIR/sw-otel.sh" metrics json 2>&1) || true
# Check that counters reflect events
total=$(echo "$output" | jq -r '.metrics.pipelines_total.value')
assert_eq "metrics count total pipelines = 2" "2" "$total"

# ─── Test 9: Unknown command ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-otel.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
