# shellcheck shell=bash
# pr-steward-stage.sh — the `steward` pipeline stage and the pre-PR scan (ADR-0017). Sourced by
# pr-steward.sh, which holds the helpers. Bash 3.2 compatible.
[[ -n "${_PR_STEWARD_STAGE_LOADED:-}" ]] && return 0
_PR_STEWARD_STAGE_LOADED=1

# stage_steward — after the PR opens: rounds of inspect → fix | rerun | wait, until done or stop.
# Returns 0 only when the PR is green with nothing left to answer (or merged), so `merge` never
# runs on a red PR. A stop leaves the PR open for a person, with the reason in the log and events.
stage_steward() {
    CURRENT_STAGE_ID="steward"
    if [[ "${NO_GITHUB:-false}" == "true" ]] || _steward_off "${SHIPWRIGHT_STEWARD:-on}"; then
        info "Steward stage skipped (no GitHub or SHIPWRIGHT_STEWARD=off)"
        return 0
    fi
    if ! _steward_available; then
        warn "Steward stage skipped: ${SW_BUN:-bun} or the TypeScript CLI is not installed"
        _steward_emit "steward.unavailable" "issue=${ISSUE_NUMBER:-0}" "reason=no_ts_cli"
        return 0
    fi
    local pr
    pr=$(_steward_find_pr) || { error "Steward: cannot list PRs for ${GIT_BRANCH}"; return 1; }
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        warn "Steward: no open PR for ${GIT_BRANCH}; nothing to watch"
        return 0
    fi
    STEWARD_DIR="${ARTIFACTS_DIR}/steward"
    mkdir -p "$STEWARD_DIR"
    [[ -s "${STEWARD_DIR}/history.json" ]] || echo '{}' > "${STEWARD_DIR}/history.json"
    _steward_rounds "$pr"
}

# _steward_find_pr — the PR this run opened (PR_NUMBER from stage_pr), else this repository's own
# open PR for the branch. Never a fork's PR with the same branch name. Fails when gh cannot answer.
_steward_find_pr() {
    if [[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$PR_NUMBER"
        return 0
    fi
    gh pr list --head "$GIT_BRANCH" --state open --json number,isCrossRepository \
        --jq '[.[] | select(.isCrossRepository == false)][0].number // empty'
}

_steward_rounds() {
    local pr="$1" n=0 errors=0 timeout poll deadline action report grace no_checks_at
    # The floors keep a template from hammering the GitHub API; tests lower them via the env.
    timeout=$(_steward_int wait_timeout_s 3600 "${STEWARD_MIN_WAIT_S:-60}" 21600)
    poll=$(_steward_int poll_interval_s 60 "${STEWARD_MIN_POLL_S:-10}" 600)
    deadline=$(( $(date +%s) + timeout ))
    # After this long with no checks at all, the PR has no CI: it can be done without them.
    grace=$(_steward_int no_checks_grace_s 600 0 21600)
    no_checks_at=$(( $(date +%s) + grace ))
    info "Steward: watching PR #${pr} (checks and review comments; up to ${timeout}s)"
    while :; do
        n=$((n + 1))
        report="${STEWARD_DIR}/inspect-${n}.json"
        local no_checks_ok=no
        # SW_REQUIRE_CI=1 (the CI pipeline): a PR with no checks is never done; it waits for a person.
        if [[ "${SW_REQUIRE_CI:-0}" != "1" && "$(date +%s)" -ge "$no_checks_at" ]]; then no_checks_ok=yes; fi
        if ! _steward_inspect "$pr" "$report" "$no_checks_ok"; then
            errors=$((errors + 1))
            [[ "$errors" -ge 3 ]] && { error "Steward: cannot read PR #${pr} from GitHub"; return 1; }
        else
            errors=0
            local act_rc=0
            action=$(jq -r '.decision.action' "$report")
            _steward_act "$pr" "$report" "$action" || act_rc=$?
            case "$act_rc" in
                0) return 0 ;;   # done
                1) return 1 ;;   # stop or a failed round
            esac                 # 2 waiting, 3 pushed a fix: either way, poll again after a pause
                                 # (GitHub needs a moment to register the new head's checks)
        fi
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            warn "Steward: PR #${pr} not green after ${timeout}s; leaving it open"
            _steward_emit "steward.timeout" "issue=${ISSUE_NUMBER:-0}" "pr=${pr}"
            return 1
        fi
        sleep "$poll"
    done
}

