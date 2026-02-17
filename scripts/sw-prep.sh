#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright prep — Repository Preparation for Agent Teams                      ║
# ║  Analyze repos · Generate configs · Equip autonomous agents            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Handle subcommands ───────────────────────────────────────────────────────
if [[ "${1:-}" == "test" ]]; then
    shift
    exec "$SCRIPT_DIR/sw-prep-test.sh" "$@"
fi

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Defaults ───────────────────────────────────────────────────────────────
FORCE=false
CHECK_ONLY=false
UPDATE_MODE=false
WITH_CLAUDE=false
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Detection results
LANG_DETECTED=""
FRAMEWORK=""
PACKAGE_MANAGER=""
TEST_CMD=""
BUILD_CMD=""
LINT_CMD=""
FORMAT_CMD=""
DEV_CMD=""
TEST_FRAMEWORK=""
HAS_DOCKER=false
HAS_COMPOSE=false
HAS_CI=false
HAS_MAKEFILE=false
PROJECT_NAME=""

# Structure scan results
SRC_DIRS=""
TEST_DIRS=""
DOC_DIRS=""
CONFIG_FILES=""
ENTRY_POINTS=""
SRC_FILE_COUNT=0
TEST_FILE_COUNT=0
TOTAL_LINES=0

# Pattern extraction results
IMPORT_STYLE=""
NAMING_CONVENTION=""
HAS_ROUTES=false
HAS_DB=false
HAS_MIDDLEWARE=false
ROUTE_PATTERNS=""
DB_PATTERNS=""
ARCHITECTURE_PATTERN=""
SEMICOLONS=""
QUOTE_STYLE=""
INDENT_STYLE=""

# Tracking generated files
GENERATED_FILES=()

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright prep${RESET} ${DIM}v${VERSION}${RESET} — Prepare a repository for autonomous agent development"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright prep${RESET} [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--force${RESET}        Overwrite existing files"
    echo -e "  ${CYAN}--check${RESET}        Audit existing prep (dry run)"
    echo -e "  ${CYAN}--update${RESET}       Refresh auto-generated sections only"
    echo -e "  ${CYAN}--with-claude${RESET}  Deep analysis using Claude Code (slower, richer)"
    echo -e "  ${CYAN}--help, -h${RESET}     Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright prep${RESET}                  # Full analysis + generation"
    echo -e "  ${DIM}shipwright prep --check${RESET}           # Audit quality"
    echo -e "  ${DIM}shipwright prep --update${RESET}          # Refresh without overwriting user edits"
    echo -e "  ${DIM}shipwright prep --force${RESET}           # Regenerate everything"
    echo -e "  ${DIM}shipwright prep --with-claude${RESET}     # Deep analysis with Claude"
    echo ""
    echo -e "${BOLD}GENERATED FILES${RESET}"
    echo -e "  ${DIM}.claude/CLAUDE.md${RESET}                    Project context for Claude Code"
    echo -e "  ${DIM}.claude/settings.json${RESET}                Permission allowlists"
    echo -e "  ${DIM}.claude/ARCHITECTURE.md${RESET}              System architecture overview"
    echo -e "  ${DIM}.claude/CODING-STANDARDS.md${RESET}          Coding conventions"
    echo -e "  ${DIM}.claude/DEFINITION-OF-DONE.md${RESET}        Completion checklist"
    echo -e "  ${DIM}.claude/agents/*.md${RESET}                  Agent role definitions"
    echo -e "  ${DIM}.claude/hooks/*.sh${RESET}                   Pre/post action hooks"
    echo -e "  ${DIM}.github/ISSUE_TEMPLATE/agent-task.md${RESET} Agent task template"
    echo ""
    echo -e "${DIM}Docs: $(_sw_docs_url)  |  GitHub: $(_sw_github_url)${RESET}"
}

# ─── CLI Argument Parsing ───────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --force)       FORCE=true ;;
        --check)       CHECK_ONLY=true ;;
        --update)      UPDATE_MODE=true ;;
        --with-claude) WITH_CLAUDE=true ;;
        --help|-h)     show_help; exit 0 ;;
        *)
            error "Unknown option: $arg"
            echo ""
            show_help
            exit 1
            ;;
    esac
done

# ─── prep_init ──────────────────────────────────────────────────────────────

prep_init() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        error "Not inside a git repository"
        exit 1
    fi
    PROJECT_ROOT="$(git rev-parse --show-toplevel)"
    PROJECT_NAME="$(basename "$PROJECT_ROOT")"
    mkdir -p "$PROJECT_ROOT/.claude"
    mkdir -p "$PROJECT_ROOT/.claude/hooks"
    mkdir -p "$PROJECT_ROOT/.claude/agents"
    mkdir -p "$PROJECT_ROOT/.github/ISSUE_TEMPLATE"
}

# ─── should_write — Idempotency gating ─────────────────────────────────────

# Returns 0 if we should write, 1 if we should skip
should_write() {
    local filepath="$1"
    if [[ ! -f "$filepath" ]]; then
        return 0  # File doesn't exist — write it
    fi
    if $FORCE; then
        return 0  # Force mode — overwrite
    fi
    if $UPDATE_MODE; then
        # In update mode, only write if file has auto markers
        if grep -q "<!-- sw:auto-start -->" "$filepath" 2>/dev/null; then
            return 0
        fi
        info "Skipping ${filepath##"$PROJECT_ROOT"/} (no auto markers, user-customized)"
        return 1
    fi
    info "Skipping ${filepath##"$PROJECT_ROOT"/} (exists, use --force to overwrite)"
    return 1
}

# ─── update_auto_section — Replace content between markers ──────────────────

update_auto_section() {
    local filepath="$1"
    local new_content="$2"

    if $UPDATE_MODE && [[ -f "$filepath" ]] && grep -q "<!-- sw:auto-start -->" "$filepath"; then
        # Replace content between markers, preserve everything else
        local before after
        before=$(sed '/<!-- sw:auto-start -->/,$d' "$filepath")
        after=$(sed '1,/<!-- sw:auto-end -->/d' "$filepath")
        {
            echo "$before"
            echo "$new_content"
            echo "$after"
        } > "$filepath"
    else
        echo "$new_content" > "$filepath"
    fi
}

# ─── track_file — Track a generated file ────────────────────────────────────

track_file() {
    local filepath="$1"
    local lines
    lines=$(wc -l < "$filepath" | tr -d ' ')
    GENERATED_FILES+=("${filepath##"$PROJECT_ROOT"/}|${lines}")
}

# ─── prep_detect_stack ──────────────────────────────────────────────────────

