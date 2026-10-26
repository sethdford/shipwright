# daemon-failure.sh — Failure classification, retry, backoff (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires state, helpers.
[[ -n "${_DAEMON_FAILURE_LOADED:-}" ]] && return 0
_DAEMON_FAILURE_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
PAUSE_FLAG="${PAUSE_FLAG:-${DAEMON_DIR}/daemon-pause.flag}"
LOG_DIR="${LOG_DIR:-${DAEMON_DIR}/logs}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-autonomous}"
MODEL="${MODEL:-opus}"
WATCH_LABEL="${WATCH_LABEL:-shipwright}"
ON_SUCCESS_REMOVE_LABEL="${ON_SUCCESS_REMOVE_LABEL:-shipwright}"
ON_SUCCESS_ADD_LABEL="${ON_SUCCESS_ADD_LABEL:-pipeline/complete}"
ON_FAILURE_ADD_LABEL="${ON_FAILURE_ADD_LABEL:-pipeline/failed}"
ON_FAILURE_LOG_LINES="${ON_FAILURE_LOG_LINES:-50}"
NO_GITHUB="${NO_GITHUB:-false}"
EVENTS_FILE="${EVENTS_FILE:-${DAEMON_DIR}/events.jsonl}"

# _daemon_classify_ts <log> — prints the TypeScript classifier's class (W2-04). Exit 0 with a
# class; non-zero when Bun or the classifier is unavailable, fails, or does not answer within
# SW_CLASSIFY_TIMEOUT seconds (default 10), so the caller falls back to regex. Exit 3 (escalate)
# still carries a class and is accepted here. The classifier reads only the last 200 lines, the same
# bound the regex path uses (tail -200), copied to a temp file first.
_daemon_classify_ts() {
    local log_path="$1"
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/cli.ts}"
    local timeout_secs="${SW_CLASSIFY_TIMEOUT:-10}"
    command -v "$bun_bin" >/dev/null 2>&1 || return 1
    local bounded out_file pid wd rc=0 out=""
    bounded=$(mktemp "${TMPDIR:-/tmp}/sw-classify-in.XXXXXX") || return 1
    out_file=$(mktemp "${TMPDIR:-/tmp}/sw-classify-out.XXXXXX") || { rm -f "$bounded"; return 1; }
    tail -200 "$log_path" > "$bounded" 2>/dev/null || true
    "$bun_bin" "$cli" failure classify --log "$bounded" --json > "$out_file" 2>/dev/null &
    pid=$!
    # Watchdog: kills the classifier after the timeout. Its output is sent away from the caller's
    # stdout, so a sleeping watchdog cannot hold a $(...) capture open.
    ( sleep "$timeout_secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" || rc=$?
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    out=$(cat "$out_file" 2>/dev/null || true)
    rm -f "$bounded" "$out_file"
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then return 1; fi
    jq -r '.class // empty' <<<"$out" 2>/dev/null || return 1
}

