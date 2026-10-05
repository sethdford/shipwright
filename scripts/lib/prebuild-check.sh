# prebuild-check.sh — Pre-build toolchain/dependency check for the target project
# Runs during intake, before any GitHub or git side effects, so a missing runtime
# or unmet engine requirement fails in seconds instead of after a paid build loop.
#
# Scope: the TARGET project's toolchain only. Shipwright's own prerequisites
# (git, jq, gh, claude) are covered by preflight_checks() in pipeline-util.sh.
#
# Public entry point:
#   prebuild_check <lang> <root>   → 0 proceed, 1 hard fail (enforce + critical finding)
# Sets PREBUILD_STATUS (pass|warn|fail|skipped) and PREBUILD_CRITICAL_IDS for the caller.
# Config (via _config_get): pipeline.prebuild.mode (off|warn|enforce),
#   pipeline.prebuild.check_timeout_seconds, pipeline.prebuild.deps_check
[[ -n "${_PREBUILD_CHECK_LOADED:-}" ]] && return 0
_PREBUILD_CHECK_LOADED=1

ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"

PREBUILD_STATUS=""
PREBUILD_CRITICAL_IDS=""
_PBC_FINDINGS_FILE=""

# ─── Primitives ──────────────────────────────────────────────────────────────

# _pbc_finding <id> <critical|warning|info> <message> <remedy>
_pbc_finding() {
    [[ -z "$_PBC_FINDINGS_FILE" ]] && return 0
    jq -cn --arg id "$1" --arg severity "$2" --arg message "$3" --arg remedy "$4" \
        '{id: $id, severity: $severity, message: $message, remedy: $remedy}' \
        >> "$_PBC_FINDINGS_FILE" 2>/dev/null || true
}

# _pbc_cfg <dotpath> <default> — config chain when config.sh is loaded, else env/default
_pbc_cfg() {
    if type _config_get >/dev/null 2>&1; then
        _config_get "$1" "$2"
        return 0
    fi
    local env_name
    env_name="SHIPWRIGHT_$(echo "$1" | tr '[:lower:].' '[:upper:]_')"
    echo "${!env_name:-$2}"
}

# _pbc_has_timeout — is a real timeout binary available? (_timeout silently runs unbounded otherwise)
_pbc_has_timeout() {
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

# _pbc_run_bounded <secs> <cmd...> — exit 124 on timeout
_pbc_run_bounded() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        return 124
    fi
}

# _pbc_version_parts "v20.11.1" → "20 11 1" (missing parts default to 0)
_pbc_version_parts() {
    local v="${1#v}"
    v="${v%%[-+]*}"
    local major minor patch
    major=$(echo "$v" | cut -d. -f1)
    minor=$(echo "$v" | cut -s -d. -f2)
    patch=$(echo "$v" | cut -s -d. -f3)
    echo "${major:-0} ${minor:-0} ${patch:-0}"
}

# _pbc_version_ge <a> <b> — 0 when a >= b
_pbc_version_ge() {
    local a1 a2 a3 b1 b2 b3
    read -r a1 a2 a3 <<< "$(_pbc_version_parts "$1")"
    read -r b1 b2 b3 <<< "$(_pbc_version_parts "$2")"
    [[ "$a1" -gt "$b1" ]] && return 0
    [[ "$a1" -lt "$b1" ]] && return 1
    [[ "$a2" -gt "$b2" ]] && return 0
    [[ "$a2" -lt "$b2" ]] && return 1
    [[ "$a3" -ge "$b3" ]]
}

# _pbc_clause_satisfies <installed> <clause> — 0 yes, 1 no, 2 unparseable
_pbc_clause_satisfies() {
    local installed="$1" clause="$2"
    local num='[0-9]+'
    local i1 i2 i3 c1 c2 c3 body
    read -r i1 i2 i3 <<< "$(_pbc_version_parts "$installed")"

    case "$clause" in
        ">="*)
            body="${clause#>=}"
            [[ "$body" =~ ^v?$num(\.$num){0,2}$ ]] || return 2
            _pbc_version_ge "$installed" "$body" && return 0
            return 1 ;;
        "^"*)
            body="${clause#^}"
            [[ "$body" =~ ^v?$num(\.$num){0,2}$ ]] || return 2
            read -r c1 c2 c3 <<< "$(_pbc_version_parts "$body")"
            [[ "$i1" -eq "$c1" ]] && _pbc_version_ge "$installed" "$body" && return 0
            return 1 ;;
        "~"*)
            body="${clause#\~}"
            [[ "$body" =~ ^v?$num\.$num(\.$num)?$ ]] || return 2
            read -r c1 c2 c3 <<< "$(_pbc_version_parts "$body")"
            [[ "$i1" -eq "$c1" && "$i2" -eq "$c2" ]] && _pbc_version_ge "$installed" "$body" && return 0
            return 1 ;;
    esac

    # Plain or x-range: "20", "v20", "20.x", "20.11", "20.11.x", "20.11.1"
    [[ "$clause" =~ ^v?$num(\.($num|x|X|\*)){0,2}$ ]] || return 2
    body="${clause#v}"
    local part idx=1 have
    for part in $(echo "$body" | tr '.' ' '); do
        case "$part" in x|X|\*) return 0 ;; esac
        case "$idx" in 1) have="$i1" ;; 2) have="$i2" ;; *) have="$i3" ;; esac
        [[ "$part" -eq "$have" ]] || return 1
        idx=$((idx + 1))
    done
    return 0
}

