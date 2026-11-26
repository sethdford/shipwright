# 0010. Repository lessons and a governance pack, read from the base commit

Status: accepted · Date: 2026-11-26

## Context
Agents build without the rules a repository has decided. The build and review prompts get CLAUDE.md, AGENTS.md
and `.claude/rules/`, but not `docs/adr/`, written policies or standards, so an agent can break an accepted
decision without being told it exists. The constitution (`config/code-constitution.json`) is a few generic grep
rules whose results are only logged.

Learning from failures does not work either. As of 2026-11-26, the bash memory store on `shipwright-data` holds
about 12 KB for this repository: `failures.json` and `playbooks.json` are empty, the one captured pattern says the
repository is Node with vitest (it is Bun), and about 25 test-fixture directories leaked into it. ADR-0009 retires
these learners (W2-16) and defers self-improvement (W2-19, phase J), because they change behaviour without being
measured or reviewed. The pipeline merge rate is 2 of 10 PRs (20%) over the last year.

## Decision
Add a `governance` context that gives agents a repository's written rules and its approved lessons, under
ADR-0009's constraints. It is the first, smallest slice of phase J: the only surface it edits is text in a prompt.

1. **Documents live in the repository.** ADRs (`docs/adr/`, `docs/decisions/`, `adr/`), policies
   (`docs/policies/`, `.shipwright/policies/`), standards (`docs/standards/`, `.shipwright/standards/`) and lessons
   (`.shipwright/lessons/`). Optional front matter: `id`, `title`, `status`, `applies_to` (path globs). Lessons add
   `failure_class`, `fingerprint`, `keywords`, `hypothesis` and `source`.
2. **Read from the base commit, tracked files only.** `governance_ref` resolves the base branch to a SHA, and every
   read comes from that commit, so a build agent cannot edit the rules it is given (the #8673 rule for memory).
3. **The build prompt gets a brief; the review prompt gets a checklist.** The brief holds the policies, standards
   and ADRs in force (not proposed, superseded, deprecated, rejected or retired), then at most 5 active lessons
   ranked by failure fingerprint, failure class, paths and keywords. It is capped at 16,000 characters. The
   checklist lists the documents whose `applies_to` matches a changed path, then repository-wide policies and
   standards; the reviewer must say each one is met or name the violation.
4. **A lesson reaches an agent only after a person merges it.** `shipwright governance propose` drafts a lesson
   from a failed run's log (classified by the ADR-0009 classifier) with status `proposed` and the evidence. A
   maintainer writes the rule and the hypothesis, sets `status: active` and merges it. A failure whose fingerprint
   a lesson already covers is not drafted again. Nothing writes lessons automatically.
5. **Every run records its arm.** Each brief emits a `governance.brief` event with the base SHA, the lesson ids and
   the document count. `SHIPWRIGHT_LESSONS=off` and `SHIPWRIGHT_GOVERNANCE=off` are the ablation arms for the
   paired ratchet (ADR-0009 rule 5); a lesson or the feature stays only if its arm is non-inferior.
6. **The brief is advice, not a gate.** If it cannot be built, the run continues without it and an event says so.

## Consequences
- Accepted ADRs, policies and standards reach the agent that has to follow them, and the reviewer that checks.
- A failed run can become a rule for later runs, reviewed by a person, with a stated hypothesis to test.
- Until the eval harness runs paired replays, the lift is not measured; the events make it measurable later.
- An eleventh bounded context, `governance`; lessons live there, and `learning` keeps classification.
- Retire a lesson by setting `status: retired`, never by deleting it, so the record of what was tried remains.
- Not done here: a reflection step that has an agent draft the rule, and a workflow that opens the lesson PR
  after a failed run. Both need the ledger (W2-08) to show which runs a lesson touched.