prep_detect_stack() {
    local root="$PROJECT_ROOT"
    info "Detecting project stack..."

    # ── Language & Framework ──

    if [[ -f "$root/package.json" ]]; then
        LANG_DETECTED="nodejs"
        local deps
        deps=$(cat "$root/package.json")

        # Detect framework from dependencies
        if echo "$deps" | grep -q '"next"'; then
            FRAMEWORK="next.js"
            LANG_DETECTED="typescript"
        elif echo "$deps" | grep -q '"nuxt"'; then
            FRAMEWORK="nuxt"
            LANG_DETECTED="typescript"
        elif echo "$deps" | grep -q '"@angular/core"'; then
            FRAMEWORK="angular"
            LANG_DETECTED="typescript"
        elif echo "$deps" | grep -q '"vue"'; then
            FRAMEWORK="vue"
        elif echo "$deps" | grep -q '"react"'; then
            FRAMEWORK="react"
        elif echo "$deps" | grep -q '"@nestjs/core"'; then
            FRAMEWORK="nestjs"
            LANG_DETECTED="typescript"
        elif echo "$deps" | grep -q '"express"'; then
            FRAMEWORK="express"
        elif echo "$deps" | grep -q '"fastify"'; then
            FRAMEWORK="fastify"
        elif echo "$deps" | grep -q '"hono"'; then
            FRAMEWORK="hono"
        fi

        # TypeScript override
        if echo "$deps" | grep -q '"typescript"'; then
            LANG_DETECTED="typescript"
        fi

        # Detect test framework
        if echo "$deps" | grep -q '"vitest"'; then
            TEST_FRAMEWORK="vitest"
        elif echo "$deps" | grep -q '"jest"'; then
            TEST_FRAMEWORK="jest"
        elif echo "$deps" | grep -q '"mocha"'; then
            TEST_FRAMEWORK="mocha"
        elif echo "$deps" | grep -q '"ava"'; then
            TEST_FRAMEWORK="ava"
        fi

        # Detect package manager
        if [[ -f "$root/pnpm-lock.yaml" ]]; then
            PACKAGE_MANAGER="pnpm"
        elif [[ -f "$root/yarn.lock" ]]; then
            PACKAGE_MANAGER="yarn"
        elif [[ -f "$root/bun.lockb" ]]; then
            PACKAGE_MANAGER="bun"
        else
            PACKAGE_MANAGER="npm"
        fi

        # Detect commands from package.json scripts
        local scripts_json
        scripts_json=$(jq -r '.scripts // {}' "$root/package.json" 2>/dev/null || echo "{}")

        if [[ -z "$TEST_CMD" ]]; then
            local has_test
            has_test=$(echo "$scripts_json" | jq -r '.test // ""' 2>/dev/null)
            if [[ -n "$has_test" && "$has_test" != "null" && "$has_test" != *"no test specified"* ]]; then
                TEST_CMD="$PACKAGE_MANAGER test"
            fi
        fi

        local has_build
        has_build=$(echo "$scripts_json" | jq -r '.build // ""' 2>/dev/null)
        if [[ -n "$has_build" && "$has_build" != "null" ]]; then
            BUILD_CMD="$PACKAGE_MANAGER run build"
        fi

        local has_lint
        has_lint=$(echo "$scripts_json" | jq -r '.lint // ""' 2>/dev/null)
        if [[ -n "$has_lint" && "$has_lint" != "null" ]]; then
            LINT_CMD="$PACKAGE_MANAGER run lint"
        fi

        local has_format
        has_format=$(echo "$scripts_json" | jq -r '.format // ""' 2>/dev/null)
        if [[ -n "$has_format" && "$has_format" != "null" ]]; then
            FORMAT_CMD="$PACKAGE_MANAGER run format"
        fi

        local has_dev
        has_dev=$(echo "$scripts_json" | jq -r '.dev // ""' 2>/dev/null)
        if [[ -n "$has_dev" && "$has_dev" != "null" ]]; then
            DEV_CMD="$PACKAGE_MANAGER run dev"
        fi

    elif [[ -f "$root/go.mod" ]]; then
        LANG_DETECTED="go"
        PACKAGE_MANAGER="go modules"
        TEST_CMD="go test ./..."
        BUILD_CMD="go build ./..."
        LINT_CMD="golangci-lint run"
        # Detect framework
        if grep -q "gin-gonic" "$root/go.mod" 2>/dev/null; then
            FRAMEWORK="gin"
        elif grep -q "labstack/echo" "$root/go.mod" 2>/dev/null; then
            FRAMEWORK="echo"
        elif grep -q "go-chi/chi" "$root/go.mod" 2>/dev/null; then
            FRAMEWORK="chi"
        elif grep -q "gofiber/fiber" "$root/go.mod" 2>/dev/null; then
            FRAMEWORK="fiber"
        fi

    elif [[ -f "$root/Cargo.toml" ]]; then
        LANG_DETECTED="rust"
        PACKAGE_MANAGER="cargo"
        TEST_CMD="cargo test"
        BUILD_CMD="cargo build"
        LINT_CMD="cargo clippy"
        FORMAT_CMD="cargo fmt"
        if grep -q "actix-web" "$root/Cargo.toml" 2>/dev/null; then
            FRAMEWORK="actix-web"
        elif grep -q "axum" "$root/Cargo.toml" 2>/dev/null; then
            FRAMEWORK="axum"
        elif grep -q "rocket" "$root/Cargo.toml" 2>/dev/null; then
            FRAMEWORK="rocket"
        fi

    elif [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/requirements.txt" ]]; then
        LANG_DETECTED="python"
        if [[ -f "$root/pyproject.toml" ]]; then
            if grep -q "poetry" "$root/pyproject.toml" 2>/dev/null; then
                PACKAGE_MANAGER="poetry"
            elif grep -q "pdm" "$root/pyproject.toml" 2>/dev/null; then
                PACKAGE_MANAGER="pdm"
            else
                PACKAGE_MANAGER="pip"
            fi
        else
            PACKAGE_MANAGER="pip"
        fi

        # Detect framework
        local py_deps=""
        [[ -f "$root/requirements.txt" ]] && py_deps=$(cat "$root/requirements.txt")
        [[ -f "$root/pyproject.toml" ]] && py_deps="$py_deps$(cat "$root/pyproject.toml")"
        if echo "$py_deps" | grep -qi "django"; then
            FRAMEWORK="django"
        elif echo "$py_deps" | grep -qi "fastapi"; then
            FRAMEWORK="fastapi"
        elif echo "$py_deps" | grep -qi "flask"; then
            FRAMEWORK="flask"
        fi

        # Detect test command
        if [[ -f "$root/pyproject.toml" ]] && grep -q "pytest" "$root/pyproject.toml" 2>/dev/null; then
            TEST_CMD="pytest"
            TEST_FRAMEWORK="pytest"
        elif [[ -d "$root/tests" ]]; then
            TEST_CMD="pytest"
            TEST_FRAMEWORK="pytest"
        fi
        LINT_CMD="ruff check ."
        FORMAT_CMD="ruff format ."

    elif [[ -f "$root/Gemfile" ]]; then
        LANG_DETECTED="ruby"
        PACKAGE_MANAGER="bundler"
        if grep -q "rails" "$root/Gemfile" 2>/dev/null; then
            FRAMEWORK="rails"
            TEST_CMD="bundle exec rails test"
        fi
        if grep -q "rspec" "$root/Gemfile" 2>/dev/null; then
            TEST_CMD="bundle exec rspec"
            TEST_FRAMEWORK="rspec"
        else
            TEST_FRAMEWORK="minitest"
        fi
        LINT_CMD="bundle exec rubocop"

    elif [[ -f "$root/pom.xml" ]]; then
        LANG_DETECTED="java"
        PACKAGE_MANAGER="maven"
        TEST_CMD="mvn test"
        BUILD_CMD="mvn package"
        if grep -q "spring-boot" "$root/pom.xml" 2>/dev/null; then
            FRAMEWORK="spring-boot"
        fi

    elif [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]]; then
        LANG_DETECTED="java"
        PACKAGE_MANAGER="gradle"
        TEST_CMD="./gradlew test"
        BUILD_CMD="./gradlew build"
        if grep -q "spring-boot" "$root/build.gradle" 2>/dev/null || \
           grep -q "spring-boot" "$root/build.gradle.kts" 2>/dev/null; then
            FRAMEWORK="spring-boot"
        fi
    fi

    # ── Infra detection ──

    [[ -f "$root/Dockerfile" ]] && HAS_DOCKER=true
    [[ -f "$root/docker-compose.yml" || -f "$root/docker-compose.yaml" || -f "$root/compose.yml" ]] && HAS_COMPOSE=true
    [[ -d "$root/.github/workflows" ]] && HAS_CI=true
    [[ -f "$root/Makefile" ]] && HAS_MAKEFILE=true

    # Makefile fallbacks
    if $HAS_MAKEFILE; then
        [[ -z "$TEST_CMD" ]] && grep -q "^test:" "$root/Makefile" 2>/dev/null && TEST_CMD="make test"
        [[ -z "$BUILD_CMD" ]] && grep -q "^build:" "$root/Makefile" 2>/dev/null && BUILD_CMD="make build"
        [[ -z "$LINT_CMD" ]] && grep -q "^lint:" "$root/Makefile" 2>/dev/null && LINT_CMD="make lint"
    fi

    # Summary
    success "Stack: ${BOLD}${LANG_DETECTED:-unknown}${RESET}" \
        "${FRAMEWORK:+/ ${BOLD}${FRAMEWORK}${RESET}}" \
        "${PACKAGE_MANAGER:+(${DIM}${PACKAGE_MANAGER}${RESET})}"
}

