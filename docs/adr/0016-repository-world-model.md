# 0016. A repository world model that agents query through tools

Status: accepted · Date: 2026-11-26

## Context
Every pipeline agent starts blind and rediscovers the repository with grep. The plan stage's "architecture
context" (`scripts/lib/architecture.sh`) is the first 100 file names, a count of import strings and export counts;
`sw-context.sh` previews the first 20 lines of up to 3 files whose names share a word with the goal. Nothing is
kept between runs, nothing knows who calls what, and no agent can ask a question of the code base other than by
reading files.

Localization (which files and functions a change belongs in) is where SWE-bench agents win or lose. The approaches
that move it:

- **Repo maps** (Aider): tag-level definitions and references from every file, a file graph from shared names,
  personalized PageRank toward the files in play, cut to a token budget.
- **Hierarchical localization** (Agentless): narrow to files, then classes and functions, then lines.
- **Code-graph tools** (LocAgent, ACL 2025; CoSIL; RepoGraph): a graph of files, classes and functions with
  contain, import, invoke and inherit edges, a BM25 entity index over names and code, and three tools: search,
  graph traversal and entity retrieval. LocAgent reports 92.7% file-level Acc@5 on SWE-bench Lite with a fine-tuned
  32B model; its ablation finds entity search (BM25 over names) matters most, then graph traversal.
- **Lexically anchored graph expansion** (LARGER, 2026): start from lexical hits, expand along the graph locally,
  inside the agent's existing search loop. +11.8 to +13.9 points file Acc@5 on LocBench.
- **Incremental maintenance** (RPG-Encoder, 2026): an evolving graph cuts upkeep by about 96% against rebuilding.

## Decision
Add an `intelligence` context with a persistent, incrementally refreshed model of the repository, and give agents
read-only tools over it.

1. **The model** holds, per source file: definitions (name, kind, line, signature, container, doc comment, exported
   or not), import specifiers, and the identifiers it uses. Extraction is tag-level line rules per language (TS/JS,
   Python, Go, Rust, bash, Java/Kotlin, Ruby) with no native dependency; a tree-sitter extractor can replace a rule
   table without changing the model. Plus CODEOWNERS and authorship from the last 400 commits.
2. **Incremental by construction.** Entries are keyed by size and mtime, then by a content hash; a refresh reads
   only new and edited files and re-reads authorship only when HEAD moves. The cache is one JSON file per root
   under `<stateDir>/repo-model/`. A full build of this repository (723 files) takes about 0.5 s, a no-change
   refresh about 0.15 s, so every query refreshes first and sees the agent's uncommitted edits.
3. **The graph and indexes** are derived in memory: definitions by name, resolved imports and importers, reference
   edges between files of one language family (Aider's weighting), a BM25 entity index (one document per file and
   per definition, LocAgent's), personalized PageRank, a static test-to-code map (imports, naming, shared names),
   and ownership.
4. **Agents query it through MCP.** `shipwright repomodel mcp` is a stdio MCP server named `repomodel` with nine
   read-only tools: `search`, `definition`, `references` (each use with its enclosing definition, so a caller list),
   `outline`, `dependencies`, `tests_for`, `owners`, `repo_map` and `localize`. `scripts/lib/repo-model.sh` writes
   its config and adds `--mcp-config` to the loop's and the pipeline stages' claude calls;
   `config/agent-permissions.json` allows `mcp__repomodel`. The same queries are CLI subcommands.
5. **Prompts get a brief.** The build loop and the plan stage get a "Repository model" section: the files and
   definitions most likely relevant to the goal (lexical hits and outright mentions seed a personalized PageRank),
   each with its tests and owners, and how to use the tools. In the plan stage it replaces the grep-based
   architecture context.
6. **An MCP server never runs code the agent can edit.** MCP servers run outside the agent's sandbox. The server
   is attached only when the shipwright CLI lives outside the agent's working tree; when shipwright works on its own
   repository, the agent gets the brief but no server.
7. **Switchable for the ratchet.** `SHIPWRIGHT_REPO_MODEL=off` (or 0, false, no) is the control arm: no brief, no
   server, and the plan stage keeps the old architecture context. Events `repo_model.brief`,
   `repo_model.mcp_attached` and `repo_model.mcp_skipped` record the arm and the files a brief named, so paired
   runs can be compared with `shipwright eval ratchet` (W2-13) and a brief's localization can be scored against
   the files a merged PR actually changed.
8. **Reviewers get the change's reach (2026-11-26).** `repomodel impact --diff FILE` reads a unified diff and
   reports the definitions it edits, files outside the change that import or use them, linked tests it does or
   does not change, and deleted files that are still imported. The review stage puts it before the diff; the
   merge critic gets it as data when `SHIPWRIGHT_VERIFIER_CRITIC=on`. The off arm leaves it out.
9. **A semantic channel, measured before it is trusted.** `SHIPWRIGHT_REPO_MODEL_SEMANTIC=on` adds latent semantic
   analysis over the files (a truncated SVD of the TF-IDF matrix by seeded randomized power iteration, pure
   TypeScript, about 0.6 s on 900 files, built only when a query needs it) as a third localize signal beside
   lexical hits and mentions. It stays off by default: on 48 past PRs it found a changed file in the top 5 for
   30 against 28 (3 wins, 1 loss), which the ratchet does not accept as better. A learned embedding model can
   replace it behind the same `SemanticIndex` shape when a provider is allowed.
10. **The localization check is repeatable and leak-free.** `repomodel eval` takes the last N first-parent PRs,
   rebuilds the model at each parent commit in a scratch worktree, localizes the PR title and records where the
   files it really changed rank. `--export` writes eval-ratchet results (pass = a changed file in the top 5), so
   a change to extraction, ranking or the semantic channel is compared case by case with
   `shipwright eval ratchet --k 1` and no model spend.

## Consequences
- Agents can ask "who calls this", "which tests cover this file" and "where is this defined" in one call instead
  of several greps and reads. A live run with Claude Code answered a localization question about the budget gate
  in 4 turns with the tools alone.
- Extraction is heuristic. Multi-line signatures, decorators and dynamic dispatch are missed, and reference edges
  are name-based, not type-resolved, so the brief says it is a starting point to check. Bump `EXTRACTOR_VERSION`
  whenever a rule changes so stored models are rebuilt.
- Lexical search plus the graph is the default. The semantic channel lifts top-10 hits (63% to 73% on one
  sample) more than top-5 ones; it turns on when `repomodel eval` exports make the ratchet accept it.
- Impact is name-based like the rest of the graph, so it lists places to check, not proven breakage.
- Coverage data does not yet sharpen the test map; the paired agent A/B (on against off on the benchmark) is
  what decides whether the model pays for itself in resolved tasks, not just in localization.
