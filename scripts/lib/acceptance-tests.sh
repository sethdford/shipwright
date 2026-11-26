# acceptance-tests.sh — spec-first acceptance tests for the pipeline (ADR-0015).
#
# Before any implementation, a test writer turns the issue into numbered acceptance criteria
# (AC-1, AC-2, ...) and new test files that check them. `shipwright acceptance` (TypeScript)
# then proves each file red for the right reason, the files are committed and locked, and the
# test stage gates the build on the locked tests passing (restored byte for byte), with an
# integrity check for weakened tests. This file only orchestrates: decisions live in
# src/contexts/planning.
#
# Mode (SW_ACCEPTANCE, else acceptance.mode in the pipeline config, else enforce):
#   enforce  no proven-red tests → the pipeline stops; acceptance failures or tampering fail the test stage
#   warn     everything runs and is reported; nothing blocks
#   off      the old behavior: no acceptance tests (ablation switch for the eval ratchet)
# The writer may answer not_testable with a reason (docs or config-only changes); that is
# recorded in the artifacts and the run continues without an acceptance gate.
#
# Source from pipeline-stages-build.sh. Requires ARTIFACTS_DIR, PROJECT_ROOT, SCRIPT_DIR.

[[ -n "${_ACCEPTANCE_TESTS_LOADED:-}" ]] && return 0
_ACCEPTANCE_TESTS_LOADED=1

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"

# acceptance_mode — off | warn | enforce
acceptance_mode() {
    local mode="${SW_ACCEPTANCE:-}"
    if [[ -z "$mode" && -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-}" ]]; then
        mode=$(jq -r '.acceptance.mode // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
    fi
    case "${mode:-enforce}" in
        off|false|0) echo "off" ;;
        warn|advisory) echo "warn" ;;
        *) echo "enforce" ;;
    esac
}

acceptance_manifest_file() { echo "${ARTIFACTS_DIR}/acceptance.json"; }

# acceptance_lock_file — the lock the gate trusts. It lives in the state dir, outside the working
# tree the build agent can write (its Edit/Write permissions are ./** only), keyed by repository,
# branch and issue so a resumed run finds it. A copy goes to the artifacts for people to read.
acceptance_lock_file() {
    local branch key
    branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
    key=$(printf '%s|%s|%s' "$PROJECT_ROOT" "$branch" "${ISSUE_NUMBER:-0}" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16)
    echo "${SHIPWRIGHT_STATE_DIR:-${HOME}/.shipwright}/acceptance/${key}/acceptance-lock.json"
}

# acceptance_lock_current — 0 when a lock exists whose commit is in this branch's history (resume).
acceptance_lock_current() {
    local lock commit
    lock=$(acceptance_lock_file)
    [[ -f "$lock" ]] || return 1
    commit=$(jq -r '.commit // empty' "$lock" 2>/dev/null || true)
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    git -C "$PROJECT_ROOT" merge-base --is-ancestor "$commit" HEAD 2>/dev/null
}

# _acceptance_sw — the shipwright CLI (the TS commands need bun).
_acceptance_sw() {
    "${SCRIPT_DIR}/sw" acceptance "$@"
}