# ─── prep_scan_structure ────────────────────────────────────────────────────

prep_scan_structure() {
    local root="$PROJECT_ROOT"
    info "Scanning project structure..."

    # Identify key directories
    local dirs=()
    for d in src lib app pkg cmd internal api routes controllers models views \
             components pages services utils helpers middleware schemas types; do
        [[ -d "$root/$d" ]] && dirs+=("$d")
    done
    SRC_DIRS="${dirs[*]:-}"

    # Test directories
    local tdirs=()
    for d in tests test spec __tests__ test_* *_test; do
        [[ -d "$root/$d" ]] && tdirs+=("$d")
    done
    TEST_DIRS="${tdirs[*]:-}"

    # Doc directories
    local ddirs=()
    for d in docs doc documentation wiki; do
        [[ -d "$root/$d" ]] && ddirs+=("$d")
    done
    DOC_DIRS="${ddirs[*]:-}"

    # Config files
    local configs=()
    for f in .env.example .env.sample .eslintrc.js .eslintrc.json .eslintrc.yml \
             .prettierrc .prettierrc.json tsconfig.json jest.config.js jest.config.ts \
             vitest.config.ts webpack.config.js vite.config.ts next.config.js \
             .babelrc babel.config.js tailwind.config.js postcss.config.js \
             pyproject.toml setup.cfg tox.ini .flake8 .pylintrc \
             .rubocop.yml .rspec Cargo.toml go.mod; do
        [[ -f "$root/$f" ]] && configs+=("$f")
    done
    CONFIG_FILES="${configs[*]:-}"

    # Entry points
    local entries=()
    for f in src/index.ts src/index.js src/main.ts src/main.js src/app.ts src/app.js \
             index.ts index.js app.ts app.js server.ts server.js \
             main.go cmd/main.go src/main.rs src/lib.rs \
             app.py main.py manage.py wsgi.py asgi.py \
             config.ru app.rb; do
        [[ -f "$root/$f" ]] && entries+=("$f")
    done
    ENTRY_POINTS="${entries[*]:-}"

    # File counts
    local src_ext="ts tsx js jsx py rb go rs java kt"
    SRC_FILE_COUNT=0
    TEST_FILE_COUNT=0
    for ext in $src_ext; do
        local count
        count=$(find "$root" -name "*.${ext}" -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' ')
        SRC_FILE_COUNT=$((SRC_FILE_COUNT + count))
    done

    # Count test files
    TEST_FILE_COUNT=$(find "$root" \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')

    # Total lines (approximation from source files)
    TOTAL_LINES=$(find "$root" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
        -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" \
        -not -path "*/target/*" 2>/dev/null -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')

    success "Found ${BOLD}${SRC_FILE_COUNT}${RESET} source files, ${BOLD}${TEST_FILE_COUNT}${RESET} test files (${DIM}~${TOTAL_LINES} lines${RESET})"
}

# ─── prep_extract_patterns ──────────────────────────────────────────────────

prep_extract_patterns() {
    local root="$PROJECT_ROOT"
    info "Extracting code patterns..."

    # ── Import style ──
    if [[ "$LANG_DETECTED" == "nodejs" || "$LANG_DETECTED" == "typescript" ]]; then
        local es_count cjs_count
        es_count=$( { grep -rl "^import " "$root/src" "$root/app" "$root/lib" 2>/dev/null || true; } | wc -l | tr -d ' ')
        cjs_count=$( { grep -rl "require(" "$root/src" "$root/app" "$root/lib" 2>/dev/null || true; } | wc -l | tr -d ' ')
        if [[ "$es_count" -gt "$cjs_count" ]]; then
            IMPORT_STYLE="ES modules (import/export)"
        elif [[ "$cjs_count" -gt 0 ]]; then
            IMPORT_STYLE="CommonJS (require/module.exports)"
        else
            IMPORT_STYLE="ES modules (import/export)"
        fi
    fi

    # ── Naming convention ──
    local camel_count snake_count
    camel_count=$( { grep -roh '[a-z][a-zA-Z]*(' "$root/src" "$root/app" "$root/lib" 2>/dev/null || true; } | grep -c '[a-z][A-Z]' 2>/dev/null || true)
    camel_count="${camel_count:-0}"
    snake_count=$( { grep -roh '[a-z_]*_[a-z]*(' "$root/src" "$root/app" "$root/lib" 2>/dev/null || true; } | wc -l 2>/dev/null | tr -d ' ')
    snake_count="${snake_count:-0}"
    if [[ "$camel_count" -gt "$snake_count" ]]; then
        NAMING_CONVENTION="camelCase"
    elif [[ "$snake_count" -gt "$camel_count" ]]; then
        NAMING_CONVENTION="snake_case"
    else
        NAMING_CONVENTION="mixed"
    fi

    # ── Route patterns ──
    if grep -rq "app\.\(get\|post\|put\|delete\|patch\|use\)" "$root/src" "$root/app" "$root/routes" "$root/lib" 2>/dev/null; then
        HAS_ROUTES=true
        ROUTE_PATTERNS="Express-style (app.get/post/put/delete)"
    elif grep -rq "@app\.route\|@router\.\(get\|post\)" "$root/src" "$root/app" 2>/dev/null; then
        HAS_ROUTES=true
        ROUTE_PATTERNS="Decorator-style (@app.route / @router)"
    elif grep -rq "router\.\(GET\|POST\|PUT\|DELETE\)" "$root" 2>/dev/null; then
        HAS_ROUTES=true
        ROUTE_PATTERNS="Go-style router methods"
    fi

    # ── DB patterns ──
    if grep -rq "prisma\|PrismaClient" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="Prisma ORM"
    elif grep -rq "sequelize\|Sequelize" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="Sequelize ORM"
    elif grep -rq "mongoose\|Schema(" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="Mongoose (MongoDB)"
    elif grep -rq "typeorm\|TypeORM\|@Entity" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="TypeORM"
    elif grep -rq "drizzle\|drizzle-orm" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="Drizzle ORM"
    elif grep -rq "sqlalchemy\|SQLAlchemy" "$root/src" "$root/app" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="SQLAlchemy"
    elif grep -rq "pg\|Pool(" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_DB=true; DB_PATTERNS="pg (raw PostgreSQL)"
    fi

    # ── Middleware ──
    if grep -rq "app\.use(" "$root/src" "$root/app" "$root/lib" 2>/dev/null; then
        HAS_MIDDLEWARE=true
    fi

    success "Patterns: ${NAMING_CONVENTION} naming${IMPORT_STYLE:+, ${IMPORT_STYLE}}${ROUTE_PATTERNS:+, ${ROUTE_PATTERNS}}"
}

# ─── Intelligence Check ──────────────────────────────────────────────────

intelligence_available() {
    command -v claude &>/dev/null || return 1
    # Honor --with-claude flag
    $WITH_CLAUDE && return 0
    # Check daemon config for intelligence.enabled
    local config="${PROJECT_ROOT}/.claude/daemon-config.json"
    if [[ -f "$config" ]]; then
        local enabled
        enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
        [[ "$enabled" == "true" ]] && return 0
    fi
    return 1
}

# ─── prep_smart_detect — Claude-enhanced detection ────────────────────────

prep_smart_detect() {
    intelligence_available || return 0

    info "Running intelligent stack analysis..."

    # Collect dependency manifests (truncated)
    local dep_info=""
    local manifest
    for manifest in package.json requirements.txt Cargo.toml go.mod pyproject.toml Gemfile pom.xml build.gradle; do
        if [[ -f "$PROJECT_ROOT/$manifest" ]]; then
            dep_info+="=== ${manifest} ===
$(head -100 "$PROJECT_ROOT/$manifest" 2>/dev/null)

"
        fi
    done

    # Collect grep detection results summary
    local grep_results="Language: ${LANG_DETECTED:-unknown}
Framework: ${FRAMEWORK:-unknown}
Package Manager: ${PACKAGE_MANAGER:-unknown}
Test Framework: ${TEST_FRAMEWORK:-unknown}
Import Style: ${IMPORT_STYLE:-unknown}
Naming: ${NAMING_CONVENTION:-unknown}
Routes: ${ROUTE_PATTERNS:-none}
Database: ${DB_PATTERNS:-none}"

    # Sample code from entry points (first 50 lines of up to 3 files)
    local code_samples=""
    local sample_count=0
    local entry
    for entry in $ENTRY_POINTS; do
        [[ $sample_count -ge 3 ]] && break
        if [[ -f "$PROJECT_ROOT/$entry" ]]; then
            code_samples+="=== ${entry} (first 50 lines) ===
$(head -50 "$PROJECT_ROOT/$entry" 2>/dev/null)

"
            sample_count=$((sample_count + 1))
        fi
    done

    # If no entry points found, sample some source files
    if [[ $sample_count -eq 0 ]]; then
        local f
        while IFS= read -r f; do
            [[ $sample_count -ge 3 ]] && break
            [[ -z "$f" ]] && continue
            local relpath="${f#"$PROJECT_ROOT"/}"
            code_samples+="=== ${relpath} (first 50 lines) ===
$(head -50 "$f" 2>/dev/null)

"
            sample_count=$((sample_count + 1))
        done < <(find "$PROJECT_ROOT/src" "$PROJECT_ROOT/app" "$PROJECT_ROOT/lib" \
            \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.go' -o -name '*.rs' \) \
            -not -path "*/node_modules/*" 2>/dev/null | head -3)
    fi

    # Sample route files if routes detected
    local route_samples=""
    if $HAS_ROUTES; then
        local route_count=0
        local f
        while IFS= read -r f; do
            [[ $route_count -ge 2 ]] && break
            [[ -z "$f" ]] && continue
            local relpath="${f#"$PROJECT_ROOT"/}"
            route_samples+="=== ${relpath} (first 40 lines) ===
$(head -40 "$f" 2>/dev/null)

"
            route_count=$((route_count + 1))
        done < <(find "$PROJECT_ROOT/src" "$PROJECT_ROOT/app" "$PROJECT_ROOT/routes" "$PROJECT_ROOT/lib" \
            \( -name '*route*' -o -name '*controller*' -o -name '*handler*' -o -name '*endpoint*' \) \
            -not -path "*/node_modules/*" 2>/dev/null | head -2)
    fi

    # Sample style from up to 10 source files (first 20 lines each)
    local style_samples=""
    local style_count=0
    local f
    while IFS= read -r f; do
        [[ $style_count -ge 10 ]] && break
        [[ -z "$f" ]] && continue
        local relpath="${f#"$PROJECT_ROOT"/}"
        style_samples+="=== ${relpath} (first 20 lines) ===
$(head -20 "$f" 2>/dev/null)

"
        style_count=$((style_count + 1))
    done < <(find "$PROJECT_ROOT/src" "$PROJECT_ROOT/app" "$PROJECT_ROOT/lib" \
        \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.rb' -o -name '*.java' \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -10)

    [[ -z "$dep_info" && -z "$code_samples" && -z "$style_samples" ]] && return 0

    local prompt
    prompt="Analyze this project and respond in EXACTLY this format (one value per line, no extra text):
PRIMARY_LANGUAGE: <language>
FRAMEWORK: <framework or none>
ARCHITECTURE: <monolith|microservice|serverless|CLI|library>
TEST_FRAMEWORK: <test framework or unknown>
CI_SYSTEM: <CI system or unknown>
IMPORT_STYLE: <ESM|CJS|mixed|N/A>
NAMING: <camelCase|snake_case|PascalCase|kebab-case|mixed>
SEMICOLONS: <yes|no|N/A>
QUOTE_STYLE: <single|double|mixed|N/A>
INDENT: <spaces-2|spaces-4|tabs|mixed>
ROUTE_STYLE: <description of routing pattern or none>
DB_PATTERN: <description of database access pattern or none>

Detected so far by grep:
${grep_results}

Dependencies:
${dep_info}
Code samples:
${code_samples}
${route_samples:+Route files:
${route_samples}}
Style samples (analyze imports, naming, code style):
${style_samples}"

    local analysis
    analysis=$(claude --print "$prompt" 2>/dev/null || true)

    [[ -z "$analysis" ]] && { warn "Smart detection returned empty — using grep results"; return 0; }

    # Parse and enrich (only override gaps — grep results take priority)
    local smart_val

    smart_val=$(echo "$analysis" | grep "^FRAMEWORK:" | sed 's/^FRAMEWORK:[[:space:]]*//' | head -1)
    if [[ -n "$smart_val" && "$smart_val" != "none" && "$smart_val" != "unknown" && -z "$FRAMEWORK" ]]; then
        FRAMEWORK="$smart_val"
    fi

    smart_val=$(echo "$analysis" | grep "^TEST_FRAMEWORK:" | sed 's/^TEST_FRAMEWORK:[[:space:]]*//' | head -1)
    if [[ -n "$smart_val" && "$smart_val" != "unknown" && -z "$TEST_FRAMEWORK" ]]; then
        TEST_FRAMEWORK="$smart_val"
    fi

    smart_val=$(echo "$analysis" | grep "^IMPORT_STYLE:" | sed 's/^IMPORT_STYLE:[[:space:]]*//' | head -1)
    if [[ -n "$smart_val" && "$smart_val" != "N/A" ]]; then
        case "$smart_val" in
            ESM)   IMPORT_STYLE="ES modules (import/export)" ;;
            CJS)   IMPORT_STYLE="CommonJS (require/module.exports)" ;;
            mixed) IMPORT_STYLE="Mixed (ESM + CJS)" ;;
        esac
    fi

    smart_val=$(echo "$analysis" | grep "^NAMING:" | sed 's/^NAMING:[[:space:]]*//' | head -1)
    if [[ -n "$smart_val" && "$smart_val" != "mixed" && "$smart_val" != "unknown" ]]; then
        NAMING_CONVENTION="$smart_val"
    fi

    smart_val=$(echo "$analysis" | grep "^ARCHITECTURE:" | sed 's/^ARCHITECTURE:[[:space:]]*//' | head -1)
    ARCHITECTURE_PATTERN="${smart_val:-}"

    smart_val=$(echo "$analysis" | grep "^ROUTE_STYLE:" | sed 's/^ROUTE_STYLE:[[:space:]]*//' | head -1)
    if [[ -n "$smart_val" && "$smart_val" != "none" && -z "$ROUTE_PATTERNS" ]]; then
        HAS_ROUTES=true
        ROUTE_PATTERNS="$smart_val"
    fi

    smart_val=$(echo "$analysis" | grep "^DB_PATTERN:" | sed 's/^DB_PATTERN:[[:space:]]*//' | head -1)
    if [[ -n "$smart_val" && "$smart_val" != "none" && -z "$DB_PATTERNS" ]]; then
        HAS_DB=true
        DB_PATTERNS="$smart_val"
    fi

    SEMICOLONS=$(echo "$analysis" | grep "^SEMICOLONS:" | sed 's/^SEMICOLONS:[[:space:]]*//' | head -1)
    QUOTE_STYLE=$(echo "$analysis" | grep "^QUOTE_STYLE:" | sed 's/^QUOTE_STYLE:[[:space:]]*//' | head -1)
    INDENT_STYLE=$(echo "$analysis" | grep "^INDENT:" | sed 's/^INDENT:[[:space:]]*//' | head -1)

    success "Smart detection: ${ARCHITECTURE_PATTERN:-unknown} architecture${FRAMEWORK:+, ${FRAMEWORK}}"
}