classify_failure() {
    local issue_num="$1"
    if [[ -z "${LOG_DIR:-}" ]]; then
        echo "unknown"
        return
    fi
    local log_path="$LOG_DIR/issue-${issue_num}.log"
    if [[ ! -f "$log_path" ]]; then
        echo "unknown"
        return
    fi
    local tail_content
    tail_content=$(tail -200 "$log_path" 2>/dev/null || true)
    # The text every rule sees, the same normalization as the TypeScript classifier (evidence.ts, #8696): ANSI colour
    # codes, the gh log prefix (`job<TAB>step<TAB>timestamp `, BOM allowed), a trailing CR and a leading BOM removed;
    # a lone CR, U+2028 and U+2029 become line breaks; model prose and loop commit lines are dropped. Every sed, awk
    # and grep here runs under LC_ALL=C, so the caller's locale cannot change a match: BSD sed aborts on an invalid
    # UTF-8 byte in a UTF-8 locale, and GNU grep -i folds `ı` to `i` there. The patterns are byte-exact, and their
    # glyphs are literal byte sequences.
    local esc tab cr bom
    esc="$(printf '\033')"
    tab="$(printf '\t')"
    cr="$(printf '\r')"
    bom="$(printf '\357\273\277')"
    tail_content=$(printf '%s\n' "$tail_content" \
        | LC_ALL=C sed -E "s/${esc}\[[0-9;?]*[A-Za-z]//g; s/^[^${tab}]*${tab}[^${tab}]*${tab}(${bom})?[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z ?//; s/${cr}\$//; s/^${bom}//" \
        | LC_ALL=C awk -v cr="$cr" -v ls="$(printf '\342\200\250')" -v ps="$(printf '\342\200\251')" \
            '{ gsub(cr, "\n"); gsub(ls, "\n"); gsub(ps, "\n"); print }' \
        | LC_ALL=C awk "$_DAEMON_DROP_PROSE")
    # The escalation rules (contamination, auth, invalid input) read error lines only: the same selection as the
    # TypeScript errorLines(), so a bare word in prose or in forged test output does not escalate (#8696).
    # Test-runner output is dropped first, as dropTestTitles() does in evidence.ts.
    local err_lines
    err_lines=$(printf '%s\n' "$tail_content" | LC_ALL=C awk "$_DAEMON_DROP_TEST_OUTPUT" | LC_ALL=C grep -aiE "$_DAEMON_ERROR_LINE" || true)

    # W2-04: the typed classifier decides the auth and invalid-input classes. Both fail safe (no
    # retry). Its `transient` verdict is NOT used here: it comes from free log text, which an agent
    # or issue can write (#8674). Transient must come from trusted data, so the regex below decides
    # as before. Anything else (build_failure, context_exhaustion, unknown) also falls through.
    local ts_class=""
    if ts_class=$(_daemon_classify_ts "$log_path" 2>/dev/null); then
        case "$ts_class" in
            auth) echo "auth_error"; return ;;
            invalid_input) echo "invalid_issue"; return ;;
            contamination) echo "contamination"; return ;;
        esac
    fi

    # Contamination: a run that reached a real service through the test gate, or changed the agent's
    # checkout. Never retried (ADR-0009 rule 10). The same signals as the TS rule, so a host without
    # Bun does not retry it either.
    if printf '%s\n' "$err_lines" | LC_ALL=C grep >/dev/null -aE "$_DAEMON_CONTAMINATION"; then
        echo "contamination"
        return
    fi

    # Auth: the same anchored, structured forms as the TS rule (failure.ts), on error lines only, so a test name or a
    # prose sentence does not escalate (#8696). A retry of an auth failure is fail-open, so both paths must agree.
    if printf '%s\n' "$err_lines" | LC_ALL=C grep >/dev/null -aiE "$_DAEMON_AUTH"; then
        echo "auth_error"
        return
    fi
    # Invalid issue: the anchored gh lookup failures for an issue or PR number, on error lines (#8696). Before the
    # log-text transient rule, so a 503 next to a missing issue is invalid input.
    if printf '%s\n' "$err_lines" | LC_ALL=C grep >/dev/null -aiE "$_DAEMON_INVALID_ISSUE"; then
        echo "invalid_issue"
        return
    fi
    # API errors (rate limits, timeouts, server errors)
    if echo "$tail_content" | grep >/dev/null -iE 'rate limit|429 |503 |502 |overloaded|timeout|ETIMEDOUT|ECONNRESET|socket hang up|service unavailable'; then
        echo "api_error"
        return
    fi
    # Context exhaustion — check progress file
    local issue_worktree_path="${WORKTREE_DIR:-${REPO_DIR}/.worktrees}/daemon-issue-${issue_num}"
    local progress_file="${issue_worktree_path}/.claude/loop-logs/progress.md"
    if [[ -f "$progress_file" ]]; then
        local cf_iter
        cf_iter=$(grep -oE 'Iteration: [0-9]+' "$progress_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
        if ! [[ "${cf_iter:-0}" =~ ^[0-9]+$ ]]; then cf_iter="0"; fi
        local cf_tests
        cf_tests=$(grep -oE 'Tests passing: (true|false)' "$progress_file" 2>/dev/null | awk '{print $NF}' || echo "unknown")
        if [[ "${cf_iter:-0}" -gt 0 ]] && { [[ "$cf_tests" == "false" ]] || [[ "$cf_tests" == "unknown" ]]; }; then
            echo "context_exhaustion"
            return
        fi
    fi
    # Build failure (test errors, compile errors)
    if echo "$tail_content" | grep >/dev/null -iE 'test.*fail|FAIL|build.*error|compile.*error|lint.*fail|npm ERR|exit code [1-9]'; then
        echo "build_failure"
        return
    fi
    echo "unknown"
}

# Error-like lines, the same vocabulary as ERROR_LINE in src/contexts/learning/domain/failure.ts. Keep them in step.
_DAEMON_ERROR_LINE='gh auth login|error|fail|fatal|exception|::error::|enoent|eacces|not found|lockfile|invalid|unauthori[sz]ed|forbidden|denied|overloaded|rate[ _-]?limit|timed? ?out|(^|[^0-9])[45][0-9][0-9]([^0-9]|$)|econn|etimedout|socket hang up|unavailable|authentication|not logged in|refus|contaminat|expired|revoked|could not resolve|does not exist|claude_code_oauth_token|bad credentials|gh_token|not accessible'

