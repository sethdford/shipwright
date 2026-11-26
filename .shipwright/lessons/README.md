# Lessons

A lesson is one rule learned from a failed run. Agents see it only when its status is `active`, and only when it
fits the run (ADR-0010). This README is not read as a lesson.

## Add one

1. Draft it from the failed run's log: `shipwright governance propose --log run.log --source "<run URL>" > draft.md`.
   Exit 3 means a lesson already covers that failure.
2. Write the rule (one thing to do, not what went wrong) and the hypothesis (what should change in later runs).
   Narrow it with `applies_to` (path globs) and `keywords`, so it reaches only the runs it is about.
3. Set `status: active`, save it as `.shipwright/lessons/L-NNNN.md` and open a pull request. Merging it is the approval.

## Let the loop draft and test them (ADR-0010, amendment 1)

1. List failed runs in a manifest, one `<source> <log path>` per line, then draft lessons from the failures that
   recur: `source scripts/lib/lessons-loop.sh; lessons_draft_from_failures manifest.txt drafts/`. An agent writes
   each rule; if it cannot, the draft keeps its placeholders for you to fill in.
2. Run the eval cases twice: once as the incumbent, once with `SHIPWRIGHT_LESSONS_TRIAL=L-NNNN`. Compare them with
   `eval ratchet`, and save the verdict JSON.
3. `shipwright governance promote --draft drafts/L-NNNN.md --verdict verdict.json > .shipwright/lessons/L-NNNN.md`.
   Exit 0 means `active` (accepted on 12 or more cases); exit 3 means `retired`. Open a pull request either way, so
   the record stays. Nothing goes live until it is merged.

## Format

```markdown
---
id: L-0001
status: active            # proposed | active | retired
failure_class: test       # from `shipwright failure classify`
fingerprint: 3f2a…        # the failure it came from
applies_to: [scripts/**/*-test.sh]
keywords: [mktemp]
hypothesis: "Bash suites stop failing at setup on runners without /tmp/claude"
source: "https://github.com/OWNER/REPO/actions/runs/123"
---
# Create temp directories under TMPDIR

Create test temp directories with `mktemp -d "${TMPDIR:-/tmp}/sw-XXXXXX"`, never under a fixed subdirectory.
```

Retire a lesson that stops helping by setting `status: retired`. Do not delete it. Measure with the ablation arm
`SHIPWRIGHT_LESSONS=off` on the paired ratchet.
