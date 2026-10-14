# 0002. Modular monolith with Clean Architecture

Status: accepted · Date: 2026-10-13

## Context
About 110 subcommands overlap heavily and share state through ad-hoc files. Agents edit this code
daily and need boundaries they cannot cross by accident.

## Decision
One deployable, split into 10 bounded contexts (see `docs/architecture.md`). Each context has
`domain/`, `application/`, its ports and an `index.ts` public API. I/O lives only in `src/adapters/`;
`src/main.ts` wires adapters into use cases.

Boundaries are fitness rules checked by `bun run arch`, which `bun run check` runs:
- F1–F4 (purity, layering, context boundaries, cycles) with dependency-cruiser;
- F5, F6, F8 (I/O placement, Agent SDK placement, test isolation) with ast-grep;
- F7 (file and function size) with a ratchet whose baseline, `tools/arch/arch-baseline.json`, may
  only shrink.

F9 (no GitHub token or permission bypass for agents) and F10 (fenced, idempotent GitHub side
effects) are planned for Waves 1–2.

## Consequences
- Violations fail CI with the rule name and a fix hint, so structure survives agent edits.
- Some ceremony for tiny commands.
- Old command names survive as aliases while implementations merge.