# _acceptance_command_args — optional --command from acceptance.command (a JSON argv with {file}).
_acceptance_command_json() {
    local cmd="${SW_ACCEPTANCE_COMMAND:-}"
    if [[ -z "$cmd" && -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-}" ]]; then
        cmd=$(jq -c '.acceptance.command // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
    fi
    printf '%s' "$cmd"
}

# acceptance_prompt REQUIREMENTS TEST_CMD FEEDBACK — the test writer's prompt.
acceptance_prompt() {
    local requirements="$1" test_cmd="$2" feedback="$3"
    cat <<PROMPT
You are the test writer. Nobody has implemented this change yet. Turn the requirements below
into executable acceptance tests that FAIL NOW and will PASS once the change is implemented
correctly. A separate agent implements the change later and is graded by your tests; it cannot
edit them.

Requirements:
${requirements}

Steps:
1. Read the code you need (public interfaces, existing tests, test helpers, conventions).
2. Write numbered acceptance criteria AC-1, AC-2, ... Each is one observable behavior the
   issue asks for, stated from the caller's or user's side. Include the error and edge cases
   the issue implies. Do not invent requirements the issue does not ask for.
3. Write NEW test files (never edit existing files) in the project's test framework and
   layout. The project's test command is: ${test_cmd}
   Every test title starts with the criterion it checks, e.g. "AC-2: rejects an expired token".
4. Each test must fail now for the right reason: an assertion on the missing behavior, or an
   import/call of the not-yet-written function or module the requirements name. It must NOT fail
   from a syntax error, a wrong import path for code that already exists, a missing test
   framework, the network or randomness. A test that passes now is rejected.
5. Test behavior through public interfaces with concrete expected values. No mocks of the unit
   under test, no snapshot tests, no sleeps, no tests that would pass with a stub returning a
   constant for every input (use at least two distinct inputs per criterion where it applies).

Answer with exactly one fenced block labelled acceptance.json and one fenced block per test file,
labelled with its repository-relative path. Do not create, edit or commit files yourself:
shipwright writes your answer (any change you make is undone and the answer rejected).

\`\`\`acceptance.json
{"criteria":[{"id":"AC-1","text":"..."}],
 "tests":[{"path":"tests/feature.test.ts","criteria":["AC-1"]}],
 "run":["<runner>","...","{file}"]}
\`\`\`
\`\`\`tests/feature.test.ts
...
\`\`\`

"run" is optional: the argv that runs ONE test file ({file} is replaced by its path), used only
when the project's test command cannot be narrowed to one file.

Only if the change has no behavior a test can observe (documentation, comments, CI or editor
configuration), answer instead with just:
\`\`\`acceptance.json
{"not_testable":"<one sentence why>"}
\`\`\`
PROMPT
    if [[ -n "$feedback" ]]; then
        cat <<PROMPT

Your previous answer was rejected. Fix every point below and answer again in full:
${feedback}
PROMPT
    fi
}

# _acceptance_requirements — plan, goal file, or issue text.
_acceptance_requirements() {
    local plan_file="${ARTIFACTS_DIR}/plan.md" goal_file="${PROJECT_ROOT}/.claude/goal.md"
    # Issue text is untrusted (trust boundary): wrapped so the model treats it as data, not instructions.
    local text
    if type untrusted_wrap >/dev/null 2>&1; then
        text=$(untrusted_wrap "issue title and body" "${GOAL:-}

${ISSUE_BODY:-}")
    else
        text="${GOAL:-}

${ISSUE_BODY:-}"
    fi
    if [[ -s "$plan_file" ]]; then
        text="${text}

Implementation plan (for where things will live; the issue decides what is required):
$(head -c 20000 "$plan_file")"
    elif [[ -s "$goal_file" ]]; then
        text="${text}

$(head -c 20000 "$goal_file")"
    fi
    printf '%s' "$text"
}

# _acceptance_discard — remove the test files a rejected answer wrote (they are always new files).
_acceptance_discard() {
    local manifest="$1" p
    [[ -f "$manifest" ]] || return 0
    while IFS= read -r p; do
        [[ -z "$p" || "$p" == /* || "$p" == *..* ]] && continue
        rm -f -- "${PROJECT_ROOT}/${p}"
    done < <(jq -r '.tests[]?.path // empty' "$manifest" 2>/dev/null || true)
    rm -f "$manifest"
}

# _acceptance_commit_and_lock MANIFEST TEST_CMD — commit exactly the test files, then lock them.
_acceptance_commit_and_lock() {
    local manifest="$1" test_cmd="$2" paths=() p ids
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done \
        < <(jq -r '.tests[].path' "$manifest" 2>/dev/null)
    [[ ${#paths[@]} -gt 0 ]] || return 1
    ids=$(jq -r '[.criteria[].id] | join(", ")' "$manifest" 2>/dev/null || echo "")
    git -C "$PROJECT_ROOT" add -- "${paths[@]}" || return 1
    # --no-verify: the tests are red by design, so a hook that runs them would refuse the commit.
    git -C "$PROJECT_ROOT" commit -q --no-verify \
        -m "test: acceptance tests${ISSUE_NUMBER:+ for #${ISSUE_NUMBER}} (${ids})" -- "${paths[@]}" || return 1
    local cmd_json args=(lock --manifest "$manifest" --lock "$(acceptance_lock_file)" --root "$PROJECT_ROOT" --test-cmd "$test_cmd")
    cmd_json=$(_acceptance_command_json)
    [[ -n "$cmd_json" ]] && args+=(--command "$cmd_json")
    _acceptance_sw "${args[@]}" || return 1
    cp "$(acceptance_lock_file)" "${ARTIFACTS_DIR}/acceptance-lock.json" 2>/dev/null || true
}

# _acceptance_tree_state — HEAD plus the working-tree status, to detect a writer that edits files.
_acceptance_tree_state() {
    git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "none"
    git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all 2>/dev/null || true
}

# _acceptance_undo_writer BEFORE — undo commits and file changes the writer made with its tools.
# Only paths whose status changed are touched, so earlier uncommitted work is left alone.
_acceptance_undo_writer() {
    local before="$1" head line path
    head=$(printf '%s\n' "$before" | head -1)
    if [[ "$head" != "none" && "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" != "$head" ]]; then
        git -C "$PROJECT_ROOT" reset -q --mixed "$head" || return 1
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -Fx -- "$line" <<< "$before" >/dev/null && continue
        path="${line:3}"
        [[ "$path" == *" -> "* || "$path" == /* || "$path" == *..* ]] && continue
        if [[ "${line:0:2}" == "??" ]]; then
            rm -f -- "${PROJECT_ROOT}/${path}"
        else
            git -C "$PROJECT_ROOT" checkout -q -- "$path" 2>/dev/null || true
        fi
    done < <(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all 2>/dev/null || true)
}

# _acceptance_write_answer PROMPT FILE — one test-writer call; the answer goes to FILE.
_acceptance_write_answer() {
    local prompt="$1" out="$2" model timeout_s
    model="${CLAUDE_MODEL:-${MODEL:-sonnet}}"
    [[ -z "$model" || "$model" == "null" ]] && model="sonnet"
    timeout_s=$(_smart_int "timeouts.tdd_generation" 600 2>/dev/null || echo 600)
    printf '%s' "$prompt" | (cd "$PROJECT_ROOT" && "$SW_AGENT_EXEC" timeout "$timeout_s" claude --print --model "$model") \
        > "$out" 2>/dev/null
}

# acceptance_generate TEST_CMD — write, prove red, commit and lock the acceptance tests.
# Returns 0 when locked or not_testable, 1 when no proven-red tests could be written.
acceptance_generate() {
    local test_cmd="$1" manifest attempts attempt feedback="" requirements cmd_json
    manifest=$(acceptance_manifest_file)
    if acceptance_lock_current; then
        info "Acceptance tests already locked for this branch: reusing them"
        return 0
    fi
    rm -f "$manifest" "$(acceptance_lock_file)" "${ARTIFACTS_DIR}/acceptance-lock.json"
    attempts=$(_smart_int "acceptance.attempts" 3 2>/dev/null || echo 3)
    requirements=$(_acceptance_requirements)
    cmd_json=$(_acceptance_command_json)
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        local answer="${ARTIFACTS_DIR}/acceptance-answer-${attempt}.md" out rc=0
        local before
        info "Acceptance tests: writing (attempt ${attempt}/${attempts})"
        before=$(_acceptance_tree_state)
        if ! _acceptance_write_answer "$(acceptance_prompt "$requirements" "$test_cmd" "$feedback")" "$answer"; then
            _acceptance_undo_writer "$before" || true
            feedback="The test writer call failed or timed out; answer sooner and more briefly."
            continue
        fi
        if [[ "$(_acceptance_tree_state)" != "$before" ]]; then
            _acceptance_undo_writer "$before" || return 1
            feedback="You changed files in the repository. Do not write, edit or commit anything; answer in text only."
            continue
        fi
        out=$(_acceptance_sw materialize --answer "$answer" --manifest "$manifest" --root "$PROJECT_ROOT" 2>&1) || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            feedback="$out"
            _acceptance_discard "$manifest"
            continue
        fi
        if [[ -n "$(jq -r '.not_testable // empty' "$manifest" 2>/dev/null)" ]]; then
            warn "Acceptance tests: not testable: $(jq -r '.not_testable' "$manifest")"
            emit_event "acceptance.not_testable" "issue=${ISSUE_NUMBER:-0}" 2>/dev/null || true
            return 0
        fi
        local args=(verify-red --manifest "$manifest" --root "$PROJECT_ROOT" --test-cmd "$test_cmd")
        [[ -n "$cmd_json" ]] && args+=(--command "$cmd_json")
        out=$(_acceptance_sw "${args[@]}" 2>&1) || rc=$?
        printf '%s\n' "$out" > "${ARTIFACTS_DIR}/acceptance-red.log"
        if [[ "$rc" -eq 0 ]] && _acceptance_commit_and_lock "$manifest" "$test_cmd"; then
            success "Acceptance tests proven red and locked: $(jq -r '[.criteria[].id] | join(", ")' "$manifest")"
            emit_event "acceptance.locked" "issue=${ISSUE_NUMBER:-0}" "attempt=${attempt}" 2>/dev/null || true
            return 0
        fi
        warn "Acceptance tests rejected (attempt ${attempt}): $(printf '%s' "$out" | grep -m1 '^✗' || true)"
        feedback="$(printf '%s' "$out" | head -c 6000)"
        _acceptance_discard "$manifest"
    done
    emit_event "acceptance.failed" "issue=${ISSUE_NUMBER:-0}" "attempts=${attempts}" 2>/dev/null || true
    return 1
}

# acceptance_build_brief — what the builder is told about the locked tests (empty when none).
acceptance_build_brief() {
    local lock
    lock=$(acceptance_lock_file)
    [[ -f "$lock" ]] || return 0
    cat <<BRIEF
ACCEPTANCE TESTS (spec-first, locked): these test files define done. They fail now and must all
pass. They are locked at commit $(jq -r '.commit[0:12]' "$lock"): the test gate restores them byte
for byte before running them, and editing them, deleting or skipping any test, removing
assertions or narrowing test configuration fails the build. Change the implementation, not the tests.
$(jq -r '.tests[] | "- \(.path) (\(.criteria | join(", ")))"' "$lock")
Criteria:
$(jq -r '.criteria[] | "- \(.id): \(.text)"' "$lock")
BRIEF
}

# acceptance_gate TEST_LOG — the build gate. Appends its report to TEST_LOG. 0 = pass.
acceptance_gate() {
    local test_log="$1" lock mode out rc=0 integrity="enforce"
    lock=$(acceptance_lock_file)
    mode=$(acceptance_mode)
    [[ "$mode" == "off" || ! -f "$lock" ]] && return 0
    [[ "$mode" == "warn" ]] && integrity="warn"
    info "Acceptance gate: restoring and running the locked tests"
    out=$(_acceptance_sw verify-green --lock "$lock" --root "$PROJECT_ROOT" --integrity "$integrity" 2>&1) || rc=$?
    printf '%s\n' "$out" > "${ARTIFACTS_DIR}/acceptance-green.log"
    if [[ "$rc" -eq 0 ]]; then
        success "Acceptance tests pass"
        emit_event "acceptance.passed" "issue=${ISSUE_NUMBER:-0}" 2>/dev/null || true
        return 0
    fi
    emit_event "acceptance.gate_failed" "issue=${ISSUE_NUMBER:-0}" "mode=${mode}" 2>/dev/null || true
    if [[ "$mode" == "warn" ]]; then
        warn "Acceptance gate failed (warn mode, not blocking)"
        return 0
    fi
    # The retry loop reads the end of the test log: put the failing output first, the verdicts last.
    {
        printf '%s\n' "$out" | grep -v -E '^(✓|✗|⚠) ' || true
        printf '\nACCEPTANCE GATE FAILED (locked tests; change the implementation, not the tests):\n'
        printf '%s\n' "$out" | grep -E '^(✗|⚠) ' || true
    } > "$test_log"
    error "Acceptance gate failed"
    return 1
}
