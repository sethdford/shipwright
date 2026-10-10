# fleet-patterns.sh — Fleet-wide failure pattern store (shared across repos)
#
# A failure learned in one fleet repo is stored under a normalized, repo-
# independent signature so daemon triage in another repo can surface the
# known fix before starting a fresh build loop.
#
# Enabled only when SHIPWRIGHT_FLEET_PATTERNS_FILE is set (sw-fleet.sh exports
# it on every daemon it launches). Every public function exits 0 and never
# aborts the caller under set -e; errors go to stderr with empty stdout.
# The one exception is fleet_patterns_enabled, which is a predicate.
#
# Layers:
#   signature  fleet_error_type, fleet_normalize_error, fleet_pattern_signature
#   store      fleet_pattern_record, fleet_pattern_update_fix,
#              fleet_pattern_record_outcome, fleet_pattern_lookup,
#              fleet_pattern_prune, fleet_patterns_list
#   triage     fleet_triage_known_fix
[[ -n "${_FLEET_PATTERNS_LOADED:-}" ]] && return 0
_FLEET_PATTERNS_LOADED=1

_FLEET_PATTERNS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! type compute_md5 >/dev/null 2>&1; then
    # shellcheck source=compat.sh
    source "$_FLEET_PATTERNS_LIB_DIR/compat.sh"
fi

FLEET_PATTERNS_SCHEMA_VERSION=1
# Caps keep the store bounded (~1 MB) at fleet scale. Env-overridable for tests.
FLEET_PATTERNS_MAX="${FLEET_PATTERNS_MAX:-500}"
FLEET_PATTERNS_MAX_REPOS="${FLEET_PATTERNS_MAX_REPOS:-20}"
FLEET_PATTERNS_LOCK_TIMEOUT="${FLEET_PATTERNS_LOCK_TIMEOUT:-5}"
FLEET_PATTERNS_STALE_LOCK_SECS="${FLEET_PATTERNS_STALE_LOCK_SECS:-30}"
# A fix is demoted (not surfaced) once it has been tried this many times...
FLEET_PATTERNS_DEMOTE_MIN_APPLIED="${FLEET_PATTERNS_DEMOTE_MIN_APPLIED:-3}"
# ...and resolved the failure in fewer than this percent of attempts.
FLEET_PATTERNS_DEMOTE_PCT="${FLEET_PATTERNS_DEMOTE_PCT:-30}"

# Lines that count as an error line. Shared by normalization and triage so
# both sides of a cross-repo match pick the same line.
_FLEET_ERROR_LINE_RE='error|fail|cannot|not found|undefined|exception|missing|denied|timed out|timeout'

_fleet_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_fleet_warn() {
    if type warn >/dev/null 2>&1; then
        warn "$*" >&2
    else
        echo "WARN: $*" >&2
    fi
}

_fleet_emit() {
    if type emit_event >/dev/null 2>&1; then
        emit_event "$@" 2>/dev/null || true
    fi
}

fleet_patterns_enabled() {
    [[ -n "${SHIPWRIGHT_FLEET_PATTERNS_FILE:-}" ]]
}

fleet_patterns_file() {
    echo "${SHIPWRIGHT_FLEET_PATTERNS_FILE:-${HOME}/.shipwright/fleet-patterns.json}"
}

# fleet_repo_id [dir] — stable repo identity: owner/repo from origin, else dir name
fleet_repo_id() {
    local dir="${1:-.}"
    local url=""
    url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "$url" ]]; then
        url="${url%.git}"
        url="${url#*://}"
        url="${url#*@}"
        url="${url//://}"
        # keep the last two path segments: owner/repo
        echo "$url" | awk -F/ '{ if (NF >= 2) print $(NF-1) "/" $NF; else print $NF }'
        return 0
    fi
    local top=""
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
    [[ -z "$top" ]] && top=$(cd "$dir" 2>/dev/null && pwd || echo "$dir")
    basename "$top"
}

# ─── Signature layer ──────────────────────────────────────────────────────

