#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright compat — Cross-platform compatibility helpers               ║
# ║  Source this AFTER color definitions for NO_COLOR + platform support    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/compat.sh"
#
# Provides:
#   - NO_COLOR / dumb terminal / non-tty detection (auto-blanks color vars)
#   - _to_lower() / _to_upper() — bash 3.2 compat (${var,,}/${var^^} require bash 4+)
#   - file_mtime() — cross-platform file modification time (epoch)
#   - sed_i()    — cross-platform sed in-place editing
#   - open_url() — cross-platform browser open
#   - tmp_dir()  — returns best temp directory for platform
#   - is_wsl()   — detect WSL environment
#   - is_macos() / is_linux() — platform checks
#   - _timeout() — run command with timeout (timeout/gtimeout or no-op on macOS)

# ─── NO_COLOR support (https://no-color.org/) ─────────────────────────────
# Blanks standard color variables when:
#   - NO_COLOR is set (any value)
#   - TERM is "dumb" (e.g. Emacs shell, CI without tty)
#   - stdout is not a terminal (piped output)
if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]] || { [[ -z "${SHIPWRIGHT_FORCE_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
    CYAN='' PURPLE='' BLUE='' GREEN='' YELLOW='' RED='' DIM='' BOLD='' RESET=''
    UNDERLINE='' ITALIC=''
fi

# ─── Platform detection ───────────────────────────────────────────────────
_COMPAT_UNAME="${_COMPAT_UNAME:-$(uname -s 2>/dev/null || echo "Unknown")}"

is_macos() { [[ "$_COMPAT_UNAME" == "Darwin" ]]; }
is_linux() { [[ "$_COMPAT_UNAME" == "Linux" ]]; }

# ─── Bash 3.2 compat (macOS ships bash 3.2) ───────────────────────────────
# Case conversion: ${var,,} and ${var^^} require bash 4+. Use these instead:
_to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
_to_upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
is_wsl()   { is_linux && [[ -n "${WSL_DISTRO_NAME:-}" || -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; }

# ─── sed -i (macOS vs GNU) ────────────────────────────────────────────────
# macOS sed requires '' after -i, GNU sed does not
sed_i() {
    if is_macos; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ─── Open URL in browser ──────────────────────────────────────────────────
open_url() {
    local url="$1"
    if is_macos; then
        open "$url"
    elif is_wsl; then
        # WSL: use wslview (from wslu) or powershell
        if command -v wslview >/dev/null 2>&1; then
            wslview "$url"
        elif command -v powershell.exe >/dev/null 2>&1; then
            powershell.exe -Command "Start-Process '$url'" 2>/dev/null
        else
            return 1
        fi
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"
    else
        return 1
    fi
}

# ─── Temp directory (respects Windows %TEMP% and %TMP%) ──────────────────
tmp_dir() {
    echo "${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
}

# ─── Process existence check (portable) ──────────────────────────────────
pid_exists() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# ─── Shared Error Taxonomy ───────────────────────────────────────────────
# Canonical error categories used by sw-pipeline.sh, sw-memory.sh, and others.
# Extend via ~/.shipwright/optimization/error-taxonomy.json
SW_ERROR_CATEGORIES="test_failure build_error lint_error timeout dependency flaky config security permission unknown"

sw_valid_error_category() {
    local category="${1:-}"
    local custom_file="$HOME/.shipwright/optimization/error-taxonomy.json"
    # Check custom taxonomy first
    if [[ -f "$custom_file" ]] && command -v jq >/dev/null 2>&1; then
        local custom_cats
        custom_cats=$(jq -r '.categories[]? // empty' "$custom_file" 2>/dev/null || true)
        if [[ -n "$custom_cats" ]]; then
            local cat_item
            while IFS= read -r cat_item; do
                if [[ "$cat_item" == "$category" ]]; then
                    return 0
                fi
            done <<< "$custom_cats"
        fi
    fi
    # Check built-in categories
    local builtin
    for builtin in $SW_ERROR_CATEGORIES; do
        if [[ "$builtin" == "$category" ]]; then
            return 0
        fi
    done
    return 1
}

# ─── Complexity Bucketing ────────────────────────────────────────────────
# Shared by sw-intelligence.sh and sw-self-optimize.sh.
# Thresholds tunable via ~/.shipwright/optimization/complexity-clusters.json
complexity_bucket() {
    local complexity="${1:-5}"
    local config_file="$HOME/.shipwright/optimization/complexity-clusters.json"
    local low_boundary=3
    local high_boundary=6
    if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
        local lb hb
        lb=$(jq -r '.low_boundary // 3' "$config_file" 2>/dev/null || echo "3")
        hb=$(jq -r '.high_boundary // 6' "$config_file" 2>/dev/null || echo "6")
        [[ "$lb" =~ ^[0-9]+$ ]] && low_boundary="$lb"
        [[ "$hb" =~ ^[0-9]+$ ]] && high_boundary="$hb"
    fi
    if [[ "$complexity" -le "$low_boundary" ]]; then
        echo "low"
    elif [[ "$complexity" -le "$high_boundary" ]]; then
        echo "medium"
    else
        echo "high"
    fi
}

# ─── Framework / Language Detection ──────────────────────────────────────
# Shared by sw-prep.sh and sw-pipeline.sh.
detect_primary_language() {
    local dir="${1:-.}"
    if [[ -f "$dir/package.json" ]]; then
        if [[ -f "$dir/tsconfig.json" ]]; then
            echo "typescript"
        else
            echo "javascript"
        fi
    elif [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
        echo "python"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$dir/build.gradle" || -f "$dir/pom.xml" ]]; then
        echo "java"
    elif [[ -f "$dir/mix.exs" ]]; then
        echo "elixir"
    else
        echo "unknown"
    fi
}

detect_test_framework() {
    local dir="${1:-.}"
    if [[ -f "$dir/package.json" ]] && command -v jq >/dev/null 2>&1; then
        local runner
        runner=$(jq -r '
            if .devDependencies.vitest then "vitest"
            elif .devDependencies.jest then "jest"
            elif .devDependencies.mocha then "mocha"
            elif .devDependencies.ava then "ava"
            elif .devDependencies.tap then "tap"
            else ""
            end' "$dir/package.json" 2>/dev/null || echo "")
        if [[ -n "$runner" ]]; then
            echo "$runner"
            return 0
        fi
    fi
    if [[ -f "$dir/pytest.ini" || -f "$dir/pyproject.toml" ]]; then
        echo "pytest"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go test"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "cargo test"
    elif [[ -f "$dir/build.gradle" ]]; then
        echo "gradle test"
    else
        echo ""
    fi
}

# ─── Cross-platform file modification time (epoch) ────────────────────────
# macOS/BSD: stat -f %m; Linux: stat -c '%Y'
file_mtime() {
    local file="$1" out

    # `-f` means two different things: BSD/macOS reads it as the output FORMAT,
    # GNU coreutils reads it as --file-system. So `stat -f %m FILE` on Linux
    # does not fail cleanly — it prints filesystem information for FILE on
    # stdout. The old `stat -f … || stat -c … || echo 0` chain therefore
    # captured that text (possibly concatenated with the real answer), and
    # callers got something that was not an epoch. Probe each dialect and
    # accept the result only if it actually looks like one.
    out=$(stat -c '%Y' "$file" 2>/dev/null) || out=""
    if [[ "$out" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$out"
        return 0
    fi

    out=$(stat -f '%m' "$file" 2>/dev/null) || out=""
    if [[ "$out" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$out"
        return 0
    fi

    printf '0\n'
}

# ─── UUID generation (for --session-id, which requires a valid UUID) ───────
# uuidgen ships with macOS and with util-linux on most distros, but is not
# guaranteed; /proc/sys/kernel/random/uuid covers Linux images without it, and
# the awk form is a last resort so callers never have to handle "no UUID".
# Usage: new_uuid
new_uuid() {
    local u=""
    if command -v uuidgen >/dev/null 2>&1; then
        u=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')
    fi
    if [[ ! "$u" =~ ^[0-9a-f-]{36}$ ]] && [[ -r /proc/sys/kernel/random/uuid ]]; then
        u=$(tr -d '\n' < /proc/sys/kernel/random/uuid)
    fi
    if [[ ! "$u" =~ ^[0-9a-f-]{36}$ ]]; then
        u=$(awk 'BEGIN {
            srand()
            h = "0123456789abcdef"
            for (i = 1; i <= 36; i++) {
                if (i == 9 || i == 14 || i == 19 || i == 24) { printf "-"; continue }
                if (i == 15) { printf "4"; continue }
                if (i == 20) { printf substr("89ab", int(rand() * 4) + 1, 1); continue }
                printf substr(h, int(rand() * 16) + 1, 1)
            }
        }')
    fi
    printf '%s\n' "$u"
}

# ─── Timeout command (macOS may lack timeout; gtimeout from coreutils) ─────
# Usage: _timeout <seconds> <command> [args...]
_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        # Fallback: run without timeout (e.g. on older macOS)
        "$@"
    fi
}

# ─── Cross-platform date helpers (BSD date, GNU date, python3) ───────────────
# BSD date (macOS) and GNU date (Linux, `gdate` on macOS) disagree on the flags these helpers
# need: `-j -f` parses only on BSD, `-r` takes an epoch on BSD but a file on GNU, and `-d`
# parses free text only on GNU. Scripts call these helpers instead of `date -j`, `date -jf` or
# `date -r <epoch>`; the fitness rule F11-bash-no-bsd-date (tools/arch) enforces that.
#
# Each helper prints its result and returns 0. On invalid input it prints NOTHING and returns 1,
# so the caller picks its default explicitly, e.g. `start=$(date_to_epoch "$ts" || echo 0)`.
# Input shapes are checked before any `date` runs, so both see only well-formed strings (they may
# still differ on out-of-range values such as Feb 30, which BSD normalizes and GNU rejects).
#
#   date_to_epoch <ts>               UTC "YYYY-MM-DDTHH:MM:SS[.frac]Z" or "YYYY-MM-DD" -> epoch
#   date_local_to_epoch <str>        ps(1) lstart "Thu Oct  5 10:00:00 2026" (local) -> epoch
#   epoch_to_iso <epoch>             epoch -> "YYYY-MM-DDTHH:MM:SSZ" (UTC)
#   epoch_format [-u] <epoch> <fmt>  epoch -> strftime(fmt); local time unless -u
#   date_days_ago <n>                UTC "YYYY-MM-DD" for n days ago
#   date_add_days <date> <n>         UTC "YYYY-MM-DD" for date + n days

# True when `date` is GNU coreutils. Probed per call because PATH can change (tests put a
# `date` shim that execs gdate first on macOS).
_compat_date_is_gnu() { date --version >/dev/null 2>&1; }

_compat_is_int() { [[ "${1:-}" =~ ^-?[0-9]+$ ]]; }

# _compat_parse_epoch <utc|local> <string>
_compat_parse_epoch() {
    local zone="$1" s="${2:-}" out="" core
    if [[ "$zone" == "utc" ]]; then
        [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z)?$ ]] || return 1
    else
        # macOS `ps -o lstart=` pads with trailing spaces; trim the ends (keep the inner day padding).
        s="${s#"${s%%[![:space:]]*}"}"
        s="${s%"${s##*[![:space:]]}"}"
        [[ "$s" =~ ^[A-Za-z]{3}\ [A-Za-z]{3}\ [\ 0-9]{2}\ [0-9:]{8}\ [0-9]{4}$ ]] || return 1
    fi
    if _compat_date_is_gnu; then
        if [[ "$zone" == "utc" ]]; then
            out=$(date -u -d "$s" +%s 2>/dev/null) || out=""
        else
            out=$(date -d "$s" +%s 2>/dev/null) || out=""
        fi
    elif [[ "$zone" == "utc" ]]; then
        # Fractional seconds are dropped. BSD `-j -f` fills fields the format does not cover from
        # the current clock, so a date-only string gets an explicit 00:00:00.
        core="${s%Z}"
        core="${core%%.*}"
        if [[ "$core" == *T* ]]; then
            out=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$core" +%s 2>/dev/null) || out=""
        else
            out=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$core 00:00:00" +%s 2>/dev/null) || out=""
        fi
    else
        # ps lstart is local time, so no TZ override here.
        out=$(date -j -f "%a %b %e %H:%M:%S %Y" "$s" +%s 2>/dev/null) || out=""
    fi
    if ! _compat_is_int "$out" && command -v python3 >/dev/null 2>&1; then
        if [[ "$zone" == "utc" ]]; then
            out=$(python3 -I -c 'import sys, calendar, datetime as d
s = sys.argv[1].rstrip("Z").split(".")[0]
f = "%Y-%m-%dT%H:%M:%S" if "T" in s else "%Y-%m-%d"
print(calendar.timegm(d.datetime.strptime(s, f).timetuple()))' "$s" 2>/dev/null) || out=""
        else
            out=$(python3 -I -c 'import sys, time
print(int(time.mktime(time.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y"))))' "$s" 2>/dev/null) || out=""
        fi
    fi
    _compat_is_int "$out" || return 1
    printf '%s\n' "$out"
}

date_to_epoch() { _compat_parse_epoch utc "${1:-}"; }

date_local_to_epoch() { _compat_parse_epoch local "${1:-}"; }

# epoch_format [-u] <epoch> <fmt>
epoch_format() {
    local utc=0 e="${1:-}" f="${2:-}" out=""
    if [[ "$e" == "-u" ]]; then
        utc=1
        e="${2:-}"
        f="${3:-}"
    fi
    [[ "$e" =~ ^[0-9]+$ && -n "$f" ]] || return 1
    if _compat_date_is_gnu; then
        if [[ "$utc" -eq 1 ]]; then
            out=$(date -u -d "@$e" +"$f" 2>/dev/null) || out=""
        else
            out=$(date -d "@$e" +"$f" 2>/dev/null) || out=""
        fi
    elif [[ "$utc" -eq 1 ]]; then
        out=$(date -u -r "$e" +"$f" 2>/dev/null) || out=""
    else
        out=$(date -r "$e" +"$f" 2>/dev/null) || out=""
    fi
    if [[ -z "$out" ]] && command -v python3 >/dev/null 2>&1; then
        out=$(python3 -I -c 'import sys, datetime as d
e, f, u = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
t = d.datetime.fromtimestamp(e, d.timezone.utc) if u else d.datetime.fromtimestamp(e)
print(t.strftime(f))' "$e" "$f" "$utc" 2>/dev/null) || out=""
    fi
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

epoch_to_iso() { epoch_format -u "${1:-}" "%Y-%m-%dT%H:%M:%SZ"; }

date_days_ago() {
    local days="${1:-}"
    _compat_is_int "$days" || return 1
    epoch_format -u $(( $(date +%s) - days * 86400 )) "%Y-%m-%d"
}

date_add_days() {
    local base="${1:-}" days="${2:-}" e
    _compat_is_int "$days" || return 1
    e=$(date_to_epoch "$base") || return 1
    epoch_format -u $(( e + days * 86400 )) "%Y-%m-%d"
}

# ─── Cross-platform MD5 ──────────────────────────────────────────────────
# Usage:
#   compute_md5 --string "some text"   → md5 hash of string
#   compute_md5 /path/to/file          → md5 hash of file
compute_md5() {
    if [[ "${1:-}" == "--string" ]]; then
        shift
        printf '%s' "$1" | md5 2>/dev/null || printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1
    else
        # File mode
        local file="$1"
        md5 -q "$file" 2>/dev/null || md5sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}

# ─── Intelligent Model Selection ──────────────────────────────────────────
# _smart_model <purpose> [default]
# Returns model name from config chain: env var → daemon-config.json → default
# Purpose: "classification", "detection", "validation", "commit_quality",
#          "default", or any custom key under model_routing.{purpose}
_smart_model() {
    local purpose="${1:-default}" default="${2:-haiku}"

    # Sanitize purpose to alphanumeric/underscore only (prevents eval injection)
    if [[ ! "$purpose" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "$default"
        return
    fi

    # 1. Environment override (e.g., SW_MODEL_CLASSIFICATION=sonnet)
    local env_key
    env_key="SW_MODEL_$(echo "$purpose" | tr '[:lower:]' '[:upper:]')"
    local env_val=""
    eval 'env_val="${'"$env_key"':-}"' 2>/dev/null || true
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return
    fi

    # 2. Daemon config: model_routing.{purpose}
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg p "$purpose" '.model_routing[$p] // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            echo "$cfg_val"
            return
        fi
    fi

    # 3. User-level config: ~/.shipwright/model-routing.json
    local user_cfg="${HOME}/.shipwright/model-routing.json"
    if [[ -f "$user_cfg" ]]; then
        local user_val
        user_val=$(jq -r --arg p "$purpose" '.[$p] // empty' "$user_cfg" 2>/dev/null || true)
        if [[ -n "$user_val" && "$user_val" != "null" ]]; then
            echo "$user_val"
            return
        fi
    fi

    # 4. Default
    echo "$default"
}

# _smart_int <config_key> <default>
# Read int from daemon-config with env override and default fallback
_smart_int() {
    local key="$1" default="$2"

    # Sanitize key to alphanumeric/underscore/dot only (prevents eval injection)
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
        echo "$default"
        return
    fi

    # Env override: config.key.path → SW_KEY_PATH
    local env_key
    env_key="SW_$(echo "$key" | tr '[:lower:].' '[:upper:]_')"
    local env_val=""
    eval 'env_val="${'"$env_key"':-}"' 2>/dev/null || true
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return
    fi

    # Daemon config
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            echo "$cfg_val"
            return
        fi
    fi

    echo "$default"
}

# _smart_effort <stage>
# Read effort level from config, with per-stage defaults
_smart_effort() {
    local stage="$1"

    # 1. Explicit override
    if [[ -n "${EFFORT_LEVEL_OVERRIDE:-}" ]]; then
        echo "$EFFORT_LEVEL_OVERRIDE"
        return
    fi

    # 2. Config: effort_levels.{stage}
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg s "$stage" '.effort_levels[$s] // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            echo "$cfg_val"
            return
        fi
    fi

    # 3. Intelligent defaults (overridable via config or EFFORT_LEVEL_OVERRIDE)
    #
    # Effort is spent ASYMMETRICALLY, not uniformly. Two things drive the shape:
    #
    #   - Coding and agentic work is where effort pays off most. `xhigh` is the
    #     recommended setting for those and is what Claude Code itself defaults
    #     to; `build` previously sat at `medium`, which underspent on the one
    #     stage that writes the code.
    #   - Refinement and review dominate agentic token cost, and a single
    #     high-effort review pass beats several cheaper ones. So `review` and
    #     `compound_quality` go to `xhigh` rather than adding more rounds.
    #
    # Mechanical stages stay at `low` deliberately — lower effort there means
    # fewer, more consolidated tool calls and less preamble, which is what you
    # want from intake/pr/merge. `max` is intentionally not a default anywhere:
    # it shows diminishing returns and can overthink. Reach for it per-run via
    # EFFORT_LEVEL_OVERRIDE when correctness matters more than cost.
    #
    # spec_generation/spec_verification are listed explicitly because they were
    # falling through to the `medium` catch-all while the docs claimed `high`.
    case "$stage" in
        intake)                  echo "low" ;;
        plan|design)             echo "high" ;;
        spec_generation|spec_verification) echo "high" ;;
        build)                   echo "xhigh" ;;
        test)                    echo "medium" ;;
        review|compound_quality) echo "xhigh" ;;
        pr|merge)                echo "low" ;;
        deploy|validate|monitor) echo "medium" ;;
        *)                       echo "medium" ;;
    esac
}

# _exponential_backoff <attempt> [base_seconds] [max_seconds]
# Returns sleep duration with jitter for retry loops
_exponential_backoff() {
    local attempt="${1:-1}" base="${2:-2}" max="${3:-60}"
    local delay=$base
    local i=1
    while [ "$i" -lt "$attempt" ]; do
        delay=$((delay * 2))
        i=$((i + 1))
    done
    # Cap at max
    [ "$delay" -gt "$max" ] && delay=$max
    # Add jitter: ±25%
    local jitter=$(( (RANDOM % (delay / 2 + 1)) - delay / 4 ))
    delay=$((delay + jitter))
    [ "$delay" -lt 1 ] && delay=1
    echo "$delay"
}