# The escalation patterns (#8696), the same as RULES in failure.ts. Keep them in step. They are locale-independent:
# no negated class, no `.`, no [[:space:]], and every non-ASCII glyph is a literal alternative, never inside a
# bracket, so LC_ALL=C (bytes) and a UTF-8 locale (characters) match the same lines. Every quantifier is bounded.
_DAEMON_TAB=$'\t'
# Model-written analysis, pipeline progress markers and loop commit subjects, dropped before every rule (MODEL_PROSE
# and LOOP_COMMIT in evidence.ts). Their text is not evidence of what failed.
_DAEMON_DROP_PROSE='
{ l = tolower($0) }
l ~ /^[ \t]*([^ \t]+[ \t]+)?(failure analyzed|failure diagnosis|analyzing failure)([^a-z0-9_]|$)/ { next }
/^[ \t]*[^ \t]*[ \t]*▸/ { next }
/^[[][^]]+[]][ \t]*loop:/ { next }
{ print }'
# Test-runner output, dropped before the escalation rules (dropTestTitles in evidence.ts): bun `(fail) ` and co.,
# the result glyphs, jest's indented `● ` header, mocha's `  1) ` title block, jest/vitest console blocks, a cargo
# panic message, the error under a vitest ` FAIL  file > test` header and pytest's captured output. No intervals
# or backslash escapes, so any awk (BSD, gawk, mawk) reads it the same.
_DAEMON_DROP_TEST_OUTPUT='
mode == "mocha" && /^[ \t]+[^ \t]/ { if ($0 ~ /:[ \t]*$/) mode = ""; next }
mode == "jest" && /^[ \t]+[^ \t]/ { next }
mode == "console" && $0 !~ /^[ \t]*$/ { next }
mode == "panic" && $0 !~ /^(note|error|stack backtrace):/ && $0 !~ /^[ \t]*$/ { next }
mode == "vitest" && $0 !~ /^ ❯ / && $0 !~ /^[ \t]*$/ { next }
mode == "pytest" && $0 !~ /^(-----|=====|___|FAILED |ERROR |[0-9]+ (failed|passed|error))/ { next }
{ mode = "" }
/^[ \t]*console[.](log|error|warn|info|debug)[ \t]*$/ { mode = "jest"; next }
/^(stderr|stdout) [|] / { mode = "console"; next }
/^thread '"'"'[^'"'"']*'"'"' panicked at / { mode = "panic"; next }
/^ ?FAIL  [^ \t].* (> |[[] )/ || /^(⎯)+ Unhandled (Rejection|Error)/ { mode = "vitest"; next }
/^-----+ Captured (stdout|stderr|log) / { mode = "pytest"; next }
/^[ \t]+[0-9]+[)] / { mode = "mocha"; next }
/^[ \t]*([(](fail|pass|skip|todo)[)] |(✕|✓|√|✔|✖) )/ || /^[ \t]+(●|×) / { next }
{ print }'
# The lead-in before an anchored phrase (LEAD in failure.ts): no leading whitespace (test runners, stack traces and
# agent prose indent), an optional ISO timestamp, `[timestamp] `, `[ERROR] `, then up to two glyphs ✗ ✘ ×. No
# punctuation: `- `, `+ `, `> `, `| `, `* ` and `# ` start diff, quote, table, list and heading lines. Brackets are
# matched as `[[]` and `[]]`, never `\]`, which POSIX ERE leaves undefined outside a bracket expression.
_DAEMON_LEAD="^([0-9]{4}[/-][0-9][0-9][/-][0-9][0-9][T ][0-9:.]{1,20}(Z|[+-][0-9][0-9]:?[0-9][0-9])? {1,2})?([[][0-9][0-9TZ:. +-]{0,38}[]] {1,2})?([[](error|err|fatal)[]] {1,2})?((✗|✘|×|⚠|"$'\xef\xb8\x8f'") {0,2}){0,3}"
# Up to two tool or annotation prefixes (PREFIX).
_DAEMON_PREFIX='((gh|error|fatal)[ :]{1,3}|##[[]error[]] ?|::error:: ?|claude[ ]code returned an error result: |fatal cli error: |cli exited [0-9]{1,3} with minimal output: |pr creation failed: |pull request create failed: ){0,2}'
_DAEMON_END="([ ${_DAEMON_TAB}]{0,3}\$|[.:;!,])"
_DAEMON_HOST='[A-Za-z0-9.-]{1,253}'
_DAEMON_URL_CHARS='[A-Za-z0-9:/._~%@+=?&#-]'
# A quote, optionally backslash-escaped (the body inside a stream-json "result" string).
_DAEMON_Q="\\\\?[\"']"
_DAEMON_AUTH_BODY="\\{${_DAEMON_Q}type${_DAEMON_Q}: ?${_DAEMON_Q}error${_DAEMON_Q}, ?${_DAEMON_Q}error${_DAEMON_Q}: ?\\{${_DAEMON_Q}type${_DAEMON_Q}: ?${_DAEMON_Q}(authentication_error|permission_error)${_DAEMON_Q}"
_DAEMON_AUTH_PHRASES="(claude[ ]code )?authentication failed(${_DAEMON_END}| for '| for https?://| — check )"
_DAEMON_AUTH_PHRASES+="|failed to authenticate${_DAEMON_END}"
_DAEMON_AUTH_PHRASES+="|api error: 401([ ${_DAEMON_TAB}:.,{]|\$)"
_DAEMON_AUTH_PHRASES+="|invalid api key(${_DAEMON_END}|[ ${_DAEMON_TAB}]{0,3}·| provided${_DAEMON_END})"
_DAEMON_AUTH_PHRASES+="|invalid x-api-key(${_DAEMON_END}| token${_DAEMON_END})"
_DAEMON_AUTH_PHRASES+="|oauth token (is |has |has been )?(expired|invalid|revoked)(${_DAEMON_END}|[ ${_DAEMON_TAB}]{0,3}·)"
_DAEMON_AUTH_PHRASES+="|not logged in(${_DAEMON_END}|[ ${_DAEMON_TAB}]{0,3}·| to )"
_DAEMON_AUTH_PHRASES+="|you are not logged into any github hosts|to get started with github cli, please run: {1,2}gh auth login"
_DAEMON_AUTH_PHRASES+="|authentication required${_DAEMON_END}|http 401: requires authentication|requires authentication \\(http 401\\)"
_DAEMON_AUTH_PHRASES+="|(http 401: )?bad credentials([ ${_DAEMON_TAB}]{0,3}\\((https?://|http 401\\))|[ ${_DAEMON_TAB}]{0,3}\$)"
_DAEMON_AUTH_PHRASES+="|(unhandled error: )?(requesterror [[]httperror[]]|httperror): (bad credentials|requires authentication)"
_DAEMON_AUTH_PHRASES+="|request failed with status (code )?401(${_DAEMON_END}| unauthorized${_DAEMON_END})|401 unauthorized(${_DAEMON_END}| - )"
_DAEMON_AUTH_PHRASES+="|claude_code_oauth_token (is )?not set${_DAEMON_END}"
_DAEMON_AUTH_PHRASES+="|to use github cli in a github actions workflow, set the "
_DAEMON_AUTH_PHRASES+="|could not read (username|password) for '${_DAEMON_URL_CHARS}{1,200}': (terminal prompts disabled|no such device or address)"
_DAEMON_AUTH_PHRASES+="|unable to access '${_DAEMON_URL_CHARS}{1,200}': the requested url returned error: 40[13]"
_DAEMON_AUTH_PHRASES+="|remote: write access to repository not granted"
_DAEMON_AUTH_PHRASES+="|[A-Za-z0-9._-]{1,64}@${_DAEMON_HOST}: permission denied \\(publickey"
_DAEMON_AUTH_PHRASES+="|(remote: )?permission to [A-Za-z0-9._/-]{1,200} denied to "
_DAEMON_AUTH_PHRASES+="|npm (err!|error) (code e401|code eneedauth|401 unauthorized)"
_DAEMON_AUTH_PHRASES+="|error response from daemon: [A-Za-z0-9 :/._\"'?=&%@+-]{0,255}unauthorized: authentication required"
_DAEMON_AUTH_PHRASES+="|get https?://${_DAEMON_URL_CHARS}{1,255} - 401[ ${_DAEMON_TAB}]{0,3}\$"
_DAEMON_AUTH_PHRASES+="|(http 403: |graphql: )?resource not accessible by (integration|personal access token)|the token in [a-z_]{1,40} is invalid"
_DAEMON_AUTH_PHRASES+='|please run [`"]?claude login'
_DAEMON_AUTH_PHRASES+="|${_DAEMON_AUTH_BODY}"
# Structured forms that may be indented (AUTH_INDENTED): the bare type name after an error prefix, gh auth status.
_DAEMON_AUTH_INDENTED="(error|fatal)[ :]{1,3}(401 )?authentication_error(:|[ ${_DAEMON_TAB}]{0,3}\$)"
_DAEMON_AUTH_INDENTED+="|x failed to log in to ${_DAEMON_HOST} (account|using token)|x ${_DAEMON_HOST}: authentication failed"
_DAEMON_AUTH_INDENTED+="|- the token in [a-z_]{1,40} is invalid"
_DAEMON_AUTH_RESPONSE="40[13]( -)? ${_DAEMON_AUTH_BODY}"
_DAEMON_AUTH="${_DAEMON_LEAD}${_DAEMON_PREFIX}(${_DAEMON_AUTH_PHRASES})|^[ ${_DAEMON_TAB}]{0,8}(${_DAEMON_AUTH_INDENTED})|${_DAEMON_AUTH_RESPONSE}"
_DAEMON_INVALID_ISSUE="${_DAEMON_LEAD}${_DAEMON_PREFIX}(graphql: could not resolve to an? (issue|pullrequest)([ ${_DAEMON_TAB}.,]|\$)"
_DAEMON_INVALID_ISSUE+="|http 404: not found \\(https://api\\.github\\.com/repos/[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}/(issues|pulls)/[0-9]{1,10}\\)"
_DAEMON_INVALID_ISSUE+="|issue not found([ ${_DAEMON_TAB}]{0,5}\$|:)|issue #?[0-9]{1,10} does not exist${_DAEMON_END})"
_DAEMON_CONTAMINATION="^([ ${_DAEMON_TAB}]|⚠|"$'\xef\xb8\x8f'"|✗|✘|×){0,4}Skipping integration tests: refusing to run inside a build-loop test gate[ ${_DAEMON_TAB}]{0,20}\$"
_DAEMON_CONTAMINATION+="|^CONTAMINATION: (pipeline-state-missing|branch-switched)([ ${_DAEMON_TAB}]|\$)"