# ─── prep_learn_patterns — Record detected patterns per repo ──────────────

prep_learn_patterns() {
    intelligence_available || return 0

    local repo_hash
    repo_hash=$(compute_md5 --string "$PROJECT_ROOT" || echo "default")

    local baselines_dir="${HOME}/.shipwright/baselines/${repo_hash}"
    mkdir -p "$baselines_dir"

    local patterns_file="${baselines_dir}/file-patterns.json"

    # Detect test file patterns present in this repo
    local test_patterns="[]"
    if find "$PROJECT_ROOT" -name "*.test.*" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -1 | grep -q .; then
        test_patterns=$(echo "$test_patterns" | jq '. + ["*.test.*"]')
    fi
    if find "$PROJECT_ROOT" -name "*.spec.*" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -1 | grep -q .; then
        test_patterns=$(echo "$test_patterns" | jq '. + ["*.spec.*"]')
    fi
    if find "$PROJECT_ROOT" -name "*_test.*" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -1 | grep -q .; then
        test_patterns=$(echo "$test_patterns" | jq '. + ["*_test.*"]')
    fi
    if find "$PROJECT_ROOT" -name "test_*" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -1 | grep -q .; then
        test_patterns=$(echo "$test_patterns" | jq '. + ["test_*"]')
    fi

    # Build config file list
    local config_json="[]"
    local f
    for f in $CONFIG_FILES; do
        config_json=$(echo "$config_json" | jq --arg f "$f" '. + [$f]')
    done

    # Build entry points list
    local entry_json="[]"
    for f in $ENTRY_POINTS; do
        entry_json=$(echo "$entry_json" | jq --arg f "$f" '. + [$f]')
    done

    # Write patterns file atomically
    local tmp_patterns
    tmp_patterns=$(mktemp)
    trap "rm -f '$tmp_patterns'" RETURN
    jq -n \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg lang "${LANG_DETECTED:-}" \
        --arg framework "${FRAMEWORK:-}" \
        --arg naming "${NAMING_CONVENTION:-}" \
        --arg imports "${IMPORT_STYLE:-}" \
        --arg arch "${ARCHITECTURE_PATTERN:-}" \
        --argjson test_patterns "$test_patterns" \
        --argjson config_files "$config_json" \
        --argjson entry_points "$entry_json" \
        '{
            updated_at: $ts,
            language: $lang,
            framework: $framework,
            architecture: $arch,
            naming_convention: $naming,
            import_style: $imports,
            test_file_patterns: $test_patterns,
            config_files: $config_files,
            entry_points: $entry_points
        }' > "$tmp_patterns" 2>/dev/null && mv "$tmp_patterns" "$patterns_file" || rm -f "$tmp_patterns"

    success "Learned file patterns → ${patterns_file##"$HOME"/}"
}