# fleet_error_type <text> — coarse class; included in the signature so the
# same normalized text under different failure classes never collides.
fleet_error_type() {
    local text
    text=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$text" | grep -qE 'unauthori[sz]ed|authentication|not logged in|invalid.*token|permission denied|401 |403 '; then
        echo "auth"
    elif printf '%s' "$text" | grep -qE 'timed out|timeout|deadline exceeded'; then
        echo "timeout"
    elif printf '%s' "$text" | grep -qE 'cannot find module|module not found|no module named|could not resolve|unresolved import|package .* not found|npm err|err_module|dependency'; then
        echo "dependency"
    elif printf '%s' "$text" | grep -qE 'eslint|shellcheck|lint|prettier|sc[0-9]{4}'; then
        echo "lint_error"
    elif printf '%s' "$text" | grep -qE 'assert|(^|[^a-z])expected|tests? failed|fail:|(^| )fail( |$)|✗|test.*fail|failing'; then
        echo "test_failure"
    elif printf '%s' "$text" | grep -qE 'syntax error|compil|build failed|undefined reference|cannot|error'; then
        echo "build_error"
    else
        echo "unknown"
    fi
}

# fleet_normalize_error <text> — the first error line, with everything that
# differs between repos/runs removed. "" when there is no error line.
#   paths → basename, :line:col → :n, timestamps/durations → t,
#   hex runs (7+) → h, numbers (3+ digits) → n, lowercase, collapsed spaces.
# Identifiers and module names are kept so distinct failures stay distinct.
fleet_normalize_error() {
    local text="${1:-}"
    [[ -z "$text" ]] && return 0
    local esc
    esc=$(printf '\033')
    local line
    line=$(printf '%s\n' "$text" \
        | sed "s/${esc}\[[0-9;]*[A-Za-z]//g" \
        | grep -iE "$_FLEET_ERROR_LINE_RE" 2>/dev/null \
        | head -1 || true)
    [[ -z "$line" ]] && return 0
    printf '%s\n' "$line" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E \
            -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[t ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?z?/t/g' \
            -e 's/[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/t/g' \
            -e 's#[^[:space:]:"'"'"'()=,]*/##g' \
            -e 's/:[0-9]+(:[0-9]+)?/:n/g' \
            -e 's/[0-9a-f]{7,}/h/g' \
            -e 's/[0-9]+(\.[0-9]+)?(ms|s)([^a-z]|$)/t\3/g' \
            -e 's/[0-9]{3,}/n/g' \
        | tr -s '[:space:]' ' ' \
        | sed -E 's/^ +//; s/ +$//' \
        | cut -c1-200
}

# fleet_pattern_signature <text> [error_type] — "<error_type>:<16 hex>" or ""
fleet_pattern_signature() {
    local text="${1:-}" etype="${2:-}"
    local norm
    norm=$(fleet_normalize_error "$text")
    [[ -z "$norm" ]] && return 0
    [[ -z "$etype" ]] && etype=$(fleet_error_type "$norm")
    local hash
    hash=$(compute_md5 --string "${etype}|${norm}" 2>/dev/null || true)
    hash=$(printf '%s' "$hash" | tr -cd '0-9a-f')
    [[ ${#hash} -lt 16 ]] && return 0
    echo "${etype}:${hash:0:16}"
}

# ─── Store layer ──────────────────────────────────────────────────────────

_fleet_patterns_valid() {
    local file="$1"
    [[ -s "$file" ]] && jq -e '.patterns | type == "object"' "$file" >/dev/null 2>&1
}

# Must run under the lock. Creates the store, or recovers a corrupt one.
_fleet_patterns_init() {
    local file="$1"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    if [[ -f "$file" ]] && ! _fleet_patterns_valid "$file"; then
        local backup
        backup="${file}.corrupt.$(date +%s)"
        mv "$file" "$backup" 2>/dev/null || rm -f "$file"
        _fleet_warn "Fleet pattern store was corrupt — backed up to ${backup}"
        _fleet_emit "fleet.patterns_corrupt" "backup=${backup}"
    fi
    if [[ ! -f "$file" ]]; then
        local tmp
        tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
        printf '{"version":%s,"patterns":{}}\n' "$FLEET_PATTERNS_SCHEMA_VERSION" > "$tmp" \
            && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    fi
    return 0
}

# _fleet_patterns_apply <file> <jq args...> — atomic read-modify-write.
# Must run under the lock.
_fleet_patterns_apply() {
    local file="$1"
    shift
    _fleet_patterns_init "$file" || return 1
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if jq "$@" "$file" > "$tmp" 2>/dev/null && _fleet_patterns_valid "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# _fleet_patterns_locked <cmd...> — run cmd holding the store lock.
# flock when available; mkdir lock dir (macOS) otherwise, with stale-lock break.
# On timeout the write is skipped: losing one count beats blocking a daemon.
_fleet_patterns_locked() {
    local file
    file=$(fleet_patterns_file)
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1

    if command -v flock >/dev/null 2>&1 && [[ -z "${FLEET_PATTERNS_FORCE_MKDIR_LOCK:-}" ]]; then
        (
            flock -w "$FLEET_PATTERNS_LOCK_TIMEOUT" 200 2>/dev/null || {
                _fleet_warn "Fleet pattern lock timeout — skipping write"
                exit 1
            }
            "$@"
        ) 200>"${file}.lock"
        return $?
    fi

    local lock_dir="${file}.lock.d"
    local waited=0 max_wait=$((FLEET_PATTERNS_LOCK_TIMEOUT * 10))
    while ! mkdir "$lock_dir" 2>/dev/null; do
        local mtime age
        mtime=$(file_mtime "$lock_dir" 2>/dev/null || echo 0)
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age=$(( $(date +%s) - mtime ))
        if [[ "$mtime" -gt 0 && "$age" -gt "$FLEET_PATTERNS_STALE_LOCK_SECS" ]]; then
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
        waited=$((waited + 1))
        if [[ "$waited" -ge "$max_wait" ]]; then
            _fleet_warn "Fleet pattern lock timeout — skipping write"
            return 1
        fi
        sleep 0.1
    done
    local rc=0
    "$@" || rc=$?
    rmdir "$lock_dir" 2>/dev/null || true
    return "$rc"
}

# fleet_pattern_record <sig> <error_type> <sample> <repo_id> <stage>
# Upsert: seen_count++, repos ∪= repo_id. Applies both caps in the same write.
fleet_pattern_record() {
    fleet_patterns_enabled || return 0
    local sig="${1:-}" etype="${2:-unknown}" sample="${3:-}" repo="${4:-unknown}" stage="${5:-unknown}"
    [[ -z "$sig" ]] && return 0
    # The signature prefix is authoritative, so the stored type always agrees with it.
    [[ "$sig" == *:* ]] && etype="${sig%%:*}"
    # Only the normalized text is stored: no absolute paths leave the repo.
    local fp
    fp=$(fleet_normalize_error "$sample")
    local file
    file=$(fleet_patterns_file)
    _fleet_patterns_locked _fleet_patterns_apply "$file" \
        --arg s "$sig" --arg t "$etype" --arg fp "$fp" \
        --arg sample "${fp:0:200}" --arg r "$repo" --arg stage "$stage" \
        --arg ts "$(_fleet_now)" \
        --argjson maxp "$FLEET_PATTERNS_MAX" --argjson maxr "$FLEET_PATTERNS_MAX_REPOS" \
        '.version = (.version // 1)
         | .patterns[$s] = ((.patterns[$s] // {
               signature: $s, error_type: $t, fingerprint: $fp, sample: $sample,
               stage: $stage, root_cause: "", fix: "", category: "",
               fix_source_repo: "", repos: [], seen_count: 0,
               fix_applied: 0, fix_resolved: 0, first_seen: $ts })
             | .seen_count += 1 | .last_seen = $ts | .stage = $stage
             | .repos = (((.repos // []) - [$r]) + [$r] | .[-$maxr:]))
         | if (.patterns | length) > $maxp
           then .patterns = (.patterns | to_entries | sort_by(.value.last_seen) | .[-$maxp:] | from_entries)
           else . end' \
        || { _fleet_warn "Fleet pattern record failed for ${sig}"; return 0; }
    _fleet_emit "fleet.pattern_recorded" "signature=${sig}" "repo=${repo}" "stage=${stage}"
    return 0
}

# fleet_pattern_update_fix <sig> <root_cause> <fix> <category> <repo_id>
# No-op when the signature is unknown or the fix is empty. A changed fix
# resets its outcome counters — the old track record belongs to the old fix.
fleet_pattern_update_fix() {
    fleet_patterns_enabled || return 0
    local sig="${1:-}" root_cause="${2:-}" fix="${3:-}" category="${4:-}" repo="${5:-unknown}"
    [[ -z "$sig" || -z "$fix" ]] && return 0
    local file
    file=$(fleet_patterns_file)
    _fleet_patterns_locked _fleet_patterns_apply "$file" \
        --arg s "$sig" --arg rc "$root_cause" --arg fix "$fix" --arg cat "$category" \
        --arg r "$repo" --arg ts "$(_fleet_now)" \
        'if .patterns[$s] then
             .patterns[$s] |= (
                 (if .fix != $fix then .fix_applied = 0 | .fix_resolved = 0 else . end)
                 | .root_cause = $rc | .fix = $fix | .category = $cat
                 | .fix_source_repo = $r | .fix_updated = $ts)
         else . end' \
        || { _fleet_warn "Fleet pattern fix update failed for ${sig}"; return 0; }
    _fleet_emit "fleet.pattern_fix_learned" "signature=${sig}" "repo=${repo}"
    return 0
}

# fleet_pattern_record_outcome <sig> <resolved:true|false>
fleet_pattern_record_outcome() {
    fleet_patterns_enabled || return 0
    local sig="${1:-}" resolved="${2:-false}"
    [[ -z "$sig" ]] && return 0
    local file
    file=$(fleet_patterns_file)
    _fleet_patterns_locked _fleet_patterns_apply "$file" \
        --arg s "$sig" --arg res "$resolved" \
        'if .patterns[$s] then
             .patterns[$s] |= (.fix_applied += 1
                 | .fix_resolved += (if $res == "true" then 1 else 0 end))
         else . end' \
        || _fleet_warn "Fleet pattern outcome update failed for ${sig}"
    return 0
}

# fleet_pattern_lookup <sig> — the pattern JSON, only when it has a fix and
# that fix has not been demoted for repeatedly failing. Lock-free read.
fleet_pattern_lookup() {
    fleet_patterns_enabled || return 0
    local sig="${1:-}"
    [[ -z "$sig" ]] && return 0
    local file
    file=$(fleet_patterns_file)
    _fleet_patterns_valid "$file" || return 0
    jq -c --arg s "$sig" \
        --argjson mina "$FLEET_PATTERNS_DEMOTE_MIN_APPLIED" --argjson pct "$FLEET_PATTERNS_DEMOTE_PCT" \
        '.patterns[$s] // empty
         | select((.fix // "") != "")
         | select(((.fix_applied // 0) >= $mina
                   and ((.fix_resolved // 0) * 100 / .fix_applied) < $pct) | not)' \
        "$file" 2>/dev/null || true
}

# fleet_patterns_list — one compact JSON object per line, most recent first
fleet_patterns_list() {
    local file
    file=$(fleet_patterns_file)
    _fleet_patterns_valid "$file" || return 0
    jq -c '.patterns | to_entries | map(.value) | sort_by(.last_seen) | reverse | .[]' \
        "$file" 2>/dev/null || true
}

# fleet_pattern_prune <older_than_days> — prints the number removed
fleet_pattern_prune() {
    local days="${1:-90}"
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
        _fleet_warn "prune: days must be a non-negative integer"
        echo 0
        return 0
    fi
    local file
    file=$(fleet_patterns_file)
    if ! _fleet_patterns_valid "$file"; then
        echo 0
        return 0
    fi
    local before after cutoff
    before=$(jq '.patterns | length' "$file" 2>/dev/null || echo 0)
    cutoff=$(( $(date +%s) - days * 86400 ))
    _fleet_patterns_locked _fleet_patterns_apply "$file" --argjson cut "$cutoff" \
        '.patterns |= with_entries(select(((.value.last_seen // "1970-01-01T00:00:00Z")
             | (try fromdateiso8601 catch 0)) >= $cut))' \
        || { echo 0; return 0; }
    after=$(jq '.patterns | length' "$file" 2>/dev/null || echo "$before")
    echo $((before - after))
}

# ─── Triage layer ─────────────────────────────────────────────────────────

# fleet_triage_known_fix <issue_num> <issue_text> <prior_log|""> <out_dir>
# Looks up every error line, newest log errors first (a retry should match
# the error that actually happened), then the issue text. On the first hit
# writes <out_dir>/.claude/fleet-known-fix.json atomically, emits
# fleet.pattern_hit and prints the hit JSON.
fleet_triage_known_fix() {
    fleet_patterns_enabled || return 0
    local issue_num="${1:-}" issue_text="${2:-}" prior_log="${3:-}" out_dir="${4:-}"
    _fleet_patterns_valid "$(fleet_patterns_file)" || return 0

    local candidates=""
    if [[ -n "$prior_log" && -f "$prior_log" ]]; then
        candidates=$(tail -200 "$prior_log" 2>/dev/null \
            | grep -iE "$_FLEET_ERROR_LINE_RE" 2>/dev/null \
            | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' || true)
    fi
    local from_text
    from_text=$(printf '%s\n' "$issue_text" | grep -iE "$_FLEET_ERROR_LINE_RE" 2>/dev/null || true)
    if [[ -n "$from_text" ]]; then
        candidates="${candidates:+${candidates}
}${from_text}"
    fi
    [[ -z "$candidates" ]] && return 0

    local line sig hit="" matched="" checked=0 seen=" "
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        checked=$((checked + 1))
        [[ "$checked" -gt 50 ]] && break
        sig=$(fleet_pattern_signature "$line")
        [[ -z "$sig" ]] && continue
        case "$seen" in *" $sig "*) continue ;; esac
        seen="${seen}${sig} "
        hit=$(fleet_pattern_lookup "$sig")
        if [[ -n "$hit" ]]; then
            matched="$line"
            break
        fi
    done <<< "$candidates"
    [[ -z "$hit" ]] && return 0

    local result
    result=$(printf '%s' "$hit" | jq -c --arg issue "$issue_num" --arg line "${matched:0:300}" \
        --arg ts "$(_fleet_now)" --arg fleet "${SHIPWRIGHT_FLEET_NAME:-}" \
        '{issue: $issue, matched_line: $line, matched_at: $ts, fleet: $fleet,
          signature, error_type, root_cause, fix, category, fix_source_repo,
          repos, seen_count, fix_applied, fix_resolved}' 2>/dev/null || true)
    [[ -z "$result" ]] && return 0

    if [[ -n "$out_dir" && -d "$out_dir" ]]; then
        mkdir -p "$out_dir/.claude" 2>/dev/null || true
        local dest="$out_dir/.claude/fleet-known-fix.json" tmp
        tmp=$(mktemp "${dest}.tmp.XXXXXX" 2>/dev/null) || tmp=""
        if [[ -n "$tmp" ]]; then
            printf '%s\n' "$result" | jq '.' > "$tmp" 2>/dev/null && mv "$tmp" "$dest" || rm -f "$tmp"
        fi
    fi

    _fleet_emit "fleet.pattern_hit" "issue=${issue_num}" \
        "signature=$(printf '%s' "$result" | jq -r '.signature' 2>/dev/null || true)" \
        "source_repo=$(printf '%s' "$result" | jq -r '.fix_source_repo' 2>/dev/null || true)"
    printf '%s\n' "$result"
    return 0
}
