# pipeline-detection.sh — Auto-detection (test cmd, lang, reviewers, task type) for sw-pipeline.sh

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"
# Source from sw-pipeline.sh. Requires SCRIPT_DIR, REPO_DIR.
[[ -n "${_PIPELINE_DETECTION_LOADED:-}" ]] && return 0
_PIPELINE_DETECTION_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

detect_test_cmd() {
    local root="$PROJECT_ROOT"

    # Node.js: check package.json scripts
    if [[ -f "$root/package.json" ]]; then
        local has_test
        has_test=$(jq -r '.scripts.test // ""' "$root/package.json" 2>/dev/null)
        if [[ -n "$has_test" && "$has_test" != "null" && "$has_test" != *"no test specified"* ]]; then
            # Detect package manager
            if [[ -f "$root/pnpm-lock.yaml" ]]; then
                echo "pnpm test"; return
            elif [[ -f "$root/yarn.lock" ]]; then
                echo "yarn test"; return
            elif [[ -f "$root/bun.lockb" ]]; then
                echo "bun test"; return
            else
                echo "npm test"; return
            fi
        fi
    fi

    # Python: check for pytest, unittest
    if [[ -f "$root/pytest.ini" || -f "$root/pyproject.toml" || -f "$root/setup.py" ]]; then
        if [[ -f "$root/pyproject.toml" ]] && grep -q "pytest" "$root/pyproject.toml" 2>/dev/null; then
            echo "pytest"; return
        elif [[ -d "$root/tests" ]]; then
            echo "pytest"; return
        fi
    fi

    # Rust
    if [[ -f "$root/Cargo.toml" ]]; then
        echo "cargo test"; return
    fi

    # Go
    if [[ -f "$root/go.mod" ]]; then
        echo "go test ./..."; return
    fi

    # Ruby
    if [[ -f "$root/Gemfile" ]]; then
        if grep -q "rspec" "$root/Gemfile" 2>/dev/null; then
            echo "bundle exec rspec"; return
        fi
        echo "bundle exec rake test"; return
    fi

    # Java/Kotlin (Maven)
    if [[ -f "$root/pom.xml" ]]; then
        echo "mvn test"; return
    fi

    # Java/Kotlin (Gradle)
    if [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]]; then
        echo "./gradlew test"; return
    fi

    # Makefile
    if [[ -f "$root/Makefile" ]] && grep -q "^test:" "$root/Makefile" 2>/dev/null; then
        echo "make test"; return
    fi

    # Fallback
    echo ""
}

# Helper: detect package manager for a directory
_detect_package_manager() {
    local dir="$1"
    if [[ -f "$dir/pnpm-lock.yaml" ]]; then echo "pnpm"
    elif [[ -f "$dir/bun.lockb" ]]; then echo "bun"
    elif [[ -f "$dir/yarn.lock" ]]; then echo "yarn"
    else echo "npm"; fi
}