_steward_inspect() {
    local pr="$1" report="$2" no_checks_ok="${3:-no}" max
    max=$(_steward_int max_rounds 3 0 20)
    _steward_cli inspect --pr "$pr" --history "${STEWARD_DIR}/history.json" --max-rounds "$max" \
        --no-checks-ok "$no_checks_ok" --format json > "$report" 2> "${report}.err" && jq -e '.decision.action' "$report" >/dev/null 2>&1
}

# _steward_act PR REPORT ACTION — 0 done, 1 stop, 2 keep waiting, 3 fixed (inspect again now).
_steward_act() {
    local pr="$1" report="$2" action="$3" reason
    reason=$(jq -r '.decision.reason' "$report")
    case "$action" in
        done)
            success "Steward: PR #${pr} is ready — ${reason}"
            _steward_emit "steward.done" "issue=${ISSUE_NUMBER:-0}" "pr=${pr}"
            return 0 ;;
        stop)
            warn "Steward: stopping on PR #${pr} — ${reason}"
            _steward_emit "steward.stopped" "issue=${ISSUE_NUMBER:-0}" "pr=${pr}" "reason=${reason}"
            return 1 ;;
        rerun)
            _steward_rerun "$pr" "$report"
            return 2 ;;
        fix)
            _steward_fix "$pr" "$report" || return 1
            return 3 ;;
    esac
    return 2
}

_steward_rerun() {
    local pr="$1" report="$2" checks csv
    checks=$(jq -c '.decision.rerunChecks' "$report")
    csv=$(jq -r '.decision.rerunJobs | map(tostring) | join(",")' "$report")
    info "Steward: re-running infrastructure failures (jobs ${csv})"
    if _steward_cli rerun --pr "$pr" --jobs "$csv"; then
        _steward_history_rerun "${STEWARD_DIR}/history.json" "$checks"
        _steward_emit "steward.rerun" "issue=${ISSUE_NUMBER:-0}" "pr=${pr}" "jobs=${csv}"
    else
        warn "Steward: re-run failed; will look again"
    fi
}

# _steward_fix PR REPORT — one fix round: sync to the PR head, run the fixer, push, reply.
_steward_fix() {
    local pr="$1" report="$2" head round goal sha out unhandled
    head=$(jq -r '.headSha' "$report")
    _steward_sync_head "$head" || return 1
    round=$(( $(jq -r '.rounds // 0' "${STEWARD_DIR}/history.json") + 1 ))
    info "Steward round ${round} on PR #${pr}: $(jq -r '.decision.reason' "$report")"
    goal=$(_steward_brief "$report")
    sha=$(_steward_handoff_fix "$goal" "fix: address CI and review feedback (steward round ${round})" "$round") \
        || { _steward_emit "steward.round_failed" "issue=${ISSUE_NUMBER:-0}" "pr=${pr}" "round=${round}"; return 1; }
    local changed=yes
    if [[ -n "$sha" ]]; then
        # The TS push re-checks the target and scans the round's change; it refuses on a secret.
        _steward_cli push --pr "$pr" --branch "$GIT_BRANCH" --sha "$sha" --from "$head" \
            --repo-dir "$PROJECT_ROOT" || { error "Steward: push refused or failed"; return 1; }
    else
        sha="$head" changed=no
        info "Steward: the fixer changed no code this round"
    fi
    out=$(_steward_cli reply --pr "$pr" --sha "$sha" --report "$report" --changed "$changed" \
        --replies "${STEWARD_DIR}/replies-${round}.json" --format json) || { error "Steward: replies failed"; return 1; }
    unhandled=$(printf '%s' "$out" | jq -c '.unhandled // []' 2>/dev/null) || unhandled=""
    # The round only counts once it is in the history; without that the limits could not hold.
    _steward_history_after_fix "${STEWARD_DIR}/history.json" "$report" "$unhandled" \
        || { error "Steward: could not record round ${round}"; return 1; }
    _steward_emit "steward.round" "issue=${ISSUE_NUMBER:-0}" "pr=${pr}" "round=${round}" "head=${sha}"
}

