#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/project-detect — Project type detection & template rec    ║
# ║  Auto-detect project language, framework, test command, and pipeline      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/project-detect.sh"
#   project_detect_type "/path/to/project"       # Returns JSON with type/framework/build/test
#   project_detect_all "/path/to/project"        # Full detection report
#   project_recommend_template "/path/to/project" # Returns JSON with template recommendation
#
# Provides:
#   - project_detect_type(root)         — Detect language + framework + package manager
#   - project_detect_framework(root, type) — Detect specific framework
#   - project_detect_test_cmd(root, type)  — Detect test command
#   - project_detect_build_cmd(root, type) — Detect build command
#   - project_recommend_template(root)  — Recommend pipeline template
#   - project_detect_all(root)          — Full detection report (cached)

[[ -n "${_PROJECT_DETECT_LOADED:-}" ]] && return 0
_PROJECT_DETECT_LOADED=1

# ─── Helper: Read JSON field safely ────────────────────────────────────────
_json_field() {
    local json="$1" field="$2"
    echo "$json" | jq -r ".${field} // empty" 2>/dev/null || echo ""
}

# ─── Helper: Count lines matching pattern ──────────────────────────────────
_count_pattern() {
    local pattern="$1" path="$2"
    grep -r "$pattern" "$path" 2>/dev/null | wc -l | tr -d ' '
}

# ─── Helper: Check file exists (safe for symlinks) ──────────────────────────
_has_file() {
    local root="$1" file="$2"
    [[ -f "$root/$file" ]]
}

# ─── Helper: Check any file matches glob ──────────────────────────────────
_has_glob() {
    local root="$1" pattern="$2"
    find "$root" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | grep -q .
}

# ─── Helper: Parse ISO 8601 timestamp to Unix seconds (cross-platform) ───────
_iso_to_unix() {
    local iso="$1"
    # Try Linux date -d first, fall back to macOS date -j
    date -d "$iso" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || echo 0
}