# ─── prep_generate_claude_md ────────────────────────────────────────────────

prep_generate_claude_md() {
    local filepath="$PROJECT_ROOT/.claude/CLAUDE.md"
    if ! should_write "$filepath"; then return; fi

    info "Generating .claude/CLAUDE.md..."

    # Build structure summary
    local structure=""
    if [[ -n "$SRC_DIRS" ]]; then
        structure+="### Source Directories\n"
        for d in $SRC_DIRS; do
            structure+="- \`${d}/\`\n"
        done
    fi
    if [[ -n "$TEST_DIRS" ]]; then
        structure+="\n### Test Directories\n"
        for d in $TEST_DIRS; do
            structure+="- \`${d}/\`\n"
        done
    fi

    # Build conventions
    local conventions=""
    [[ -n "$NAMING_CONVENTION" ]] && conventions+="- Naming: ${NAMING_CONVENTION}\n"
    [[ -n "$IMPORT_STYLE" ]] && conventions+="- Imports: ${IMPORT_STYLE}\n"
    [[ -n "$ROUTE_PATTERNS" ]] && conventions+="- Routes: ${ROUTE_PATTERNS}\n"
    [[ -n "$DB_PATTERNS" ]] && conventions+="- Database: ${DB_PATTERNS}\n"

    # Build important files
    local important=""
    if [[ -n "$ENTRY_POINTS" ]]; then
        for f in $ENTRY_POINTS; do
            important+="- \`${f}\`\n"
        done
    fi
    if [[ -n "$CONFIG_FILES" ]]; then
        for f in $CONFIG_FILES; do
            important+="- \`${f}\`\n"
        done
    fi

    local content
    content="<!-- sw:auto-start -->
# Project: ${PROJECT_NAME}

## Stack
- Language: ${LANG_DETECTED:-unknown}
- Framework: ${FRAMEWORK:-none detected}
- Package Manager: ${PACKAGE_MANAGER:-unknown}
- Test Framework: ${TEST_FRAMEWORK:-unknown}

## Commands
- Build: \`${BUILD_CMD:-N/A}\`
- Test: \`${TEST_CMD:-N/A}\`
- Lint: \`${LINT_CMD:-N/A}\`
- Format: \`${FORMAT_CMD:-N/A}\`
- Dev: \`${DEV_CMD:-N/A}\`

## Structure
$(echo -e "$structure")

## Conventions
$(echo -e "$conventions")

## Important Files
$(echo -e "$important")
<!-- sw:auto-end -->"

    update_auto_section "$filepath" "$content"
    track_file "$filepath"
    success "Generated .claude/CLAUDE.md"
}

# ─── prep_generate_settings ─────────────────────────────────────────────────

prep_generate_settings() {
    local filepath="$PROJECT_ROOT/.claude/settings.json"
    if ! should_write "$filepath"; then return; fi

    info "Generating .claude/settings.json..."

    # Build allow list using jq for proper JSON escaping
    local allow_json='[]'
    allow_json=$(echo "$allow_json" | jq '. + ["Read(***)","Edit(***)","Write(***)"]')
    [[ -n "$TEST_CMD" ]] && allow_json=$(echo "$allow_json" | jq --arg cmd "Bash($TEST_CMD)" '. + [$cmd]')
    [[ -n "$LINT_CMD" ]] && allow_json=$(echo "$allow_json" | jq --arg cmd "Bash($LINT_CMD)" '. + [$cmd]')
    [[ -n "$BUILD_CMD" ]] && allow_json=$(echo "$allow_json" | jq --arg cmd "Bash($BUILD_CMD)" '. + [$cmd]')
    [[ -n "$FORMAT_CMD" ]] && allow_json=$(echo "$allow_json" | jq --arg cmd "Bash($FORMAT_CMD)" '. + [$cmd]')
    allow_json=$(echo "$allow_json" | jq '. + ["Bash(git *)"]')

    jq -n --argjson allow "$allow_json" '{ permissions: { allow: $allow } }' > "$filepath"

    # Validate JSON
    if ! jq empty "$filepath" 2>/dev/null; then
        warn "settings.json has invalid JSON — check manually"
    fi

    track_file "$filepath"
    success "Generated .claude/settings.json"
}

# ─── prep_generate_hooks ────────────────────────────────────────────────────

prep_generate_hooks() {
    # Pre-build hook
    local pre_build="$PROJECT_ROOT/.claude/hooks/pre-build.sh"
    if should_write "$pre_build"; then
        info "Generating hooks..."

        cat > "$pre_build" <<'HOOKEOF'
#!/usr/bin/env bash
# Pre-build hook: run linter before building
set -euo pipefail

HOOKEOF

        if [[ -n "$LINT_CMD" ]]; then
            cat >> "$pre_build" <<HOOKEOF
echo "Running lint check..."
${LINT_CMD} || {
    echo "Lint failed — fix issues before building"
    exit 1
}
echo "Lint passed"
HOOKEOF
        else
            cat >> "$pre_build" <<'HOOKEOF'
echo "No lint command configured — skipping pre-build check"
HOOKEOF
        fi

        chmod +x "$pre_build"
        track_file "$pre_build"
    fi

    # Post-test hook
    local post_test="$PROJECT_ROOT/.claude/hooks/post-test.sh"
    if should_write "$post_test"; then
        cat > "$post_test" <<'HOOKEOF'
#!/usr/bin/env bash
# Post-test hook: check for common issues after test runs
set -euo pipefail

# Check for leftover console.log / print debugging
DEBUGGING_STMTS=$(grep -rn "console\.log\|debugger\|print(" src/ app/ lib/ 2>/dev/null | grep -v node_modules | grep -v ".test." | grep -v ".spec." || true)
if [[ -n "$DEBUGGING_STMTS" ]]; then
    echo "Warning: Found debugging statements:"
    echo "$DEBUGGING_STMTS" | head -10
fi

echo "Post-test checks complete"
HOOKEOF

        chmod +x "$post_test"
        track_file "$post_test"
    fi

    success "Generated hook scripts"
}

# ─── prep_generate_agents ───────────────────────────────────────────────────

prep_generate_agents() {
    info "Generating agent definitions..."

    # Backend agent
    local backend="$PROJECT_ROOT/.claude/agents/backend.md"
    if should_write "$backend"; then
        cat > "$backend" <<AGENTEOF
# Backend Agent

## Role
You are a backend specialist working on **${PROJECT_NAME}**.

## Stack
- Language: ${LANG_DETECTED:-unknown}
- Framework: ${FRAMEWORK:-none}
- Database: ${DB_PATTERNS:-none detected}

## Focus Areas
- API endpoints and route handlers
- Business logic and data processing
- Database queries and migrations
- Authentication and authorization
- Error handling and validation

## Constraints
- Always write tests for new endpoints
- Follow existing patterns in the codebase
- Do not modify frontend files
- Use existing error handling patterns
- Run \`${TEST_CMD:-echo "no test cmd"}\` before marking work complete

## Key Directories
$(for d in $SRC_DIRS; do echo "- \`${d}/\`"; done)
AGENTEOF
        track_file "$backend"
    fi

    # Frontend agent (only if frontend-ish framework detected)
    if [[ "$FRAMEWORK" == "react" || "$FRAMEWORK" == "vue" || "$FRAMEWORK" == "angular" || \
          "$FRAMEWORK" == "next.js" || "$FRAMEWORK" == "nuxt" ]]; then
        local frontend="$PROJECT_ROOT/.claude/agents/frontend.md"
        if should_write "$frontend"; then
            cat > "$frontend" <<AGENTEOF
# Frontend Agent

## Role
You are a frontend specialist working on **${PROJECT_NAME}**.

## Stack
- Framework: ${FRAMEWORK}
- Language: ${LANG_DETECTED}

## Focus Areas
- UI components and layouts
- State management
- Client-side routing
- Form handling and validation
- Styling and responsiveness
- Accessibility (a11y)

## Constraints
- Follow existing component patterns
- Do not modify backend/API files
- Write unit tests for components
- Ensure responsive design
- Run \`${TEST_CMD:-echo "no test cmd"}\` before marking work complete

## Key Directories
$(for d in components pages views app src/components src/pages; do
    [[ -d "$PROJECT_ROOT/$d" ]] && echo "- \`${d}/\`"
done)
AGENTEOF
            track_file "$frontend"
        fi
    fi

    # Tester agent
    local tester="$PROJECT_ROOT/.claude/agents/tester.md"
    if should_write "$tester"; then
        cat > "$tester" <<AGENTEOF
# Tester Agent

## Role
You are a testing specialist working on **${PROJECT_NAME}**.

## Stack
- Test Framework: ${TEST_FRAMEWORK:-unknown}
- Test Command: \`${TEST_CMD:-N/A}\`

## Focus Areas
- Unit tests for all new functions and methods
- Integration tests for API endpoints
- Edge case coverage
- Error path testing
- Test data fixtures and factories

## Constraints
- Write real tests, not mocked pass-throughs
- Test both happy paths and error paths
- Follow existing test patterns and naming conventions
- Maintain or improve code coverage
- Do not modify source code — only test files

## Test Directories
$(for d in $TEST_DIRS; do echo "- \`${d}/\`"; done)
$(if [[ -z "$TEST_DIRS" ]]; then echo "- Tests colocated with source files"; fi)

## Running Tests
\`\`\`bash
${TEST_CMD:-# No test command detected}
\`\`\`
AGENTEOF
        track_file "$tester"
    fi

    success "Generated agent definitions"
}

# ─── prep_generate_architecture ─────────────────────────────────────────────

prep_generate_architecture() {
    local filepath="$PROJECT_ROOT/.claude/ARCHITECTURE.md"
    if ! should_write "$filepath"; then return; fi

    info "Generating .claude/ARCHITECTURE.md..."

    # Build module map
    local module_map=""
    for d in $SRC_DIRS; do
        local file_count
        file_count=$(find "$PROJECT_ROOT/$d" -type f -not -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')
        module_map+="- \`${d}/\` — ${file_count} files\n"
    done

    # Key dependencies
    local deps_section=""
    if [[ -f "$PROJECT_ROOT/package.json" ]]; then
        local dep_names
        dep_names=$(jq -r '.dependencies // {} | keys[]' "$PROJECT_ROOT/package.json" 2>/dev/null | head -15)
        if [[ -n "$dep_names" ]]; then
            deps_section="## Dependencies\n"
            while IFS= read -r dep; do
                deps_section+="- \`${dep}\`\n"
            done <<< "$dep_names"
        fi
    elif [[ -f "$PROJECT_ROOT/go.mod" ]]; then
        local go_deps
        go_deps=$( { grep "^\t" "$PROJECT_ROOT/go.mod" 2>/dev/null || true; } | awk '{print $1}' | head -15)
        if [[ -n "$go_deps" ]]; then
            deps_section="## Dependencies\n"
            while IFS= read -r dep; do
                deps_section+="- \`${dep}\`\n"
            done <<< "$go_deps"
        fi
    fi

    # Data flow
    local data_flow=""
    if $HAS_ROUTES && $HAS_DB; then
        data_flow="## Data Flow\n"
        data_flow+="Request → ${ROUTE_PATTERNS:-Router} → Handler → ${DB_PATTERNS:-Database} → Response\n"
    elif $HAS_ROUTES; then
        data_flow="## Data Flow\n"
        data_flow+="Request → ${ROUTE_PATTERNS:-Router} → Handler → Response\n"
    fi

    # Pre-compute entry points section
    local entry_section=""
    if [[ -n "$ENTRY_POINTS" ]]; then
        for f in $ENTRY_POINTS; do
            entry_section+="- \`${f}\`"$'\n'
        done
    else
        entry_section="- No standard entry points detected"$'\n'
    fi

    # Pre-compute module map section
    local module_section=""
    if [[ -n "$module_map" ]]; then
        module_section=$(echo -e "$module_map")
    else
        module_section="No standard module directories detected."
    fi

    # Pre-compute infrastructure section
    local infra_section=""
    $HAS_DOCKER && infra_section+="- Docker: Dockerfile present"$'\n'
    $HAS_COMPOSE && infra_section+="- Docker Compose: multi-service setup"$'\n'
    $HAS_CI && infra_section+="- CI/CD: GitHub Actions workflows"$'\n'
    $HAS_MAKEFILE && infra_section+="- Makefile: build automation"$'\n'
    if [[ -z "$infra_section" ]]; then
        infra_section="- No infrastructure files detected"$'\n'
    fi

    local content
    content="<!-- sw:auto-start -->
# Architecture

## Overview
**${PROJECT_NAME}** is a ${LANG_DETECTED:-unknown}${FRAMEWORK:+ / ${FRAMEWORK}} project with ${SRC_FILE_COUNT} source files and ~${TOTAL_LINES} lines of code.

## Entry Points
${entry_section}
## Module Map
${module_section}

$(echo -e "${deps_section}")

$(echo -e "${data_flow}")

## Infrastructure
${infra_section}<!-- sw:auto-end -->"

    update_auto_section "$filepath" "$content"
    track_file "$filepath"
    success "Generated .claude/ARCHITECTURE.md"
}

# ─── prep_generate_standards ────────────────────────────────────────────────

prep_generate_standards() {
    local filepath="$PROJECT_ROOT/.claude/CODING-STANDARDS.md"
    if ! should_write "$filepath"; then return; fi

    info "Generating .claude/CODING-STANDARDS.md..."

    local file_org=""
    if [[ -n "${SRC_DIRS:-}" ]]; then
        file_org+="- Source code: \`${SRC_DIRS}\`"$'\n'
    fi
    if [[ -n "${TEST_DIRS:-}" ]]; then
        file_org+="- Tests: \`${TEST_DIRS}\`"$'\n'
    fi

    local content
    content="<!-- sw:auto-start -->
# Coding Standards

## Naming
- Convention: **${NAMING_CONVENTION:-not detected}**
- Files: follow existing file naming patterns in the project
- Variables/functions: use **${NAMING_CONVENTION:-mixed}** style consistently

## Imports
- Style: **${IMPORT_STYLE:-follow existing patterns}**
- Keep imports organized: stdlib → external deps → internal modules

## Error Handling
- Use the existing error handling patterns
- Always handle promise rejections / async errors
- Provide meaningful error messages
- Do not swallow errors silently

## Testing
- Framework: **${TEST_FRAMEWORK:-unknown}**
- Write tests for all new functionality
- Test both success and error paths
- Use descriptive test names
- Keep tests focused — one assertion per test where practical

## File Organization
${file_org}- Follow the existing directory structure — do not create new top-level dirs without discussion
<!-- sw:auto-end -->"

    update_auto_section "$filepath" "$content"
    track_file "$filepath"
    success "Generated .claude/CODING-STANDARDS.md"
}

# ─── prep_generate_dod ──────────────────────────────────────────────────────

prep_generate_dod() {
    local filepath="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"
    if ! should_write "$filepath"; then return; fi

    info "Generating .claude/DEFINITION-OF-DONE.md..."

    cat > "$filepath" <<HEREDOC
# Definition of Done

## Code Quality
- [ ] All tests pass (\`${TEST_CMD:-N/A}\`)
$(if [[ -n "$LINT_CMD" ]]; then echo "- [ ] Lint passes (\`${LINT_CMD}\`)"; fi)
$(if [[ -n "$BUILD_CMD" ]]; then echo "- [ ] Build succeeds (\`${BUILD_CMD}\`)"; fi)
- [ ] No console.log/print debugging left in code
- [ ] Error handling for edge cases

## Testing
- [ ] Unit tests for new functions
- [ ] Integration tests for new endpoints/features
- [ ] Error paths tested
- [ ] Edge cases covered

## Documentation
- [ ] Code comments for complex logic
- [ ] README updated if API changes

## Git
- [ ] Clean commit history
- [ ] Branch naming follows convention
- [ ] No unresolved merge conflicts
- [ ] PR description explains the "why"
HEREDOC

    track_file "$filepath"
    success "Generated .claude/DEFINITION-OF-DONE.md"
}

# ─── prep_generate_issue_templates ──────────────────────────────────────────

prep_generate_issue_templates() {
    local filepath="$PROJECT_ROOT/.github/ISSUE_TEMPLATE/agent-task.md"
    if ! should_write "$filepath"; then return; fi

    info "Generating issue template..."

    cat > "$filepath" <<'HEREDOC'
---
name: Agent Task
about: Structured task for autonomous agent execution
labels: ready-to-build
---

## Goal
<!-- One clear sentence describing what needs to happen -->

## Context
<!-- Background information, related issues, user requirements -->

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Technical Notes
<!-- Implementation hints, files to modify, constraints -->

## Definition of Done
- [ ] All existing tests pass
- [ ] New tests added for new functionality
- [ ] Code reviewed (adversarial + negative prompting)
- [ ] No lint errors
HEREDOC

    track_file "$filepath"
    success "Generated .github/ISSUE_TEMPLATE/agent-task.md"
}

# ─── prep_generate_manifest ─────────────────────────────────────────────────

prep_generate_manifest() {
    local filepath="$PROJECT_ROOT/.claude/prep-manifest.json"
    info "Writing manifest..."

    local files_json="{"
    local first=true
    if [[ ${#GENERATED_FILES[@]} -gt 0 ]]; then
        for entry in "${GENERATED_FILES[@]}"; do
            local fname flines
            fname="${entry%%|*}"
            flines="${entry##*|}"
            local checksum
            checksum=$(compute_md5 "$PROJECT_ROOT/$fname" || echo "unknown")
            if $first; then
                first=false
            else
                files_json+=","
            fi
            files_json+="
    \"${fname}\": { \"checksum\": \"${checksum}\", \"lines\": ${flines} }"
        done
    fi
    files_json+="
  }"

    cat > "$filepath" <<HEREDOC
{
  "version": 1,
  "generated_at": "$(now_iso)",
  "stack": {
    "lang": "${LANG_DETECTED:-unknown}",
    "framework": "${FRAMEWORK:-none}",
    "test": "${TEST_FRAMEWORK:-unknown}",
    "package_manager": "${PACKAGE_MANAGER:-unknown}"
  },
  "files": ${files_json}
}
HEREDOC

    # Validate JSON
    if command -v jq &>/dev/null; then
        if ! jq empty "$filepath" 2>/dev/null; then
            warn "prep-manifest.json may have invalid JSON — check manually"
        fi
    fi

    track_file "$filepath"
    success "Written prep-manifest.json"
}

# ─── prep_with_claude — Deep analysis using Claude Code ─────────────────────

prep_with_claude() {
    if ! $WITH_CLAUDE; then return; fi

    if ! command -v claude &>/dev/null; then
        warn "claude CLI not found — skipping deep analysis"
        return
    fi

    info "Running deep analysis with Claude Code..."

    local source_sample
    source_sample=$(find "$PROJECT_ROOT/src" "$PROJECT_ROOT/app" "$PROJECT_ROOT/lib" \
        -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.go' -o -name '*.rs' \
        2>/dev/null | head -20 | xargs cat 2>/dev/null | head -500 || true)

    if [[ -z "$source_sample" ]]; then
        warn "No source files found for deep analysis"
        return
    fi

    local analysis
    analysis=$(claude --print "Analyze this ${LANG_DETECTED:-} / ${FRAMEWORK:-} repository and provide:
1. A 2-3 sentence architecture overview
2. Key patterns and conventions you observe
3. Potential pitfalls for developers new to this codebase
4. Suggested focus areas for code quality

Source sample:
${source_sample}" 2>/dev/null || true)

    if [[ -n "$analysis" ]]; then
        local filepath="$PROJECT_ROOT/.claude/DEEP-ANALYSIS.md"
        cat > "$filepath" <<HEREDOC
# Deep Analysis (Claude-generated)

_Generated at $(now_iso)_

${analysis}
HEREDOC
        track_file "$filepath"
        success "Generated .claude/DEEP-ANALYSIS.md"
    else
        warn "Claude analysis returned empty — skipping"
    fi
}

# ─── prep_validate — Validate generated files ──────────────────────────────

prep_validate() {
    local issues=0

    # Check JSON files
    if command -v jq &>/dev/null; then
        for f in "$PROJECT_ROOT/.claude/settings.json" "$PROJECT_ROOT/.claude/prep-manifest.json"; do
            if [[ -f "$f" ]] && ! jq empty "$f" 2>/dev/null; then
                warn "Invalid JSON: ${f##"$PROJECT_ROOT"/}"
                issues=$((issues + 1))
            fi
        done
    fi

    # Check markdown files aren't empty
    for f in "$PROJECT_ROOT/.claude/CLAUDE.md" "$PROJECT_ROOT/.claude/ARCHITECTURE.md" \
             "$PROJECT_ROOT/.claude/CODING-STANDARDS.md" "$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"; do
        if [[ -f "$f" ]]; then
            local lines
            lines=$(wc -l < "$f" | tr -d ' ')
            if [[ "$lines" -lt 3 ]]; then
                warn "Suspiciously short: ${f##"$PROJECT_ROOT"/} (${lines} lines)"
                issues=$((issues + 1))
            fi
        fi
    done

    # Check hooks are executable
    for f in "$PROJECT_ROOT/.claude/hooks/"*.sh; do
        if [[ -f "$f" ]] && [[ ! -x "$f" ]]; then
            warn "Hook not executable: ${f##"$PROJECT_ROOT"/}"
            chmod +x "$f"
            issues=$((issues + 1))
        fi
    done

    if [[ "$issues" -eq 0 ]]; then
        success "Validation passed — all files OK"
    else
        warn "Validation found ${issues} issue(s)"
    fi
}

# ─── prep_check — Audit mode ───────────────────────────────────────────────

prep_check() {
    echo -e "\n${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Prep Audit                                                       ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}\n"

    local score=0
    local total=0
    local missing=()

    # Check each expected file
    local expected_files=(
        ".claude/CLAUDE.md"
        ".claude/settings.json"
        ".claude/ARCHITECTURE.md"
        ".claude/CODING-STANDARDS.md"
        ".claude/DEFINITION-OF-DONE.md"
        ".claude/agents/backend.md"
        ".claude/agents/tester.md"
        ".claude/hooks/pre-build.sh"
        ".claude/hooks/post-test.sh"
        ".claude/prep-manifest.json"
        ".github/ISSUE_TEMPLATE/agent-task.md"
    )

    for f in "${expected_files[@]}"; do
        total=$((total + 1))
        if [[ -f "$PROJECT_ROOT/$f" ]]; then
            local lines
            lines=$(wc -l < "$PROJECT_ROOT/$f" | tr -d ' ')
            echo -e "  ${GREEN}${BOLD}✓${RESET} ${f} ${DIM}(${lines} lines)${RESET}"
            score=$((score + 1))

            # Check for auto markers in markdown files
            if [[ "$f" == *.md && "$f" != *"ISSUE_TEMPLATE"* && "$f" != *"DEFINITION-OF-DONE"* ]]; then
                if grep -q "<!-- sw:auto-start -->" "$PROJECT_ROOT/$f" 2>/dev/null; then
                    echo -e "    ${DIM}↳ Has auto-update markers${RESET}"
                else
                    echo -e "    ${YELLOW}↳ No auto-update markers (user-customized)${RESET}"
                fi
            fi
        else
            echo -e "  ${RED}${BOLD}✗${RESET} ${f} ${DIM}(missing)${RESET}"
            missing+=("$f")
        fi
    done

    # Report
    echo ""
    local pct=$((score * 100 / total))
    local grade
    if [[ $pct -ge 90 ]]; then grade="${GREEN}A${RESET}"
    elif [[ $pct -ge 75 ]]; then grade="${GREEN}B${RESET}"
    elif [[ $pct -ge 60 ]]; then grade="${YELLOW}C${RESET}"
    elif [[ $pct -ge 40 ]]; then grade="${YELLOW}D${RESET}"
    else grade="${RED}F${RESET}"
    fi

    echo -e "  ${BOLD}Score:${RESET} ${score}/${total} (${pct}%) — Grade: ${BOLD}${grade}${RESET}"

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Missing files:${RESET}"
        for f in "${missing[@]}"; do
            echo -e "    ${DIM}→ ${f}${RESET}"
        done
        echo ""
        echo -e "  ${DIM}Run ${CYAN}shipwright prep${DIM} to generate missing files${RESET}"
    fi
    echo ""
}

# ─── prep_report — Summary output ──────────────────────────────────────────

prep_report() {
    echo ""
    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Prep Complete                                                    ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Stack:${RESET}      ${LANG_DETECTED:-unknown}${FRAMEWORK:+ / ${FRAMEWORK}}${TEST_FRAMEWORK:+ / ${TEST_FRAMEWORK}}"
    echo -e "  ${BOLD}Files:${RESET}      ${#GENERATED_FILES[@]} generated"
    echo ""
    echo -e "  ${BOLD}Created:${RESET}"
    if [[ ${#GENERATED_FILES[@]} -gt 0 ]]; then
    for entry in "${GENERATED_FILES[@]}"; do
        local fname flines
        fname="${entry%%|*}"
        flines="${entry##*|}"
        printf "    ${GREEN}${BOLD}✓${RESET} %-42s ${DIM}(%s lines)${RESET}\n" "$fname" "$flines"
    done
    fi
    echo ""
    echo -e "  ${DIM}Next steps:${RESET}"
    echo -e "    ${DIM}1. Review generated files and customize as needed${RESET}"
    echo -e "    ${DIM}2. Run ${CYAN}shipwright prep --check${DIM} to audit quality${RESET}"
    echo -e "    ${DIM}3. Content between auto markers can be refreshed with ${CYAN}shipwright prep --update${RESET}"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    # Banner
    echo -e "\n${CYAN}${BOLD}▸ shipwright prep${RESET} ${DIM}v${VERSION}${RESET}\n"

    # Init
    prep_init

    # Check-only mode
    if $CHECK_ONLY; then
        prep_check
        exit 0
    fi

    # Detection & analysis
    prep_detect_stack
    prep_scan_structure
    prep_extract_patterns

    # Smart detection (intelligence-gated)
    prep_smart_detect
    prep_learn_patterns

    # Generation
    prep_generate_claude_md
    prep_generate_settings
    prep_generate_hooks
    prep_generate_agents
    prep_generate_architecture
    prep_generate_standards
    prep_generate_dod
    prep_generate_issue_templates

    # Deep analysis (optional)
    prep_with_claude

    # Manifest & validation
    prep_generate_manifest
    prep_validate

    # Report
    prep_report
}

main