# _pbc_semver_satisfies <installed X.Y.Z> <range> — 0 satisfied, 1 not, 2 unparseable
# Supported: >=X[.Y[.Z]], ^X[.Y[.Z]], ~X.Y[.Z], X, X.x, X.Y.x, X.Y.Z and "||" unions.
_pbc_semver_satisfies() {
    local installed="$1" range="$2"
    [[ "$(_pbc_version_parts "$installed")" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || return 2
    local saw_unparseable=false clause rc
    local rest="$range"
    while :; do
        clause="${rest%%||*}"
        # trim whitespace
        clause="$(echo "$clause" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ -z "$clause" ]]; then
            saw_unparseable=true
        else
            rc=0
            _pbc_clause_satisfies "$installed" "$clause" || rc=$?
            [[ "$rc" -eq 0 ]] && return 0
            [[ "$rc" -eq 2 ]] && saw_unparseable=true
        fi
        [[ "$rest" == *"||"* ]] || break
        rest="${rest#*||}"
    done
    [[ "$saw_unparseable" == "true" ]] && return 2
    return 1
}

# ─── Language checkers ───────────────────────────────────────────────────────

# _pbc_node_engine_requirement <root> — echoes "source<TAB>range" or nothing
_pbc_node_engine_requirement() {
    local root="$1" req=""
    if [[ -f "$root/package.json" ]]; then
        req=$(jq -r '.engines.node // empty | strings' "$root/package.json" 2>/dev/null || true)
        [[ -n "$req" ]] && { printf 'package.json engines.node\t%s\n' "$req"; return 0; }
    fi
    local f
    for f in .nvmrc .node-version; do
        if [[ -f "$root/$f" ]]; then
            req=$(head -1 "$root/$f" 2>/dev/null | tr -d '[:space:]' || true)
            [[ -n "$req" ]] && { printf '%s\t%s\n' "$f" "$req"; return 0; }
        fi
    done
    return 0
}

_pbc_check_node_engine() {
    local root="$1" node_version="$2"
    local line src range rc=0
    line=$(_pbc_node_engine_requirement "$root")
    [[ -z "$line" ]] && return 0
    src="${line%%	*}"
    range="${line#*	}"
    _pbc_semver_satisfies "$node_version" "$range" || rc=$?
    case "$rc" in
        1) _pbc_finding "engine_mismatch" "critical" \
               "Node $node_version does not satisfy $src \"$range\"" \
               "nvm install '$range' (or see https://nodejs.org/en/download)" ;;
        2) _pbc_finding "engine_unparseable" "info" \
               "Could not evaluate $src \"$range\" against Node $node_version" \
               "Verify manually: node --version" ;;
    esac
    return 0
}