# ═══════════════════════════════════════════════════════════════════════════
# project_detect_type(root)
# ─────────────────────────────────────────────────────────────────────────────
# Detect primary language/type by checking for marker files in order
#
# Returns JSON: {
#   "type": "nodejs|python|rust|golang|ruby|java|dotnet|c|bash",
#   "framework": "react|next|express|django|actix|...|unknown",
#   "build_tool": "npm|yarn|cargo|go|...",
#   "test_runner": "jest|pytest|cargo test|..."
# }
project_detect_type() {
    local root="${1:-.}"
    [[ -d "$root" ]] || return 1

    local type="" framework="" build_tool="" test_runner=""

    # ── Node.js / JavaScript / TypeScript ──
    if _has_file "$root" "package.json"; then
        type="nodejs"

        # Detect package manager first
        if _has_file "$root" "pnpm-lock.yaml"; then
            build_tool="pnpm"
        elif _has_file "$root" "yarn.lock"; then
            build_tool="yarn"
        elif _has_file "$root" "bun.lockb"; then
            build_tool="bun"
        else
            build_tool="npm"
        fi

        # Detect framework and test runner from package.json
        local pkg
        pkg=$(cat "$root/package.json" 2>/dev/null)

        # Framework detection
        if echo "$pkg" | grep -q '"next"'; then
            framework="next"
        elif echo "$pkg" | grep -q '"react"'; then
            framework="react"
        elif echo "$pkg" | grep -q '"vue"'; then
            framework="vue"
        elif echo "$pkg" | grep -q '"@angular/core"'; then
            framework="angular"
        elif echo "$pkg" | grep -q '"@nestjs/core"'; then
            framework="nestjs"
        elif echo "$pkg" | grep -q '"express"'; then
            framework="express"
        elif echo "$pkg" | grep -q '"fastify"'; then
            framework="fastify"
        elif echo "$pkg" | grep -q '"hono"'; then
            framework="hono"
        else
            framework="unknown"
        fi

        # Test runner detection
        if echo "$pkg" | grep -q '"vitest"'; then
            test_runner="vitest"
        elif echo "$pkg" | grep -q '"jest"'; then
            test_runner="jest"
        elif echo "$pkg" | grep -q '"mocha"'; then
            test_runner="mocha"
        elif echo "$pkg" | grep -q '"ava"'; then
            test_runner="ava"
        else
            test_runner="unknown"
        fi

    # ── Rust ──
    elif _has_file "$root" "Cargo.toml"; then
        type="rust"
        build_tool="cargo"
        test_runner="cargo"

        local cargo_content
        cargo_content=$(cat "$root/Cargo.toml" 2>/dev/null)

        if echo "$cargo_content" | grep -q "actix-web"; then
            framework="actix-web"
        elif echo "$cargo_content" | grep -q "axum"; then
            framework="axum"
        elif echo "$cargo_content" | grep -q "rocket"; then
            framework="rocket"
        else
            framework="unknown"
        fi

    # ── Go ──
    elif _has_file "$root" "go.mod"; then
        type="golang"
        build_tool="go"
        test_runner="go test"

        local go_content
        go_content=$(cat "$root/go.mod" 2>/dev/null)

        if echo "$go_content" | grep -q "gin-gonic/gin"; then
            framework="gin"
        elif echo "$go_content" | grep -q "labstack/echo"; then
            framework="echo"
        elif echo "$go_content" | grep -q "go-chi/chi"; then
            framework="chi"
        elif echo "$go_content" | grep -q "gofiber/fiber"; then
            framework="fiber"
        else
            framework="unknown"
        fi

    # ── Python ──
    elif _has_file "$root" "pyproject.toml" || _has_file "$root" "setup.py" || _has_file "$root" "requirements.txt"; then
        type="python"
        test_runner="pytest"

        # Detect package manager
        if _has_file "$root" "pyproject.toml"; then
            local pyproject
            pyproject=$(cat "$root/pyproject.toml" 2>/dev/null)
            if echo "$pyproject" | grep -q "poetry"; then
                build_tool="poetry"
            elif echo "$pyproject" | grep -q "pdm"; then
                build_tool="pdm"
            else
                build_tool="pip"
            fi
        else
            build_tool="pip"
        fi

        # Framework detection
        local py_deps=""
        _has_file "$root" "requirements.txt" && py_deps=$(cat "$root/requirements.txt" 2>/dev/null)
        _has_file "$root" "pyproject.toml" && py_deps="$py_deps$(cat "$root/pyproject.toml" 2>/dev/null)"

        if echo "$py_deps" | grep -qi "django"; then
            framework="django"
        elif echo "$py_deps" | grep -qi "fastapi"; then
            framework="fastapi"
        elif echo "$py_deps" | grep -qi "flask"; then
            framework="flask"
        else
            framework="unknown"
        fi

    # ── Ruby ──
    elif _has_file "$root" "Gemfile"; then
        type="ruby"
        build_tool="bundler"

        local gemfile
        gemfile=$(cat "$root/Gemfile" 2>/dev/null)

        if echo "$gemfile" | grep -q "rails"; then
            framework="rails"
            test_runner="rails test"
        elif echo "$gemfile" | grep -q "rspec"; then
            framework="unknown"
            test_runner="rspec"
        else
            framework="unknown"
            test_runner="minitest"
        fi

    # ── Java ──
    elif _has_file "$root" "pom.xml"; then
        type="java"
        build_tool="maven"
        test_runner="maven"

        local pom
        pom=$(cat "$root/pom.xml" 2>/dev/null)

        if echo "$pom" | grep -q "spring-boot"; then
            framework="spring-boot"
        else
            framework="unknown"
        fi

    elif _has_file "$root" "build.gradle" || _has_file "$root" "build.gradle.kts"; then
        type="java"
        build_tool="gradle"
        test_runner="gradle"

        local gradle_content
        gradle_content=""
        _has_file "$root" "build.gradle" && gradle_content=$(cat "$root/build.gradle" 2>/dev/null)
        _has_file "$root" "build.gradle.kts" && gradle_content=$(cat "$root/build.gradle.kts" 2>/dev/null)

        if echo "$gradle_content" | grep -q "spring-boot"; then
            framework="spring-boot"
        else
            framework="unknown"
        fi

    # ── .NET ──
    elif _has_glob "$root" "*.sln" || _has_glob "$root" "*.csproj"; then
        type="dotnet"
        build_tool="dotnet"
        test_runner="dotnet test"
        framework="unknown"

    # ── C/C++ (Makefile only) ──
    elif _has_file "$root" "Makefile"; then
        type="c"
        build_tool="make"
        test_runner="make"
        framework="unknown"

    # ── Bash (shell scripts) ──
    else
        # Check if directory contains shell scripts
        local shell_count
        shell_count=$(find "$root" -maxdepth 2 -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$shell_count" -gt 0 ]]; then
            type="bash"
            build_tool="bash"
            test_runner="bash"
            framework="unknown"
        fi
    fi

    # Output JSON
    if [[ -n "$type" ]]; then
        jq -n \
            --arg type "$type" \
            --arg framework "${framework:-unknown}" \
            --arg build_tool "${build_tool:-unknown}" \
            --arg test_runner "${test_runner:-unknown}" \
            '{type: $type, framework: $framework, build_tool: $build_tool, test_runner: $test_runner}'
    else
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# project_detect_test_cmd(root, type)
# ─────────────────────────────────────────────────────────────────────────────
# Detect the test command to run based on project type
#
# Returns string like "npm test" or "pytest" or "cargo test"
project_detect_test_cmd() {
    local root="${1:-.}"
    local type="${2:-}"
    [[ -d "$root" ]] || return 1

    # If type not provided, detect it
    if [[ -z "$type" ]]; then
        local detection
        detection=$(project_detect_type "$root") || return 1
        type=$(_json_field "$detection" "type")
    fi

    local test_cmd=""

    case "$type" in
        nodejs)
            # Check package.json for test script
            if [[ -f "$root/package.json" ]]; then
                local has_test
                has_test=$(jq -r '.scripts.test // ""' "$root/package.json" 2>/dev/null || echo "")
                if [[ -n "$has_test" && "$has_test" != "null" && ! "$has_test" =~ "no test" ]]; then
                    # Determine package manager
                    if [[ -f "$root/pnpm-lock.yaml" ]]; then
                        test_cmd="pnpm test"
                    elif [[ -f "$root/yarn.lock" ]]; then
                        test_cmd="yarn test"
                    elif [[ -f "$root/bun.lockb" ]]; then
                        test_cmd="bun test"
                    else
                        test_cmd="npm test"
                    fi
                fi
            fi
            ;;

        python)
            if [[ -f "$root/pyproject.toml" ]] && grep -q "pytest" "$root/pyproject.toml" 2>/dev/null; then
                test_cmd="pytest"
            elif [[ -d "$root/tests" ]]; then
                test_cmd="pytest"
            elif [[ -f "$root/setup.cfg" ]] && grep -q "test_suite" "$root/setup.cfg" 2>/dev/null; then
                test_cmd="python -m unittest"
            fi
            ;;

        rust)
            test_cmd="cargo test"
            ;;

        golang)
            test_cmd="go test ./..."
            ;;

        ruby)
            if [[ -f "$root/Gemfile" ]]; then
                local gemfile
                gemfile=$(cat "$root/Gemfile" 2>/dev/null)
                if echo "$gemfile" | grep -q "rails"; then
                    test_cmd="bundle exec rails test"
                elif echo "$gemfile" | grep -q "rspec"; then
                    test_cmd="bundle exec rspec"
                else
                    test_cmd="bundle exec rake test"
                fi
            fi
            ;;

        java)
            if [[ -f "$root/pom.xml" ]]; then
                test_cmd="mvn test"
            elif [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]]; then
                test_cmd="./gradlew test"
            fi
            ;;

        dotnet)
            test_cmd="dotnet test"
            ;;

        c)
            if [[ -f "$root/Makefile" ]] && grep -q "^test:" "$root/Makefile" 2>/dev/null; then
                test_cmd="make test"
            fi
            ;;

        bash)
            # Look for test runner scripts
            if [[ -f "$root/package.json" ]]; then
                test_cmd="npm test"
            elif [[ -f "$root/scripts/run-tests.sh" ]]; then
                test_cmd="bash scripts/run-tests.sh"
            elif [[ -f "$root/Makefile" ]] && grep -q "^test:" "$root/Makefile" 2>/dev/null; then
                test_cmd="make test"
            fi
            ;;
    esac

    [[ -n "$test_cmd" ]] && echo "$test_cmd"
}

