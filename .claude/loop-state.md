---
goal: "E2E test: add comment to README [automated]

## Specification: E2E test: add comment to README [automated]

### Goals
- E2E test: add comment to README [automated]

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 40,
      "summary": "Build-stage pattern for a Node project (Cannot find module, fix: npm i) with a known fix, the closest match to a build stage run in a JS repo."
    },
    {
      "file": "index.json",
      "relevance": 35,
      "summary": "Build-stage failure pattern with a documented fix, a generic signal for what can go wrong during build."
    },
    {
      "file": "success-patterns.json",
      "relevance": 30,
      "summary": "Successful pattern (repo 5112be...) with build stage and npm test strategy, a low-complexity run similar to a simple README edit."
    },
    {
      "file": "success-patterns.json",
      "relevance": 30,
      "summary": "Successful pattern (test-repo-comptime) covering intake, build and test stages, mirroring the stages this pipeline is running."
    },
    {
      "file": "failures.json",
      "relevance": 20,
      "summary": "Recorded test-stage failures with root causes and fixes; only tangentially related since this task is a documentation change."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Split sw-loop.sh into iteration-execution, convergence-detection, and session-management modules — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Split sw-loop.sh into iteration-execution, convergence-detection, and session-management modules

## Implementation Checklist
- [ ] **T1** Baseline test counts, `--help` snapshot, function dump. *Blocks T5, T8.*
- [ ] **T2** Write the function-mover script. *Blocks T5.*
- [ ] **T3** Create `lib/loop-session.sh` with guard and `loop_session_init`. *Blocks T4, T5.*
- [ ] **T4** Extract `handle_verification_gap` (keep in `sw-loop.sh`) and replace the inline block and session-id block with calls. *Blocks T5.*
- [ ] **T5** Move functions into iteration, convergence and session modules. *Blocks T6.*
- [ ] **T6** Update source lines and add the fail-fast guard. *Blocks T7.*
- [ ] **T7** `bash -n`, shellcheck, Bash 3.2 lint. *Blocks T8.*
- [ ] **T8** Function-dump diff and `--help` diff. *Blocks T9.*
- [ ] **T9** Targeted suites, then `npm test`; confirm `git diff --exit-code main -- 'scripts/*-test.sh'`. *Blocks T10.*
- [ ] **T10** Hygiene ranking check and `wc -l` report.
- [ ] **T11** `shipwright docs sync` / `docs check` and the CLAUDE.md lib rows.
- [ ] `scripts/lib/loop-iteration.sh`, `loop-convergence.sh` and the new `loop-session.sh` hold the iteration, convergence and session logic per the map, and `sw-loop.sh` sources them
- [ ] `wc -l scripts/sw-loop.sh` ≤ ~1,200 and below `sw-memory.sh` (2,241); hygiene `script_sizes[0]` is not `sw-loop.sh`
- [ ] `git diff main -- 'scripts/*-test.sh'` is empty
- [ ] `sw-loop-test.sh`, `sw-convergence-test.sh`, `sw-heartbeat-test.sh`, `sw-recruit-test.sh`, `sw-agi-roadmap-test.sh`, `sw-autoresearch-e2e-test.sh`, `sw-session-restart-test.sh`, `sw-e2e-system-test.sh` pass with counts at least the baseline; `npm test` green
- [ ] `--help` output is byte-identical; the function-dump diff shows only the documented changes; each function is defined exactly once
- [ ] `bash -n`, shellcheck and the Bash 3.2 lint are clean on all changed files
- [ ] The fail-fast guard fires with a clear message when a required loop module is missing
- [ ] `shipwright docs check` exits 0

## Context
- Pipeline: standard
- Branch: refactor/split-sw-loop-sh-into-iteration-executio-8439
- Issue: #8439
- Generated: 2026-10-11T02:54:33Z

## Skill Guidance (documentation issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **documentation**: The change is a lightweight edit to README.md, so the documentation approach fits: keep the edit minimal and confined to the README without touching other files.

## Documentation Expertise

For documentation-focused issues, apply a lightweight approach:

### Scope
- Focus on accuracy over comprehensiveness
- Update only what's actually changed or incorrect
- Remove outdated information rather than marking it deprecated
- Keep examples current and runnable

### Writing Style
- Use active voice and present tense
- Lead with the most important information
- Use code examples for anything technical
- Keep paragraphs short — 2-3 sentences max

### Structure
- Start with a one-line summary of what this documents
- Include prerequisites and setup if applicable
- Provide a quick start / most common usage first
- Put advanced topics and edge cases later

### Skip Heavy Stages
This is a documentation change. The following pipeline stages can be simplified:
- **Design stage**: Skip — documentation doesn't need architecture design
- **Build stage**: Focus on file edits only, no compilation needed
- **Test stage**: Verify links work and examples are syntactically correct
- **Review stage**: Focus on accuracy and clarity, not code patterns

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **What to Document**: List of documentation files created/modified with specific sections added to each
2. **What to Skip**: Explicitly state which topics are NOT documented and why (e.g., "Advanced topic X is out of scope for this issue")
3. **Audience**: Who will read this documentation (developers, users, operators) and what level of detail is appropriate

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-10-11T03:29:38Z
last_iteration_at: 2026-10-11T03:29:38Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

