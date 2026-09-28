#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_PREFLIGHT_LOADED:-}" ]] && return 0
_LOOP_PREFLIGHT_LOADED=1

# ─── Build-Loop Pre-Flight ─────────────────────────────────────────────────────
# Catches a test command that is BROKEN (syntax error, executable missing, npm
# script undefined, no Makefile, deps not installed) before iteration 1 spends
# a Claude call discovering it.
#
# This never RUNS the test suite. At loop start the tests are expected to fail —
# the feature isn't written yet — so an exit code can't tell "broken command"
# from "red tests". Everything here is static. Anything we can't parse reliably
# (quotes, pipes, subshells, expansions) passes: a false failure would block a
# working loop, which is worse than the iteration a missed check costs.

PREFLIGHT_REASON=""

# _preflight_script_defined <dir> <script> — package.json in <dir> defines <script>
_preflight_script_defined() {
    local dir="$1" script="$2"
    if [[ ! -f "$dir/package.json" ]]; then
        PREFLIGHT_REASON="no package.json in ${dir}"
        return 1
    fi
    # Without jq we can't inspect scripts — pass rather than guess
    command -v jq >/dev/null 2>&1 || return 0
    local body
    if ! body=$(jq -r --arg s "$script" '.scripts[$s] // empty' "$dir/package.json" 2>/dev/null); then
        return 0
    fi
    if [[ -z "$body" ]]; then
        PREFLIGHT_REASON="package.json has no \"${script}\" script"
        return 1
    fi
    if [[ "$body" == *"no test specified"* ]]; then
        PREFLIGHT_REASON="package.json \"${script}\" script is npm's placeholder (no test specified)"
        return 1
    fi
    return 0
}

# _preflight_resolve <dir> <path> — absolute path for <path> relative to <dir>
_preflight_resolve() {
    case "$2" in
        /*) echo "$2" ;;
        *)  echo "$1/$2" ;;
    esac
}

# _preflight_check_simple <dir> <cmd> — one simple command (no &&) run from <dir>
_preflight_check_simple() {
    local dir="$1" cmd="$2"
    local -a tok=()
    read -r -a tok <<< "$cmd"
    local n=${#tok[@]} i=0

    # Skip VAR=val assignments and transparent wrappers
    while [[ $i -lt $n ]]; do
        case "${tok[$i]}" in
            env|time|command) i=$((i + 1)) ;;
            *=*) [[ "${tok[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && i=$((i + 1)) || break ;;
            *) break ;;
        esac
    done
    [[ $i -ge $n ]] && return 0

    local exe="${tok[$i]}"
    local -a args=()
    local j
    for (( j = i + 1; j < n; j++ )); do
        # Stop at redirections (2>&1, >/dev/null, <in)
        case "${tok[$j]}" in
            *'>'*|*'<'*) break ;;
        esac
        args+=("${tok[$j]}")
    done
    local nargs=${#args[@]}

    # Executable exists
    if [[ "$exe" == */* ]]; then
        local path
        path=$(_preflight_resolve "$dir" "$exe")
        if [[ ! -f "$path" ]]; then
            PREFLIGHT_REASON="'${exe}' does not exist"
            return 1
        fi
        if [[ ! -x "$path" ]]; then
            PREFLIGHT_REASON="'${exe}' is not executable"
            return 1
        fi
        return 0
    fi
    if ! command -v "$exe" >/dev/null 2>&1; then
        PREFLIGHT_REASON="'${exe}' not found on PATH"
        return 1
    fi

    # First non-flag argument (script / tool)
    local first="" a
    for (( j = 0; j < nargs; j++ )); do
        a="${args[$j]}"
        [[ "$a" == -* ]] && continue
        first="$a"
        break
    done

    case "$exe" in
        bash|sh|zsh)
            # `bash -c ...` / `bash -n` etc. — nothing to inspect
            [[ $nargs -gt 0 && "${args[0]}" == -* ]] && return 0
            if [[ -n "$first" ]]; then
                local script_path
                script_path=$(_preflight_resolve "$dir" "$first")
                if [[ ! -f "$script_path" ]]; then
                    PREFLIGHT_REASON="script '${first}' does not exist"
                    return 1
                fi
            fi
            ;;
        npm|yarn|pnpm)
            # Flags can take values (--prefix DIR, -w PKG, --filter X), so only
            # inspect the plain `<pm> test` / `<pm> run <script>` shapes.
            local sub="${args[0]:-}" script="${args[1]:-}"
            case "$exe:$sub" in
                npm:test|npm:t|yarn:test|pnpm:test)
                    _preflight_script_defined "$dir" "test" || return 1 ;;
                npm:run|npm:run-script|yarn:run|pnpm:run)
                    if [[ -n "$script" && "$script" != -* ]]; then
                        _preflight_script_defined "$dir" "$script" || return 1
                    fi
                    ;;
            esac
            ;;
        make)
            # -C / -f point make elsewhere — don't second-guess them
            for a in ${args[@]+"${args[@]}"}; do
                case "$a" in -C|-f|--file=*|--directory=*|-C*|-f*) return 0 ;; esac
            done
            if [[ ! -f "$dir/Makefile" && ! -f "$dir/makefile" && ! -f "$dir/GNUmakefile" ]]; then
                PREFLIGHT_REASON="no Makefile in ${dir}"
                return 1
            fi
            ;;
        npx)
            case "$first" in
                vitest|jest|mocha)
                    if [[ ! -e "$dir/node_modules/.bin/$first" ]]; then
                        PREFLIGHT_REASON="'${first}' is not installed (node_modules/.bin/${first} missing — run npm install)"
                        return 1
                    fi
                    ;;
            esac
            ;;
    esac
    return 0
}

