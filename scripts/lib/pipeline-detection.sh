# pipeline-detection.sh — Auto-detection (test cmd, lang, reviewers, task type) for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires SCRIPT_DIR, REPO_DIR.
[[ -n "${_PIPELINE_DETECTION_LOADED:-}" ]] && return 0
_PIPELINE_DETECTION_LOADED=1

# Detect best iOS Simulator destination by UUID.
# Prefers: booted iPhone > iPhone Pro/Max on newest OS > any iPhone on newest OS > fallback
_detect_ios_sim_dest() {
    local sim_id="" all_iphones=""
    all_iphones=$(xcrun simctl list devices available 2>/dev/null | grep -i "    iphone" || true)

    # 1. Booted iPhone
    sim_id=$(echo "$all_iphones" | grep -i "Booted" | head -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/' || true)

    # 2. iPhone Pro or Pro Max on newest OS (tail = newest OS section)
    if [[ -z "$sim_id" ]]; then
        sim_id=$(echo "$all_iphones" | grep -i "pro" | tail -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/' || true)
    fi

    # 3. Any iPhone on newest OS
    if [[ -z "$sim_id" ]]; then
        sim_id=$(echo "$all_iphones" | tail -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/' || true)
    fi

    if [[ -n "$sim_id" ]]; then
        echo "platform=iOS Simulator,id=${sim_id}"
    else
        echo "platform=iOS Simulator,name=Any iOS Simulator Device"
    fi
}

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

    # iOS/macOS: Xcode project, Swift package, test harness, or workspace
    # 1. .xcodeproj
    local xc_project=""
    xc_project=$(find "$root" -maxdepth 1 -name "*.xcodeproj" -print -quit 2>/dev/null || true)
    if [[ -n "$xc_project" ]]; then
        local proj_name scheme sim_dest
        proj_name=$(basename "$xc_project")
        scheme="${proj_name%.xcodeproj}"
        sim_dest=$(_detect_ios_sim_dest)
        echo "xcodebuild -project ${proj_name} -scheme ${scheme} -sdk iphonesimulator -destination '${sim_dest}' -enableCodeCoverage YES -resultBundlePath TestResults/\$(date +%Y%m%d-%H%M%S).xcresult test 2>&1"
        return
    fi
    # 2. Swift Package Manager
    if [[ -f "$root/Package.swift" ]]; then
        echo "swift test"; return
    fi
    # 3. Test harness script
    if [[ -f "$root/scripts/run-xcode-tests.sh" ]]; then
        echo "./scripts/run-xcode-tests.sh 2>&1"; return
    fi
    # 4. .xcworkspace (exclude internal project.xcworkspace inside .xcodeproj)
    local xc_workspace=""
    xc_workspace=$(find "$root" -maxdepth 1 -name "*.xcworkspace" ! -path "*.xcodeproj/*" -print -quit 2>/dev/null || true)
    if [[ -n "$xc_workspace" ]]; then
        local ws_name scheme sim_dest
        ws_name=$(basename "$xc_workspace")
        scheme="${ws_name%.xcworkspace}"
        sim_dest=$(_detect_ios_sim_dest)
        echo "xcodebuild -workspace ${ws_name} -scheme ${scheme} -sdk iphonesimulator -destination '${sim_dest}' -enableCodeCoverage YES -resultBundlePath TestResults/\$(date +%Y%m%d-%H%M%S).xcresult test 2>&1"
        return
    fi

    # Fallback
    echo ""
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
    elif ls "$root"/*.xcworkspace 1>/dev/null 2>&1 || ls "$root"/*.xcodeproj 1>/dev/null 2>&1; then
        detected="swift"
    elif [[ -f "$root/Package.swift" ]]; then
        detected="swift"
    else
        detected="unknown"
    fi

    # Intelligence: holistic analysis for polyglot/monorepo detection
    if [[ "$detected" == "unknown" ]] && type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local config_files
        config_files=$(ls "$root" 2>/dev/null | grep -E '\.(json|toml|yaml|yml|xml|gradle|lock|mod)$' | head -15)
        if [[ -n "$config_files" ]]; then
            local ai_lang
            ai_lang=$(claude --print --output-format text -p "Based on these config files in a project root, what is the primary language/framework? Reply with ONE word (e.g., typescript, python, rust, go, java, ruby, nodejs):

Files: ${config_files}" --model haiku < /dev/null 2>/dev/null || true)
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

    # Fallback: hardcoded mapping
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
        ai_result=$(claude --print --output-format text -p "Classify this task into exactly ONE category. Reply in format: CATEGORY|CONFIDENCE (0-100)

Categories: bug, refactor, testing, security, docs, devops, migration, architecture, feature

Task: ${goal}" --model haiku < /dev/null 2>/dev/null || true)
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

