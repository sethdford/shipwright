# pr-content.sh — what a pipeline PR contains and how it is titled
# Source from pipeline-stages-delivery.sh. Pure helpers plus one git step (pr_scrub_noise).
#
# Why this exists: of the pipeline's closed PRs, most never merged because the branch
# carried run artifacts (loop logs, state, caches: up to 118k lines), the title or
# summary was the model's analysis text, or the branch conflicted with its base.
[[ -n "${_PR_CONTENT_LOADED:-}" ]] && return 0
_PR_CONTENT_LOADED=1

PR_TITLE_MAX=72

# The ref a PR diff is measured against: the remote base when it exists (CI checkouts
# have no local base branch), else the local one.
pr_base_ref() {
    local branch="${1:-${BASE_BRANCH:-main}}"
    if git rev-parse --verify --quiet "origin/${branch}" >/dev/null 2>&1; then
        echo "origin/${branch}"
    else
        echo "$branch"
    fi
}

# True when a path is pipeline run output, not part of the change.
# .claude/ is run state except the agent config the repo tracks on purpose.
pr_is_noise_path() {
    local p="$1"
    case "$p" in
        .claude/agents/*|.claude/hooks/*|.claude/rules/*|.claude/skills/*) return 1 ;;
        .claude/settings.json|.claude/CLAUDE.md) return 1 ;;
        .claude/*) return 0 ;;
        */progress.md|progress.md|*/error-summary.json|error-summary.json) return 0 ;;
        IMPLEMENTATION_PLAN.md|*/IMPLEMENTATION_PLAN.md) return 0 ;;
    esac
    return 1
}

# True when a path is planning output: kept in the PR but never counts as the change.
pr_is_plan_doc() {
    case "$1" in
        docs/plans/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md) return 0 ;;
    esac
    return 1
}