_pbc_check_node_deps() {
    local root="$1" pm="$2" timeout_secs="$3" deps_check="$4"
    local lockfile=""
    case "$pm" in
        pnpm) lockfile="pnpm-lock.yaml" ;;
        bun)  lockfile="bun.lockb" ;;
        yarn) lockfile="yarn.lock" ;;
        *)    [[ -f "$root/package-lock.json" ]] && lockfile="package-lock.json"
              [[ -z "$lockfile" && -f "$root/npm-shrinkwrap.json" ]] && lockfile="npm-shrinkwrap.json" ;;
    esac
    local install_cmd="$pm install"
    [[ "$pm" == "npm" && -n "$lockfile" ]] && install_cmd="npm ci"

    if [[ -z "$lockfile" ]]; then
        _pbc_finding "lockfile_missing" "info" "package.json has no lockfile; installs are not reproducible" \
            "$pm install"
    fi
    if [[ ! -d "$root/node_modules" ]]; then
        _pbc_finding "deps_not_installed" "warning" "node_modules is missing; dependencies are not installed" \
            "(cd '$root' && $install_cmd)"
        return 0
    fi
    [[ "$deps_check" == "true" && "$pm" == "npm" ]] || return 0
    command -v npm >/dev/null 2>&1 || return 0
    if ! _pbc_has_timeout; then
        _pbc_finding "check_timeout" "info" "No timeout binary available; dependency scan skipped" \
            "Install coreutils for timeout/gtimeout"
        return 0
    fi
    local out rc=0
    out=$(cd "$root" && _pbc_run_bounded "$timeout_secs" npm ls --depth=0 --json 2>/dev/null) || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        _pbc_finding "check_timeout" "info" "npm ls exceeded ${timeout_secs}s; dependency scan skipped" \
            "Run manually: npm ls --depth=0"
        return 0
    fi
    # npm ls exits non-zero for harmless peer warnings — trust .problems, not the exit code
    local problems
    problems=$(echo "$out" | jq -r '(.problems // []) | length' 2>/dev/null || echo 0)
    if [[ "${problems:-0}" =~ ^[0-9]+$ ]] && [[ "$problems" -gt 0 ]]; then
        local first
        first=$(echo "$out" | jq -r '.problems[0] // ""' 2>/dev/null || true)
        _pbc_finding "deps_inconsistent" "warning" \
            "npm ls reports $problems problem(s): ${first:0:200}" "(cd '$root' && $install_cmd)"
    fi
    return 0
}

_pbc_check_node() {
    local root="$1" timeout_secs="$2" deps_check="$3"
    if ! command -v node >/dev/null 2>&1; then
        _pbc_finding "runtime_missing" "critical" "Node.js runtime (node) not found on PATH" \
            "Install Node.js: https://nodejs.org/en/download"
        return 0
    fi
    local node_version
    node_version=$(node --version 2>/dev/null | head -1 || true)
    node_version="${node_version#v}"
    if [[ -n "$node_version" ]]; then
        _pbc_check_node_engine "$root" "$node_version"
    fi

    local pm="npm"
    if type _detect_package_manager >/dev/null 2>&1; then
        pm=$(_detect_package_manager "$root")
    fi
    if ! command -v "$pm" >/dev/null 2>&1; then
        local remedy="npm install -g $pm"
        [[ "$pm" == "pnpm" || "$pm" == "yarn" ]] && remedy="corepack enable $pm"
        [[ "$pm" == "bun" ]] && remedy="curl -fsSL https://bun.sh/install | bash"
        [[ "$pm" == "npm" ]] && remedy="Install Node.js (bundles npm): https://nodejs.org/en/download"
        _pbc_finding "pkg_manager_missing" "critical" "Lockfile requires $pm, but $pm is not on PATH" "$remedy"
        return 0
    fi
    [[ -f "$root/package.json" ]] || return 0
    _pbc_check_node_deps "$root" "$pm" "$timeout_secs" "$deps_check"
}

# _pbc_require_bin <bin> <label> <remedy> [id] — critical finding when bin is absent
_pbc_require_bin() {
    command -v "$1" >/dev/null 2>&1 && return 0
    _pbc_finding "${4:-runtime_missing}" "critical" "$2 ($1) not found on PATH" "$3"
}

_pbc_check_generic() {
    local lang="$1" root="$2"
    case "$lang" in
        rust)   _pbc_require_bin cargo "Rust toolchain" "curl --proto '=https' -sSf https://sh.rustup.rs | sh" ;;
        go)     _pbc_require_bin go "Go toolchain" "Install Go: https://go.dev/dl/" ;;
        python)
            if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
                _pbc_finding "runtime_missing" "critical" "Python runtime (python3) not found on PATH" \
                    "Install Python: https://www.python.org/downloads/"
            fi ;;
        ruby)
            _pbc_require_bin ruby "Ruby runtime" "Install Ruby: https://www.ruby-lang.org/en/downloads/"
            if [[ -f "$root/Gemfile" ]]; then
                _pbc_require_bin bundle "Bundler" "gem install bundler" "pkg_manager_missing"
            fi ;;
        java)
            _pbc_require_bin java "Java runtime" "Install a JDK: https://adoptium.net/"
            if [[ -f "$root/pom.xml" && ! -x "$root/mvnw" ]]; then
                _pbc_require_bin mvn "Maven" "Install Maven: https://maven.apache.org/download.cgi" "pkg_manager_missing"
            fi
            if [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]] && [[ ! -x "$root/gradlew" ]]; then
                _pbc_require_bin gradle "Gradle" "Install Gradle: https://gradle.org/install/" "pkg_manager_missing"
            fi ;;
        *) : ;;
    esac
    return 0
}

# ─── Orchestrator ────────────────────────────────────────────────────────────