# _steward_sync_head SHA — the trusted checkout must sit at the PR head before a round. When
# someone else pushed to the branch, fast-forward to it (fetch only; never a reset or force).
_steward_sync_head() {
    local want="$1" have
    have=$(git -C "$PROJECT_ROOT" rev-parse HEAD) || return 1
    [[ "$have" == "$want" ]] && return 0
    git -C "$PROJECT_ROOT" -c core.hooksPath=/dev/null fetch -q origin "refs/heads/${GIT_BRANCH}" 2>/dev/null \
        && [[ "$(git -C "$PROJECT_ROOT" rev-parse FETCH_HEAD)" == "$want" ]] \
        && git -C "$PROJECT_ROOT" -c core.hooksPath=/dev/null merge -q --ff-only "$want" 2>/dev/null \
        && return 0
    error "Steward: local branch is at ${have:0:12}, PR head is ${want:0:12}, and it is not a fast-forward"
    return 1
}

# steward_preflight BASE_REF — the pre-PR self-scan. 0 go on, 1 do not push.
# An install without bun or the TypeScript CLI skips the scan with a warning and an event (like the
# merge verifier). Once the scan runs, it fails closed: an error blocks the push, since a diff
# could be shaped to crash it (SHIPWRIGHT_STEWARD_SCAN=off to override).
steward_preflight() {
    local base="$1" rc=0 out
    _steward_off "${SHIPWRIGHT_STEWARD_SCAN:-on}" && return 0
    if ! _steward_available; then
        warn "Pre-PR scan skipped: ${SW_BUN:-bun} or the TypeScript CLI is not installed"
        _steward_emit "pr.scan_unavailable" "issue=${ISSUE_NUMBER:-0}" "reason=no_ts_cli"
        return 0
    fi
    STEWARD_DIR="${ARTIFACTS_DIR}/steward"
    mkdir -p "$STEWARD_DIR"
    out="${STEWARD_DIR}/scan.json"
    _steward_cli scan --base "$base" --format json > "$out" 2>/dev/null || rc=$?
    _steward_preflight_verdict "$rc" "$out" "$base"
}

_steward_preflight_verdict() {
    local rc="$1" out="$2" base="$3" rc2=0
    case "$rc" in
        0) return 0 ;;
        3)
            error "Pre-PR scan: a secret is in the diff — not pushing ($(_steward_scan_list "$out" block))"
            _steward_emit "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=secret_in_diff"
            return 1 ;;
        4) ;;
        *)
            error "Pre-PR scan could not run (exit ${rc}); not pushing (SHIPWRIGHT_STEWARD_SCAN=off overrides)"
            _steward_emit "pr.scan_unavailable" "issue=${ISSUE_NUMBER:-0}" "exit=${rc}"
            return 1 ;;
    esac
    info "Pre-PR scan: $(_steward_scan_list "$out" fix); one fix round"
    _steward_handoff_fix "$(_steward_scan_goal "$out")" "fix: pre-PR scan findings" "scan" >/dev/null || return 1
    _steward_cli scan --base "$base" --format json > "$out" 2>/dev/null || rc2=$?
    [[ "$rc2" == "0" ]] && return 0
    error "Pre-PR scan still fails after a fix round: $(_steward_scan_list "$out" fix)"
    _steward_emit "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=scan_findings"
    return 1
}

_steward_scan_list() {
    jq -r --arg s "$2" '[.findings[]? | select(.severity == $s) | "\(.path):\(.line) \(.rule)"] | join(", ")' "$1" 2>/dev/null
}

_steward_scan_goal() {
    local findings
    findings=$(jq -r '.findings[]? | select(.severity == "fix") | "- \(.path):\(.line): \(.message)"' "$1")
    printf '%s\n\n%s' "The pre-PR scan found these problems in lines this branch adds. Fix each one and change nothing else. Do not delete or skip tests." \
        "$(untrusted_block "pre-PR scan findings" "$findings")"
}