# Returns newline-separated test commands (primary + additional)
# First line is always the primary test command from detect_test_cmd()
detect_test_commands() {
    local root="${PROJECT_ROOT:-.}"
    local primary
    primary=$(detect_test_cmd)

    [[ -n "$primary" ]] && echo "$primary"

    # Scan package.json for additional test scripts (test:*, test.*)
    # Skip heavyweight integration/e2e scripts — those belong in the pipeline test stage
    if [[ -f "$root/package.json" ]] && command -v jq >/dev/null 2>&1; then
        local extra_scripts
        extra_scripts=$(jq -r '.scripts // {} | to_entries[]
            | select(.key | test("^test[:.].") and . != "test")
            | select(.key | test("integration|e2e|system") | not)
            | .key' "$root/package.json" 2>/dev/null) || true
        if [[ -n "$extra_scripts" ]]; then
            local pm
            pm=$(_detect_package_manager "$root")
            while IFS= read -r script; do
                [[ -z "$script" ]] && continue
                echo "${pm} run ${script}"
            done <<< "$extra_scripts"
        fi
    fi

    # Scan for subdirectory test runners (dashboard/, apps/*, etc.)
    while IFS= read -r sub_pkg; do
        [[ -z "$sub_pkg" ]] && continue
        local sub_dir
        sub_dir=$(dirname "$sub_pkg")
        local sub_test
        sub_test=$(jq -r '.scripts.test // ""' "$sub_pkg" 2>/dev/null) || true
        if [[ -n "$sub_test" && "$sub_test" != "null" && "$sub_test" != *"no test"* ]]; then
            # Skip subdirectories without installed dependencies
            [[ ! -d "$sub_dir/node_modules" ]] && continue
            local sub_pm
            sub_pm=$(_detect_package_manager "$sub_dir")
            echo "(cd \"$sub_dir\" && ${sub_pm} test)"
        fi
    done < <(find "$root" -maxdepth 3 -name "package.json" \
        -not -path "*/node_modules/*" -not -path "$root/package.json" 2>/dev/null || true)
}

# Detect test files created since a given commit
# Returns additional test commands for newly created test files
detect_created_test_files() {
    local since_commit="${1:-HEAD~1}"
    local root="${PROJECT_ROOT:-.}"
    local new_test_files
    new_test_files=$(git -C "$root" diff --name-only --diff-filter=A "$since_commit" 2>/dev/null \
        | grep -E '\.(test|spec)\.(ts|js|tsx|jsx)$' || true)

    [[ -z "$new_test_files" ]] && return

    # Group by directory, determine runner for each
    local seen_dirs=()
    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        local dir
        dir=$(dirname "$test_file")
        # Skip if already seen
        local already_seen=false
        local sd
        for sd in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
            [[ "$sd" == "$dir" ]] && already_seen=true && break
        done
        $already_seen && continue
        seen_dirs+=("$dir")

        # Find nearest package.json to determine runner
        local pkg_dir="$dir"
        while [[ "$pkg_dir" != "." && "$pkg_dir" != "/" ]]; do
            if [[ -f "$root/$pkg_dir/package.json" ]]; then
                local pm
                pm=$(_detect_package_manager "$root/$pkg_dir")
                echo "${pm} test -- ${dir}/"
                break
            fi
            pkg_dir=$(dirname "$pkg_dir")
        done
    done <<< "$new_test_files"
}

# Detect project language/framework
detect_project_lang() {
    local root="$PROJECT_ROOT"
    local detected=""

    # Fast heuristic detection (grep-based)
    if [[ -f "$root/package.json" ]]; then
        if grep -q "typescript" "$root/package.json" 2>/dev/null; then
            detected="typescript"
        elif grep -q "\"next\"" "$root/package.json" 2>/dev/null; then
            detected="nextjs"
        elif grep -q "\"react\"" "$root/package.json" 2>/dev/null; then
            detected="react"
        else
            detected="nodejs"
        fi
    elif [[ -f "$root/Cargo.toml" ]]; then
        detected="rust"
    elif [[ -f "$root/go.mod" ]]; then
        detected="go"
    elif [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/requirements.txt" ]]; then
        detected="python"
    elif [[ -f "$root/Gemfile" ]]; then
        detected="ruby"
    elif [[ -f "$root/pom.xml" || -f "$root/build.gradle" ]]; then
        detected="java"
    else
        detected="unknown"
    fi

    # Intelligence: holistic analysis for polyglot/monorepo detection
    if [[ "$detected" == "unknown" ]] && type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local config_files
        config_files=$(ls "$root" 2>/dev/null | grep -E '\.(json|toml|yaml|yml|xml|gradle|lock|mod)$' | head -15)
        if [[ -n "$config_files" ]]; then
            local ai_lang
            ai_lang=$("$SW_AGENT_EXEC" claude --print --output-format text -p "Based on these config files in a project root, what is the primary language/framework? Reply with ONE word (e.g., typescript, python, rust, go, java, ruby, nodejs):

Files: ${config_files}" --model "$(_smart_model detection haiku)" < /dev/null 2>/dev/null || true)
            ai_lang=$(echo "$ai_lang" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            case "$ai_lang" in
                typescript|python|rust|go|java|ruby|nodejs|react|nextjs|kotlin|swift|elixir|scala)
                    detected="$ai_lang" ;;
            esac
        fi
    fi

    echo "$detected"
}

# Detect likely reviewers from CODEOWNERS or git log
detect_reviewers() {
    local root="$PROJECT_ROOT"

    # Check CODEOWNERS — common paths first, then broader search
    local codeowners=""
    for f in "$root/.github/CODEOWNERS" "$root/CODEOWNERS" "$root/docs/CODEOWNERS"; do
        if [[ -f "$f" ]]; then
            codeowners="$f"
            break
        fi
    done
    # Broader search if not found at common locations
    if [[ -z "$codeowners" ]]; then
        codeowners=$(find "$root" -maxdepth 3 -name "CODEOWNERS" -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$codeowners" ]]; then
        # Extract GitHub usernames from CODEOWNERS (lines like: * @user1 @user2)
        local owners
        owners=$(grep -oE '@[a-zA-Z0-9_-]+' "$codeowners" 2>/dev/null | sed 's/@//' | sort -u | head -3 | tr '\n' ',')
        owners="${owners%,}"  # trim trailing comma
        if [[ -n "$owners" ]]; then
            echo "$owners"
            return
        fi
    fi

    # Fallback: try to extract GitHub usernames from recent commit emails
    # Format: user@users.noreply.github.com → user, or noreply+user@... → user
    local current_user
    current_user=$(gh api user --jq '.login' 2>/dev/null || true)
    local contributors
    contributors=$(git log --format='%aE' -100 2>/dev/null | \
        grep -oE '[a-zA-Z0-9_-]+@users\.noreply\.github\.com' | \
        sed 's/@users\.noreply\.github\.com//' | sed 's/^[0-9]*+//' | \
        sort | uniq -c | sort -rn | \
        awk '{print $NF}' | \
        grep -v "^${current_user:-___}$" 2>/dev/null | \
        head -2 | tr '\n' ',')
    contributors="${contributors%,}"
    echo "$contributors"
}

# Get branch prefix from task type — checks git history for conventions first
branch_prefix_for_type() {
    local task_type="$1"

    # Analyze recent branches for naming conventions
    local branch_prefixes
    branch_prefixes=$(git branch -r 2>/dev/null | sed 's#origin/##' | grep -oE '^[a-z]+/' | sort | uniq -c | sort -rn | head -5 || true)
    if [[ -n "$branch_prefixes" ]]; then
        local total_branches dominant_prefix dominant_count
        total_branches=$(echo "$branch_prefixes" | awk '{s+=$1} END {print s}' || echo "0")
        dominant_prefix=$(echo "$branch_prefixes" | head -1 | awk '{print $2}' | tr -d '/' || true)
        dominant_count=$(echo "$branch_prefixes" | head -1 | awk '{print $1}' || echo "0")
        # If >80% of branches use a pattern, adopt it for the matching type
        if [[ "$total_branches" -gt 5 ]] && [[ "$dominant_count" -gt 0 ]]; then
            local pct=$(( (dominant_count * 100) / total_branches ))
            if [[ "$pct" -gt 80 && -n "$dominant_prefix" ]]; then
                # Map task type to the repo's convention
                local mapped=""
                case "$task_type" in
                    bug)      mapped=$(echo "$branch_prefixes" | awk '{print $2}' | tr -d '/' | grep -E '^(fix|bug|hotfix)$' | head -1 || true) ;;
                    feature)  mapped=$(echo "$branch_prefixes" | awk '{print $2}' | tr -d '/' | grep -E '^(feat|feature)$' | head -1 || true) ;;
                esac
                if [[ -n "$mapped" ]]; then
                    echo "$mapped"
                    return
                fi
            fi
        fi
    fi

    # Fallback: default branch prefix mapping
    case "$task_type" in
        bug)          echo "fix" ;;
        refactor)     echo "refactor" ;;
        testing)      echo "test" ;;
        security)     echo "security" ;;
        docs)         echo "docs" ;;
        devops)       echo "ci" ;;
        migration)    echo "migrate" ;;
        architecture) echo "arch" ;;
        *)            echo "feat" ;;
    esac
}

