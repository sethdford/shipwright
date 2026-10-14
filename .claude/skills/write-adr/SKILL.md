---
name: write-adr
description: Record an architecture decision in docs/adr. Use when choosing between approaches that future contributors would otherwise re-debate.
---
Create `docs/adr/NNNN-kebab-title.md` with the next number and these sections:
`# NNNN. Title`, `Status: accepted|superseded by NNNN`, `Date`, `## Context` (forces and
constraints), `## Decision` (one paragraph), `## Consequences` (what gets easier, what gets harder).
Keep it under 60 lines. Link it from `docs/architecture.md` if it changes the structure.