# ═══════════════════════════════════════════════════════════════════════════
# project_detect_build_cmd(root, type)
# ─────────────────────────────────────────────────────────────────────────────
# Detect the build command for the project
project_detect_build_cmd() {
    local root="${1:-.}"
    local type="${2:-}"
    [[ -d "$root" ]] || return 1

    # If type not provided, detect it
    if [[ -z "$type" ]]; then
        local detection
        detection=$(project_detect_type "$root") || return 1
        type=$(_json_field "$detection" "type")
    fi

    local build_cmd=""

    case "$type" in
        nodejs)
            if [[ -f "$root/package.json" ]]; then
                local has_build
                has_build=$(jq -r '.scripts.build // ""' "$root/package.json" 2>/dev/null || echo "")
                if [[ -n "$has_build" && "$has_build" != "null" ]]; then
                    if [[ -f "$root/pnpm-lock.yaml" ]]; then
                        build_cmd="pnpm run build"
                    elif [[ -f "$root/yarn.lock" ]]; then
                        build_cmd="yarn build"
                    elif [[ -f "$root/bun.lockb" ]]; then
                        build_cmd="bun run build"
                    else
                        build_cmd="npm run build"
                    fi
                fi
            fi
            ;;

        python)
            # Most Python projects don't need explicit build, just deps install
            build_cmd=""
            ;;

        rust)
            build_cmd="cargo build"
            ;;

        golang)
            build_cmd="go build ./..."
            ;;

        ruby)
            build_cmd=""
            ;;

        java)
            if [[ -f "$root/pom.xml" ]]; then
                build_cmd="mvn package"
            elif [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]]; then
                build_cmd="./gradlew build"
            fi
            ;;

        dotnet)
            build_cmd="dotnet build"
            ;;

        c)
            if [[ -f "$root/Makefile" ]]; then
                build_cmd="make build"
            fi
            ;;

        bash)
            build_cmd=""
            ;;
    esac

    [[ -n "$build_cmd" ]] && echo "$build_cmd"
}