# ─── Consecutive Failure Tracking (persisted + adaptive) ─────────────────────

DAEMON_CONSECUTIVE_FAILURE_CLASS=""
DAEMON_CONSECUTIVE_FAILURE_COUNT=0

# Max retries per failure class (adaptive retry strategy)
get_max_retries_for_class() {
    local class="${1:-unknown}"
    case "$class" in
        auth_error|invalid_issue|contamination) echo 0 ;;
        api_error)                echo "${MAX_RETRIES_API_ERROR:-4}" ;;
        context_exhaustion)       echo "${MAX_RETRIES_CONTEXT_EXHAUSTION:-2}" ;;
        build_failure)           echo "${MAX_RETRIES_BUILD:-2}" ;;
        *)                       echo "${MAX_RETRIES:-2}" ;;
    esac
}

# Append failure to persisted history and compute consecutive count; smart pause with exponential backoff
record_failure_class() {
    local failure_class="$1"
    # In-memory consecutive (for backward compat)
    if [[ "$failure_class" == "$DAEMON_CONSECUTIVE_FAILURE_CLASS" ]]; then
        DAEMON_CONSECUTIVE_FAILURE_COUNT=$((DAEMON_CONSECUTIVE_FAILURE_COUNT + 1))
    else
        DAEMON_CONSECUTIVE_FAILURE_CLASS="$failure_class"
        DAEMON_CONSECUTIVE_FAILURE_COUNT=1
    fi

    # Persist failure to state (failure_history) for pattern tracking
    if [[ -f "${STATE_FILE:-}" ]]; then
        local entry
        entry=$(jq -n --arg ts "$(now_iso)" --arg class "$failure_class" '{ts: $ts, class: $class}')
        locked_state_update --argjson entry "$entry" \
            '.failure_history = ((.failure_history // []) + [$entry] | .[-100:])' 2>/dev/null || true
    fi

    # Consecutive count from persisted tail: count only the unbroken run of $failure_class
    # from the newest entry backwards (not total occurrences)
    local consecutive="$DAEMON_CONSECUTIVE_FAILURE_COUNT"
    if [[ -f "${STATE_FILE:-}" ]]; then
        local from_state
        from_state=$(jq -r --arg c "$failure_class" '
            (.failure_history // []) | [.[].class] | reverse |
            if length == 0 then 0
            elif .[0] != $c then 0
            else
                reduce .[] as $x (
                    {count: 0, done: false};
                    if .done then . elif $x == $c then .count += 1 else .done = true end
                ) | .count
            end
        ' "$STATE_FILE" 2>/dev/null || echo "1")
        consecutive="${from_state:-1}"
        [[ "$consecutive" -eq 0 ]] && consecutive="$DAEMON_CONSECUTIVE_FAILURE_COUNT"
        DAEMON_CONSECUTIVE_FAILURE_COUNT="$consecutive"
    fi

    # Smart pause: exponential backoff instead of hard stop (resume_after so daemon can auto-resume)
    if [[ "$consecutive" -ge 3 ]]; then
        local pause_mins=$((5 * (1 << (consecutive - 3))))
        [[ "$pause_mins" -gt 480 ]] && pause_mins=480
        local resume_ts resume_after
        resume_ts=$(($(date +%s) + pause_mins * 60))
        resume_after=$(epoch_to_iso "$resume_ts")
        daemon_log ERROR "${consecutive} consecutive failures (class: ${failure_class}) — auto-pausing until ${resume_after} (${pause_mins}m backoff)"
        local pause_json
        pause_json=$(jq -n \
            --arg reason "consecutive_${failure_class}" \
            --arg ts "$(now_iso)" \
            --arg resume "$resume_after" \
            --argjson count "$consecutive" \
            '{reason: $reason, timestamp: $ts, resume_after: $resume, consecutive_count: $count}')
        local _tmp_pause
        _tmp_pause=$(mktemp "${TMPDIR:-/tmp}/sw-pause.XXXXXX") || { daemon_log ERROR "mktemp failed for pause flag"; return 0; }
        echo "$pause_json" > "$_tmp_pause"
        mv "$_tmp_pause" "$PAUSE_FLAG" || rm -f "$_tmp_pause"
        emit_event "daemon.auto_pause" "reason=consecutive_failures" "class=$failure_class" "count=$consecutive" "resume_after=$resume_after"
    fi
}

reset_failure_tracking() {
    DAEMON_CONSECUTIVE_FAILURE_CLASS=""
    DAEMON_CONSECUTIVE_FAILURE_COUNT=0
}

# ─── Failure Handler ────────────────────────────────────────────────────────

# Key of a finally-failed tombstone (.final_failed). Org mode keys it "owner/repo:number": the same
# number can exist in two repos (ADR-0007). Repo mode keeps the bare number.
daemon_final_failed_key() {
    local issue_num="$1" repo="${2:-}"
    if [[ -n "$repo" ]]; then
        echo "${repo}:${issue_num}"
    else
        echo "$issue_num"
    fi
}

daemon_on_failure() {
    local issue_num="$1" exit_code="${2:-1}" duration="${3:-}" repo_full_name="${4:-}"
    # Org mode: every issue write goes to the job's repo (a bare number means the daemon's own repo).
    local gh_repo_args=()
    if [[ -n "$repo_full_name" ]]; then gh_repo_args=(--repo "$repo_full_name"); fi

    daemon_log ERROR "Pipeline failed for issue #${issue_num} (exit: ${exit_code}, ${duration:-unknown})"

    # Record pipeline duration for adaptive threshold learning
    if [[ -n "$duration" && "$duration" != "unknown" ]]; then
        local dur_secs=0
        local _h _m _s
        _h=$(echo "$duration" | grep -oE '[0-9]+h' | grep -oE '[0-9]+' || true)
        _m=$(echo "$duration" | grep -oE '[0-9]+m' | grep -oE '[0-9]+' || true)
        _s=$(echo "$duration" | grep -oE '[0-9]+s' | grep -oE '[0-9]+' || true)
        dur_secs=$(( ${_h:-0} * 3600 + ${_m:-0} * 60 + ${_s:-0} ))
        if [[ "$dur_secs" -gt 0 ]]; then
            record_pipeline_duration "$PIPELINE_TEMPLATE" "$dur_secs" "failure"
            record_scaling_outcome "$MAX_PARALLEL" "failure"
        fi
    fi

    # Record in completed list
    locked_state_update \
        --argjson num "$issue_num" \
        --arg result "failed" \
        --argjson code "$exit_code" \
        --arg dur "${duration:-unknown}" \
        --arg completed_at "$(now_iso)" \
        '.completed += [{
            issue: $num,
            result: $result,
            exit_code: $code,
            duration: $dur,
            completed_at: $completed_at
        }] | .completed = .completed[-500:]'

    # ── Classify failure and decide retry strategy ──
    local failure_class
    failure_class=$(classify_failure "$issue_num")
    daemon_log INFO "Failure classified as: ${failure_class} for issue #${issue_num}"
    emit_event "daemon.failure_classified" "issue=$issue_num" "class=$failure_class"
    record_failure_class "$failure_class"

    # Why the issue failed finally: "exhausted" (or no retry) unless the gates refused a retry
    local final_reason="exhausted"

    # ── Auto-retry with strategy escalation ──
    if [[ "${RETRY_ESCALATION:-true}" == "true" ]]; then
        local retry_count
        # Read retry count from SQLite first (durable across daemon restarts),
        # then fall back to JSON state file
        local _db_file="${DAEMON_DIR}/shipwright.db"
        if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db_file" ]]; then
            retry_count=$(sqlite3 -cmd ".timeout 3000" "$_db_file" \
                "SELECT COALESCE(MAX(retry_count), 0) FROM daemon_state WHERE issue_number = ${issue_num};" 2>/dev/null || echo "0")
        else
            retry_count=$(jq -r --arg num "$issue_num" \
                '.retry_counts[$num] // 0' "$STATE_FILE" 2>/dev/null || echo "0")
        fi

        # Non-retryable failures — skip retry entirely
        case "$failure_class" in
            auth_error)
                daemon_log ERROR "Auth error for issue #${issue_num} — skipping retry"
                emit_event "daemon.skip_retry" "issue=$issue_num" "reason=auth_error"
                if [[ "$NO_GITHUB" != "true" ]]; then
                    gh issue edit "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --add-label "pipeline/auth-error" 2>/dev/null || true
                fi
                ;;
            contamination)
                daemon_log ERROR "Contamination for issue #${issue_num} — skipping retry (a retry repeats real side effects)"
                emit_event "daemon.skip_retry" "issue=$issue_num" "reason=contamination"
                ;;
            invalid_issue)
                daemon_log ERROR "Invalid issue #${issue_num} — skipping retry"
                emit_event "daemon.skip_retry" "issue=$issue_num" "reason=invalid_issue"
                if [[ "$NO_GITHUB" != "true" ]]; then
                    gh issue comment "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --body "Pipeline skipped retry: issue appears invalid or has no body." 2>/dev/null || true
                fi
                ;;
            *)
                # Retryable failures — per-class max retries and escalation
                local effective_max
                effective_max=$(get_max_retries_for_class "$failure_class")
                if [[ "$retry_count" -lt "$effective_max" ]]; then
                    retry_count=$((retry_count + 1))

                    # Update retry count in state (locked to prevent race)
                    locked_state_update \
                        --arg num "$issue_num" --argjson count "$retry_count" \
                        '.retry_counts[$num] = $count'

                    # Also persist to SQLite (survives daemon restarts/state resets)
                    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db_file" ]]; then
                        sqlite3 -cmd ".timeout 3000" "$_db_file" \
                            "UPDATE daemon_state SET retry_count = ${retry_count} WHERE issue_number = ${issue_num} AND status = 'active';" 2>/dev/null || true
                    fi

                    daemon_log WARN "Auto-retry #${retry_count}/${effective_max} for issue #${issue_num} (class: ${failure_class})"
                    emit_event "daemon.retry" "issue=$issue_num" "retry=$retry_count" "max=$effective_max" "class=$failure_class"

                    # Check for checkpoint to enable resume-from-checkpoint
                    local checkpoint_args=()
                    if [[ "${CHECKPOINT_ENABLED:-true}" == "true" ]]; then
                        local issue_worktree="${REPO_DIR}/.worktrees/daemon-issue-${issue_num}"
                        if [[ -d "$issue_worktree/.claude/pipeline-artifacts/checkpoints" ]]; then
                            local latest_checkpoint=""
                            for cp_file in "$issue_worktree/.claude/pipeline-artifacts/checkpoints"/*-checkpoint.json; do
                                [[ -f "$cp_file" ]] && latest_checkpoint="$cp_file"
                            done
                            if [[ -n "$latest_checkpoint" ]]; then
                                daemon_log INFO "Found checkpoint: $latest_checkpoint"
                                emit_event "daemon.recovery" "issue=$issue_num" "checkpoint=$latest_checkpoint"
                                checkpoint_args+=("--resume")
                            fi
                        fi
                    fi

                    # Build escalated pipeline args
                    local retry_template="$PIPELINE_TEMPLATE"
                    local retry_model="${MODEL:-opus}"
                    local extra_args=()

                    if [[ "$retry_count" -eq 1 ]]; then
                        retry_model="opus"
                        extra_args+=("--max-iterations" "30")
                        daemon_log INFO "Escalation: model=opus, max_iterations=30"
                    elif [[ "$retry_count" -ge 2 ]]; then
                        retry_template="full"
                        retry_model="opus"
                        extra_args+=("--max-iterations" "30" "--compound-cycles" "5")
                        daemon_log INFO "Escalation: template=full, compound_cycles=5"
                    fi

                    # Increase restarts on context exhaustion
                    if [[ "$failure_class" == "context_exhaustion" ]]; then
                        local boosted_restarts=$(( ${MAX_RESTARTS_CFG:-3} + retry_count ))
                        if [[ "$boosted_restarts" -gt 5 ]]; then
                            boosted_restarts=5
                        fi
                        extra_args+=("--max-restarts" "$boosted_restarts")
                        daemon_log INFO "Boosting max-restarts to $boosted_restarts (context exhaustion)"
                    fi

                    # Exponential backoff (per-class base); cap at 1h
                    local base_secs=30
                    [[ "$failure_class" == "api_error" ]] && base_secs=300
                    local backoff_secs=$((base_secs * (1 << (retry_count - 1))))
                    [[ "$backoff_secs" -gt 3600 ]] && backoff_secs=3600
                    [[ "$failure_class" == "api_error" ]] && daemon_log INFO "API error — exponential backoff ${backoff_secs}s"

                    if [[ "$NO_GITHUB" != "true" ]]; then
                        gh issue comment "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --body "## 🔄 Auto-Retry #${retry_count}

Pipeline failed (${failure_class}) — retrying with escalated strategy.

| Field | Value |
|-------|-------|
| Retry | ${retry_count} / ${MAX_RETRIES:-2} |
| Failure | \`${failure_class}\` |
| Template | \`${retry_template}\` |
| Model | \`${retry_model}\` |
| Started | $(now_iso) |

_Escalation: $(if [[ "$retry_count" -eq 1 ]]; then echo "upgraded model + increased iterations"; else echo "full template + compound quality"; fi)_" 2>/dev/null || true
                    fi

                    daemon_log INFO "Waiting ${backoff_secs}s before retry #${retry_count}"
                    sleep "$backoff_secs"

                    # Merge checkpoint args + extra args for passthrough
                    local all_extra_args=()
                    if [[ ${#checkpoint_args[@]} -gt 0 ]]; then
                        all_extra_args+=("${checkpoint_args[@]}")
                    fi
                    if [[ ${#extra_args[@]} -gt 0 ]]; then
                        all_extra_args+=("${extra_args[@]}")
                    fi

                    # Re-spawn with escalated strategy
                    local orig_template="$PIPELINE_TEMPLATE"
                    local orig_model="$MODEL"
                    PIPELINE_TEMPLATE="$retry_template"
                    MODEL="$retry_model"
                    # The retry number feeds the fix-loop cap in the safety gates (ADR-0007).
                    local retry_rc=0
                    DAEMON_RETRY_ATTEMPT="$retry_count" \
                        daemon_spawn_pipeline "$issue_num" "retry-${retry_count}" "$repo_full_name" "${all_extra_args[@]}" \
                        || retry_rc=$?
                    PIPELINE_TEMPLATE="$orig_template"
                    MODEL="$orig_model"
                    if [[ "$retry_rc" -eq 0 ]]; then
                        _retry_spawned_for="$issue_num"
                        return
                    fi
                    # Not spawned: report a final failure so the issue loses the watch label
                    # instead of being re-polled as a first dispatch.
                    if [[ "$retry_rc" -eq "${DAEMON_SPAWN_REFUSED:-75}" ]]; then
                        final_reason="refused by gates/budget"
                        daemon_log WARN "Retry #${retry_count} refused by gates/budget — final failure for issue #${issue_num}"
                    else
                        final_reason="retry spawn failed (rc=${retry_rc})"
                        daemon_log WARN "Retry #${retry_count} failed: ${final_reason} — final failure for issue #${issue_num}"
                    fi
                    emit_event "daemon.retry_refused" "issue=$issue_num" "retry=$retry_count" "rc=$retry_rc"
                else
                    daemon_log WARN "Max retries (${effective_max}) exhausted for issue #${issue_num}"
                    emit_event "daemon.retry_exhausted" "issue=$issue_num" "retries=$retry_count"
                fi

                ;;
        esac
    fi

    # ── No retry — report final failure ──
    # PM agent: record failure for learning (only when we're done with this issue)
    if [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
        bash "$SCRIPT_DIR/sw-pm.sh" learn "$issue_num" failure 2>/dev/null || true
    fi

    if [[ "$NO_GITHUB" != "true" ]]; then
        # Add the failure label and remove the watch label in separate calls: a missing failure
        # label must not leave the watch label in place (the issue would be re-polled as new).
        local marked_labels=()
        if gh issue edit "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --add-label "$ON_FAILURE_ADD_LABEL" 2>/dev/null; then
            marked_labels+=("$ON_FAILURE_ADD_LABEL")
        else
            daemon_log WARN "Could not add '${ON_FAILURE_ADD_LABEL}' to failed issue #${issue_num}"
        fi
        if ! gh issue edit "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --remove-label "$WATCH_LABEL" 2>/dev/null; then
            daemon_log ERROR "Could not remove '${WATCH_LABEL}' from failed issue #${issue_num} — adding shipwright-stuck"
            if gh issue edit "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --add-label "shipwright-stuck" 2>/dev/null; then
                marked_labels+=("shipwright-stuck")
            else
                daemon_log ERROR "Could not add shipwright-stuck to issue #${issue_num}; daemon state keeps it from being dispatched"
            fi
            # The issue still carries the watch label: the poll loop skips it until a human
            # removes every marked label (or the watch label). With nothing marked, the entry
            # stays until the watch label is gone or the state is edited by hand (fail closed).
            local marked_json
            marked_json=$(printf '%s\n' ${marked_labels[@]+"${marked_labels[@]}"} | jq -R . | jq -s -c 'map(select(length > 0))')
            local ff_key
            ff_key=$(daemon_final_failed_key "$issue_num" "$repo_full_name")
            locked_state_update --arg num "$ff_key" --arg ts "$(now_iso)" --argjson marked "$marked_json" \
                '.final_failed[$num] = {ts: $ts, marked: $marked}' || \
                daemon_log ERROR "Could not record final failure of issue #${issue_num} in daemon state"
        fi

        # Close any draft PR created for this issue (cleanup abandoned work)
        local draft_pr
        draft_pr=$(gh pr list ${gh_repo_args[@]+"${gh_repo_args[@]}"} --head "daemon/issue-${issue_num}" --head "pipeline/pipeline-issue-${issue_num}" \
            --json number,isDraft --jq '.[] | select(.isDraft == true) | .number' 2>/dev/null | head -1 || true)
        if [[ -n "$draft_pr" ]]; then
            gh pr close "$draft_pr" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --delete-branch 2>/dev/null || true
            daemon_log INFO "Closed draft PR #${draft_pr} for failed issue #${issue_num}"
        fi

        # Comment with log tail
        local log_tail=""
        local log_path="$LOG_DIR/issue-${issue_num}.log"
        if [[ -f "$log_path" ]]; then
            log_tail=$(tail -"$ON_FAILURE_LOG_LINES" "$log_path" 2>/dev/null || true)
        fi

        local retry_info=""
        if [[ "${RETRY_ESCALATION:-true}" == "true" ]]; then
            local final_count final_max
            final_count=$(jq -r --arg num "$issue_num" \
                '.retry_counts[$num] // 0' "$STATE_FILE" 2>/dev/null || echo "0")
            final_max=$(get_max_retries_for_class "$failure_class")
            retry_info="| Retries | ${final_count} / ${final_max} (${final_reason}) |"
        fi

        gh issue comment "$issue_num" ${gh_repo_args[@]+"${gh_repo_args[@]}"} --body "## ❌ Pipeline Failed

The autonomous pipeline encountered an error.

| Field | Value |
|-------|-------|
| Exit Code | ${exit_code} |
| Duration | ${duration:-unknown} |
| Failed At | $(now_iso) |
${retry_info}

<details>
<summary>Last ${ON_FAILURE_LOG_LINES} lines of log</summary>

\`\`\`
${log_tail}
\`\`\`

</details>

_Re-add the \`${WATCH_LABEL}\` label to retry._" 2>/dev/null || true
    fi

    notify "Pipeline Failed — Issue #${issue_num}" \
        "Exit code: ${exit_code}, Duration: ${duration:-unknown}" "error"
    "$SCRIPT_DIR/sw-tracker.sh" notify "failed" "$issue_num" "Exit code: ${exit_code}, Duration: ${duration:-unknown}" 2>/dev/null || true
}

# ─── Intelligent Triage ──────────────────────────────────────────────────────

# Score an issue from 0-100 based on multiple signals for intelligent prioritization.
# Combines priority labels, age, complexity, dependencies, type, and memory signals.
# When intelligence engine is enabled, uses semantic AI analysis for richer scoring.