# _preflight_check_cmd <cmd> — 0 if the command looks runnable, else 1 with
# PREFLIGHT_REASON set. Checks are relative to the current directory.
_preflight_check_cmd() {
    local cmd="$1"
    PREFLIGHT_REASON=""
    [[ -z "${cmd//[[:space:]]/}" ]] && return 0

    if ! bash -n -c "$cmd" 2>/dev/null; then
        PREFLIGHT_REASON="syntax error"
        return 1
    fi

    # Anything beyond simple commands joined by && isn't parsed — pass.
    local stripped="${cmd//&&/ }"
    stripped="${stripped//2>&1/ }"
    case "$stripped" in
        *\'*|*\"*|*\`*|*'$'*|*'('*|*')'*|*'{'*|*'}'*|*'|'*|*';'*|*'&'*|*'\'*) return 0 ;;
    esac

    local dir="$PWD" rest="$cmd" seg
    while [[ -n "$rest" ]]; do
        if [[ "$rest" == *"&&"* ]]; then
            seg="${rest%%&&*}"
            rest="${rest#*&&}"
        else
            seg="$rest"
            rest=""
        fi
        local -a words=()
        read -r -a words <<< "$seg"
        [[ ${#words[@]} -eq 0 ]] && continue
        if [[ "${words[0]}" == "cd" ]]; then
            # `cd` with no args or `cd -` — can't follow it, stop checking
            [[ ${#words[@]} -lt 2 || "${words[1]}" == "-" ]] && return 0
            local target
            target=$(_preflight_resolve "$dir" "${words[1]}")
            if [[ ! -d "$target" ]]; then
                PREFLIGHT_REASON="directory '${words[1]}' does not exist"
                return 1
            fi
            dir="$target"
            continue
        fi
        _preflight_check_simple "$dir" "$seg" || return 1
    done
    return 0
}

# _preflight_write_result <status> [command] [reason] — atomic write of preflight.json
_preflight_write_result() {
    local status="$1" cmd="${2:-}" reason="${3:-}"
    [[ -n "${LOG_DIR:-}" && -d "${LOG_DIR:-}" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local out="$LOG_DIR/preflight.json"
    local tmp="${out}.tmp.$$"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if jq -n --arg status "$status" --arg command "$cmd" --arg reason "$reason" --arg checked_at "$ts" \
        '{status: $status, command: $command, reason: $reason, checked_at: $checked_at}' > "$tmp" 2>/dev/null \
        && mv "$tmp" "$out" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    # A failed write must not turn into a false pre-flight failure
    if type warn >/dev/null 2>&1; then warn "Pre-flight: could not write ${out}"; fi
    return 0
}

# loop_preflight_check — validate TEST_CMD, FAST_TEST_CMD and ADDITIONAL_TEST_CMDS.
# Returns 1 (after printing why) if any of them is broken.
loop_preflight_check() {
    # Bypassed runs still overwrite preflight.json so a stale "failed" from an
    # earlier run can't be misread by the pipeline or daemon.
    if [[ "${LOOP_PREFLIGHT:-true}" == "false" ]]; then
        _preflight_write_result "skipped"
        return 0
    fi
    if type _config_get >/dev/null 2>&1; then
        local cfg
        cfg=$(_config_get "loop.preflight" "true" 2>/dev/null || echo "true")
        if [[ "$cfg" == "false" ]]; then
            _preflight_write_result "skipped"
            return 0
        fi
    fi

    local -a cmds=()
    [[ -n "${TEST_CMD:-}" ]] && cmds+=("$TEST_CMD")
    [[ -n "${FAST_TEST_CMD:-}" ]] && cmds+=("$FAST_TEST_CMD")
    local c
    for c in ${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}; do
        [[ -n "$c" ]] && cmds+=("$c")
    done

    for c in ${cmds[@]+"${cmds[@]}"}; do
        if ! _preflight_check_cmd "$c"; then
            _preflight_write_result "failed" "$c" "$PREFLIGHT_REASON"
            if type error >/dev/null 2>&1; then
                error "Pre-flight: test command is broken: '${c}' — ${PREFLIGHT_REASON}"
            else
                echo "Pre-flight: test command is broken: '${c}' — ${PREFLIGHT_REASON}" >&2
            fi
            echo "  Fix --test-cmd / install dependencies, or bypass with --no-preflight (LOOP_PREFLIGHT=false)." >&2
            if type emit_event >/dev/null 2>&1; then
                emit_event "loop.preflight_failed" "cmd=${c}" "reason=${PREFLIGHT_REASON}" 2>/dev/null || true
            fi
            return 1
        fi
    done

    _preflight_write_result "passed"
    return 0
}