# Filter a newline list of paths (stdin) down to the ones that are the real change.
pr_real_files() {
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        pr_is_noise_path "$p" && continue
        pr_is_plan_doc "$p" && continue
        case "$p" in .github/*) continue ;; esac
        printf '%s\n' "$p"
    done
}

# Put every noise path back to its merge-base state in one commit, so run artifacts
# never reach the PR. Files stay on disk. Prints the number of paths scrubbed.
pr_scrub_noise() {
    local base_ref="$1" mb p count=0
    mb=$(git merge-base "$base_ref" HEAD 2>/dev/null) || { echo 0; return 0; }
    local paths=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        pr_is_noise_path "$p" && paths+=("$p")
    done < <(git diff --name-only "$mb" HEAD 2>/dev/null || true)
    if [[ ${#paths[@]} -eq 0 ]]; then
        echo 0
        return 0
    fi
    for p in "${paths[@]}"; do
        if git cat-file -e "${mb}:${p}" 2>/dev/null; then
            git checkout "$mb" -- "$p" 2>/dev/null || continue
        else
            git rm --cached --quiet -- "$p" 2>/dev/null || continue
        fi
        count=$((count + 1))
    done
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit --quiet --no-verify -m "chore: drop pipeline run artifacts from the PR" 2>/dev/null || true
    fi
    echo "$count"
}

# True when text reads like model narration or an error, not a title.
pr_is_chatter() {
    local t="$1"
    [[ -z "$t" ]] && return 0
    printf '%s' "$t" | grep >/dev/null -iE \
        '^(I |I'"'"'(ll|ve|m) |Here'"'"'s|Here is|Let me|Sure[,.!]|Okay[,.!]|Based on |Looking at |The (implementation|feature|branch) (is|was|has)|This (feature|PR|change|issue|task) (is|was|has) |(Summary|Analysis|Plan):)' \
        && return 0
    printf '%s' "$t" | grep >/dev/null -iE \
        'already (fully )?(implemented|complete|on main|exists)|Invalid API|API key|authentication_error|rate_limit|CLI error|no useful output|\*\*|^#|```' \
        && return 0
    return 1
}

# Conventional-commit type for a pipeline task type.
pr_type_prefix() {
    case "${1:-}" in
        bug|security|hotfix) echo "fix" ;;
        refactor|architecture|migration) echo "refactor" ;;
        testing) echo "test" ;;
        docs) echo "docs" ;;
        devops) echo "ci" ;;
        *) echo "feat" ;;
    esac
}

# Cut text to max chars at a word boundary, without a trailing ellipsis.
pr_truncate_words() {
    local t="$1" max="${2:-$PR_TITLE_MAX}"
    [[ ${#t} -le $max ]] && { printf '%s' "$t"; return 0; }
    local cut="${t:0:$max}"
    if [[ "${t:$max:1}" != " " && "$cut" == *" "* ]]; then
        cut="${cut% *}"
    fi
    cut="${cut%"${cut##*[![:space:][:punct:]]}"}"
    printf '%s' "$cut"
}

# PR title: "<type>: <issue title> (#N)" from the goal, never from model output.
# Args: goal task_type issue_number
pr_build_title() {
    local goal="$1" task_type="${2:-}" issue="${3:-}"
    local subject
    subject=$(printf '%s' "$goal" | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^Issue #[0-9]+:[[:space:]]*//')
    pr_is_chatter "$subject" && subject=""

    local suffix=""
    if [[ -n "$issue" && "$issue" != "0" && "$subject" != *"#${issue}"* ]]; then
        suffix=" (#${issue})"
    fi
    if [[ -z "$subject" ]]; then
        if [[ -n "$suffix" ]]; then
            printf '%s: resolve #%s' "$(pr_type_prefix "$task_type")" "$issue"
        else
            printf '%s: pipeline changes' "$(pr_type_prefix "$task_type")"
        fi
        return 0
    fi

    local prefix=""
    if ! printf '%s' "$subject" | grep >/dev/null -E '^[a-z]+(\([^)]+\))?!?: '; then
        prefix="$(pr_type_prefix "$task_type"): "
        # Conventional subjects start lower-case unless the first word is an acronym or name.
        if printf '%s' "$subject" | grep >/dev/null -E '^[A-Z][a-z]'; then
            subject="$(printf '%s' "${subject:0:1}" | tr '[:upper:]' '[:lower:]')${subject:1}"
        fi
    fi
    local room=$(( PR_TITLE_MAX - ${#prefix} - ${#suffix} ))
    printf '%s%s%s' "$prefix" "$(pr_truncate_words "$subject" "$room")" "$suffix"
}

# One line saying how the tests ended, from a test log; empty when none is found.
pr_test_summary() {
    local log="$1"
    [[ -s "$log" ]] || return 0
    sed 's/\x1b\[[0-9;]*m//g' "$log" \
        | grep -iE '([0-9]+ (tests? )?(passed|failed|failing|passing))|PASS: *[0-9]+|FAIL: *[0-9]+|Tests?: +[0-9]+' \
        | tail -1 | sed -E 's/^[[:space:]▸✓✗═]+//; s/[[:space:]═]+$//' | cut -c1-200
}

# Markdown list of the changed files with line counts. Args: base_ref [max]
pr_changed_files_md() {
    local base_ref="$1" max="${2:-25}" shown=0 total=0 add del path
    while IFS=$'\t' read -r add del path; do
        [[ -z "$path" ]] && continue
        pr_is_noise_path "$path" && continue
        total=$((total + 1))
        if [[ $shown -lt $max ]]; then
            printf -- '- `%s` (+%s −%s)\n' "$path" "$add" "$del"
            shown=$((shown + 1))
        fi
    done < <(git diff --numstat "${base_ref}...HEAD" 2>/dev/null || true)
    if [[ $total -gt $shown ]]; then
        printf -- '- …and %s more\n' "$((total - shown))"
    fi
}