# ═══════════════════════════════════════════════════════════════════════════
# project_recommend_template(root)
# ─────────────────────────────────────────────────────────────────────────────
# Recommend a pipeline template based on project analysis
#
# Returns JSON: {
#   "template": "fast|standard|full|deployed|cost-aware|hotfix",
#   "confidence": 0-100,
#   "reason": "explanation"
# }
project_recommend_template() {
    local root="${1:-.}"
    [[ -d "$root" ]] || return 1

    local template="" confidence=0 reason=""

    # Analyze project characteristics
    local src_file_count test_file_count has_docker has_compose has_ci has_k8s
    local has_deploy src_lines test_lines

    # Count source files
    src_file_count=$(find "$root" \
        \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
           -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" \
        -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' ')

    # Count test files
    test_file_count=$(find "$root" \
        \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')

    # Check infrastructure
    has_docker=$([[ -f "$root/Dockerfile" ]] && echo "true" || echo "false")
    has_compose=$([[ -f "$root/docker-compose.yml" || -f "$root/docker-compose.yaml" || -f "$root/compose.yml" ]] && echo "true" || echo "false")
    has_k8s=$([[ -f "$root/k8s.yaml" || -d "$root/k8s" || -d "$root/helm" ]] && echo "true" || echo "false")
    has_ci=$([[ -d "$root/.github/workflows" || -f "$root/.gitlab-ci.yml" || -f "$root/Jenkinsfile" ]] && echo "true" || echo "false")
    has_deploy=$([[ "$has_docker" == "true" || "$has_k8s" == "true" || "$has_compose" == "true" ]] && echo "true" || echo "false")

    # Count lines (rough estimate)
    src_lines=$(find "$root" \
        \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
           -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" \
        -not -path "*/target/*" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')

    # Heuristics for template recommendation
    if [[ "$src_file_count" -lt 20 && "$test_file_count" -lt 5 && "$has_deploy" == "false" ]]; then
        # Small project, no tests, no deploy
        template="fast"
        confidence=85
        reason="Small project with minimal complexity"

    elif [[ "$src_file_count" -lt 50 && "$has_deploy" == "false" && "$test_file_count" -gt 0 ]]; then
        # Small-to-medium with some tests
        template="standard"
        confidence=80
        reason="Medium project with test coverage, no deployment"

    elif [[ "$src_file_count" -ge 50 && "$test_file_count" -gt 10 && "$has_ci" == "true" && "$has_deploy" == "false" ]]; then
        # Larger with good tests and CI
        template="full"
        confidence=75
        reason="Larger codebase with comprehensive testing and CI"

    elif [[ "$has_deploy" == "true" ]]; then
        # Has deployment infrastructure (Dockerfile, Docker Compose, or Kubernetes)
        template="deployed"
        confidence=90
        reason="Project with containerization and deployment config"

    elif [[ "$src_file_count" -lt 30 && "$test_file_count" == "0" ]]; then
        # Small, no tests — risky
        template="standard"
        confidence=65
        reason="Small project without test coverage — recommend adding tests"

    elif [[ "$src_lines" -gt 5000 ]]; then
        # Large codebase
        template="full"
        confidence=80
        reason="Large codebase with significant complexity"

    elif [[ "$test_file_count" -eq "0" ]]; then
        # No tests detected
        template="standard"
        confidence=60
        reason="No test suite detected — recommend adding tests"

    else
        # Default middle ground
        template="standard"
        confidence=70
        reason="Medium complexity project"
    fi

    # Output JSON
    jq -n \
        --arg template "$template" \
        --argjson confidence "$confidence" \
        --arg reason "$reason" \
        '{template: $template, confidence: $confidence, reason: $reason}'
}

# ═══════════════════════════════════════════════════════════════════════════
# project_detect_all(root)
# ─────────────────────────────────────────────────────────────────────────────
# Run full detection and cache results to .claude/project-detection.json
#
# Returns JSON: {
#   "type": "...",
#   "framework": "...",
#   "build_tool": "...",
#   "test_runner": "...",
#   "test_cmd": "...",
#   "build_cmd": "...",
#   "recommended_template": {...},
#   "cached_at": "2026-03-07T...",
#   "cache_ttl_seconds": 3600
# }
project_detect_all() {
    local root="${1:-.}"
    [[ -d "$root" ]] || return 1

    local cache_file="${root}/.claude/project-detection.json"
    local cache_ttl=3600

    # Check cache validity
    if [[ -f "$cache_file" ]]; then
        local cached_at
        cached_at=$(jq -r '.cached_at // ""' "$cache_file" 2>/dev/null || echo "")

        if [[ -n "$cached_at" ]]; then
            local cache_age
            cache_age=$(($(date +%s) - $(_iso_to_unix "$cached_at")))

            if [[ "$cache_age" -lt "$cache_ttl" ]]; then
                cat "$cache_file"
                return 0
            fi
        fi
    fi

    # Perform detection
    local type_info test_cmd build_cmd template_rec

    type_info=$(project_detect_type "$root") || return 1
    test_cmd=$(project_detect_test_cmd "$root" "$(_json_field "$type_info" "type")")
    build_cmd=$(project_detect_build_cmd "$root" "$(_json_field "$type_info" "type")")
    template_rec=$(project_recommend_template "$root")

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Merge all data into single JSON
    local result
    result=$(jq -n \
        --argjson type_info "$type_info" \
        --arg test_cmd "${test_cmd:-}" \
        --arg build_cmd "${build_cmd:-}" \
        --argjson template_rec "$template_rec" \
        --arg cached_at "$now_iso" \
        --argjson cache_ttl 3600 \
        '{
            type: $type_info.type,
            framework: $type_info.framework,
            build_tool: $type_info.build_tool,
            test_runner: $type_info.test_runner,
            test_cmd: $test_cmd,
            build_cmd: $build_cmd,
            recommended_template: $template_rec,
            cached_at: $cached_at,
            cache_ttl_seconds: $cache_ttl
        }')

    # Cache result
    mkdir -p "${root}/.claude"
    echo "$result" > "$cache_file"

    echo "$result"
}