# ─── State Management ──────────────────────────────────────────────────────

PIPELINE_STATUS="pending"
CURRENT_STAGE=""
STARTED_AT=""
UPDATED_AT=""
STAGE_STATUSES=""
LOG_ENTRIES=""

detect_task_type() {
    local goal="$1"

    # Intelligence: Claude classification with confidence score
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local ai_result
        ai_result=$("$SW_AGENT_EXEC" claude --print --output-format text -p "Classify this task into exactly ONE category. Reply in format: CATEGORY|CONFIDENCE (0-100)

Categories: bug, refactor, testing, security, docs, devops, migration, architecture, feature

Task: ${goal}" --model "$(_smart_model classification haiku)" < /dev/null 2>/dev/null || true)
        if [[ -n "$ai_result" ]]; then
            local ai_type ai_conf
            ai_type=$(echo "$ai_result" | head -1 | cut -d'|' -f1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            ai_conf=$(echo "$ai_result" | head -1 | cut -d'|' -f2 | grep -oE '[0-9]+' | head -1 || echo "0")
            # Use AI classification if confidence >= 70
            case "$ai_type" in
                bug|refactor|testing|security|docs|devops|migration|architecture|feature)
                    if [[ "${ai_conf:-0}" -ge 70 ]] 2>/dev/null; then
                        echo "$ai_type"
                        return
                    fi
                    ;;
            esac
        fi
    fi

    # Fallback: keyword matching
    local lower
    lower=$(echo "$goal" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *fix*|*bug*|*broken*|*error*|*crash*)     echo "bug" ;;
        *refactor*|*clean*|*reorganize*|*extract*) echo "refactor" ;;
        *test*|*coverage*|*spec*)                  echo "testing" ;;
        *security*|*audit*|*vuln*|*cve*)           echo "security" ;;
        *doc*|*readme*|*guide*)                    echo "docs" ;;
        *deploy*|*ci*|*pipeline*|*docker*|*infra*) echo "devops" ;;
        *migrate*|*migration*|*schema*)            echo "migration" ;;
        *architect*|*design*|*rfc*|*adr*)          echo "architecture" ;;
        *)                                          echo "feature" ;;
    esac
}

template_for_type() {
    case "$1" in
        bug)          echo "bug-fix" ;;
        refactor)     echo "refactor" ;;
        testing)      echo "testing" ;;
        security)     echo "security-audit" ;;
        docs)         echo "documentation" ;;
        devops)       echo "devops" ;;
        migration)    echo "migration" ;;
        architecture) echo "architecture" ;;
        *)            echo "feature-dev" ;;
    esac
}

# ─── Stage Preview ──────────────────────────────────────────────────────────