# _pbc_write_artifact <json> — atomic tmp+mv; fail-open
_pbc_write_artifact() {
    local json="$1"
    mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || return 1
    local tmp
    tmp=$(mktemp "$ARTIFACTS_DIR/.prebuild-check.XXXXXX" 2>/dev/null) || return 1
    if echo "$json" > "$tmp" 2>/dev/null && mv "$tmp" "$ARTIFACTS_DIR/prebuild-check.json" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# _pbc_report <findings-json-array> — one line per finding
_pbc_report() {
    local line sev msg remedy
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        sev=$(echo "$line" | jq -r '.severity')
        msg=$(echo "$line" | jq -r '.message')
        remedy=$(echo "$line" | jq -r '.remedy')
        case "$sev" in
            critical) error "Prebuild: $msg — fix: $remedy" ;;
            warning)  warn "Prebuild: $msg — fix: $remedy" ;;
            *)        info "Prebuild: $msg" ;;
        esac
    done < <(echo "$1" | jq -c '.[]' 2>/dev/null || true)
}

prebuild_check() {
    local lang="${1:-unknown}" root="${2:-${PROJECT_ROOT:-.}}"
    PREBUILD_STATUS="skipped"
    PREBUILD_CRITICAL_IDS=""

    local mode timeout_secs deps_check
    mode=$(_pbc_cfg "pipeline.prebuild.mode" "enforce")
    case "$mode" in off|warn|enforce) ;; *) mode="enforce" ;; esac
    [[ "$mode" == "off" ]] && return 0
    timeout_secs=$(_pbc_cfg "pipeline.prebuild.check_timeout_seconds" "5")
    [[ "$timeout_secs" =~ ^[0-9]+$ && "$timeout_secs" -gt 0 ]] || timeout_secs=5
    deps_check=$(_pbc_cfg "pipeline.prebuild.deps_check" "true")

    local start_s
    start_s=$(date +%s)
    _PBC_FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/sw-prebuild.XXXXXX" 2>/dev/null) || {
        warn "Prebuild check: could not create temp file — skipping"
        _PBC_FINDINGS_FILE=""
        return 0
    }

    case "$lang" in
        typescript|nodejs|react|nextjs) _pbc_check_node "$root" "$timeout_secs" "$deps_check" ;;
        *)                              _pbc_check_generic "$lang" "$root" ;;
    esac

    local findings
    findings=$(jq -s '.' "$_PBC_FINDINGS_FILE" 2>/dev/null || echo "[]")
    rm -f "$_PBC_FINDINGS_FILE" 2>/dev/null || true
    _PBC_FINDINGS_FILE=""
    [[ -z "$findings" ]] && findings="[]"

    local criticals warnings infos
    criticals=$(echo "$findings" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo 0)
    warnings=$(echo "$findings" | jq '[.[] | select(.severity == "warning")] | length' 2>/dev/null || echo 0)
    infos=$(echo "$findings" | jq '[.[] | select(.severity == "info")] | length' 2>/dev/null || echo 0)
    PREBUILD_CRITICAL_IDS=$(echo "$findings" | jq -r '[.[] | select(.severity == "critical") | .id] | unique | join(",")' 2>/dev/null || true)

    local status="pass" rc=0
    if [[ "${criticals:-0}" -gt 0 && "$mode" == "enforce" ]]; then
        status="fail"; rc=1
    elif [[ "${criticals:-0}" -gt 0 || "${warnings:-0}" -gt 0 ]]; then
        status="warn"
    fi
    PREBUILD_STATUS="$status"
    local duration_ms=$(( ($(date +%s) - start_s) * 1000 ))

    local result
    result=$(jq -n --arg mode "$mode" --arg lang "$lang" --arg status "$status" \
        --argjson duration "$duration_ms" --argjson findings "$findings" \
        '{version: 1, mode: $mode, language: $lang, status: $status, duration_ms: $duration, findings: $findings}' \
        2>/dev/null || true)
    if [[ -z "$result" ]] || ! _pbc_write_artifact "$result"; then
        warn "Prebuild check: could not write $ARTIFACTS_DIR/prebuild-check.json"
    fi

    _pbc_report "$findings"
    if [[ "$rc" -eq 1 ]]; then
        emit_event "prebuild_check.failed" "language=$lang" "critical_ids=$PREBUILD_CRITICAL_IDS" \
            "duration_ms=$duration_ms" 2>/dev/null || true
    else
        emit_event "prebuild_check.completed" "language=$lang" "status=$status" "mode=$mode" \
            "critical=$criticals" "warning=$warnings" "info=$infos" "duration_ms=$duration_ms" 2>/dev/null || true
        [[ "$status" == "pass" ]] && success "Prebuild check passed ($lang)"
    fi
    return "$rc"
}
