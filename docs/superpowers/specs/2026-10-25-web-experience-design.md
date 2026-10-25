# Web experience design: dashboard and website (epic #8697)

Status: proposed. Date: 2026-10-25. Basis: `origin/main` at `24d24a489`.
Scope: `dashboard/` (Fleet Command SPA) and `website/` (Astro 5 + Starlight). No implementation in this document.

Evidence labels: **[repo]** read from `origin/main`; **[web]** from a search result (secondary unless marked primary); **[est]** estimate, not measured. Nothing was built or run: the disk is 99% full and `bun install` was not allowed.

---

## 1. Audit (what exists today)

### 1.1 Dashboard (Fleet Command)

- **Scale.** About 9,800 lines of non-test TypeScript under `dashboard/src` [repo]. `dashboard/server.ts` is 5,887 lines and ratcheted by F12 [repo]. `dashboard/public/styles.css` is 5,908 lines of hand-written CSS [repo]. `dashboard/public/index.html` is 37 KB of inline markup with 13 tab panels [repo].
- **Views: 13, not 17.** The epic says 17 views. The repo has 13 tab buttons, 13 `views/*.ts` modules and 13 `VALID_TABS` entries (`dashboard/src/core/router.ts`) [repo]. The epic count should be corrected.
- **Tabs.** Overview, Agents, Pipelines, Timeline, Activity, Metrics, Machines, Insights, Team, Map, Theater, Cockpit, Shipyard [repo]. Nine are data views. Four are visual or thematic: Map (`fleet-map.ts`, 299 lines), Theater (`pipeline-theater.ts`, 219), Cockpit (`agent-cockpit.ts`, 236) and Shipyard (`shipyard.ts`, 39 plus a canvas scene of about 616 lines, `canvas/shipyard-scene.ts`, plus `shipyard-effects.ts` 367, `pixel-sprites.ts` 440, `submarine-layout.ts`, `submarine-theme.ts`) [repo]. Shipyard and the pixel sprites are the clearest gimmicks in the codebase.
- **Design tokens exist but are not the system.** `dashboard/src/design/tokens.ts` (160 lines) defines colour, type, spacing, radius, shadow, duration and easing in hex, rgba and px. It names three fonts (Instrument Serif, Plus Jakarta Sans, JetBrains Mono) [repo]. None of these fonts is loaded: `public/index.html` and `styles.css` contain no `@font-face`, no font link and no Google Fonts reference [repo]. Every font declared in tokens falls back to the system stack.
- **Two theme sources.** `design/tokens.ts` and `design/submarine-theme.ts` both carry theme constants [repo]. `docs/` has no single token contract for CSS and Canvas to share.
- **Accessibility, measured by grep only (not run in a browser).**
  - `role="tab"`, `role="tablist"`, `aria-selected`, `aria-live` and `role="dialog"` appear 0 times in `public/index.html` [repo]. The tab bar is `<button class="tab-btn">` with no tab semantics.
  - `prefers-reduced-motion` appears once in `styles.css` [repo]. Canvas scenes do not check it (no match in `canvas/renderer.ts`) [repo].
  - `:focus-visible` does not appear in `styles.css` [repo]. Keyboard focus styling is probably browser default at best.
  - The only icon-only controls with labels are a few `aria-label`s (user avatar, alert dismiss, close detail) [repo].
- **Branding.** The favicon is an emoji anchor inline as an SVG data URI (`⚓`) [repo, `public/index.html` line 10]. The landing title and OG copy use "Autonomous Agent Fleet Command".
- **Real-time model.** One WebSocket `/ws` streams aggregated fleet state, with reconnection, a stale-data timer and a connection clock in `core/ws.ts` [repo]. `/ws/events` streams raw events. SSE `/api/logs/:n/stream` streams one run's log [repo]. The client uses a central store with typed subscriptions (`core/state.ts`) [repo]. This is a sound base.
- **Server surface.** Routes are mounted in one `server.ts` `fetch` handler [repo]. Public (no auth): `/login`, `/auth/*`, `/api/health`, `/api/ws-status`, `/api/join*`, `/api/connect/*`, `/api/team*`, `/api/claim*`, `/api/webhook/ci`. Authenticated: `/api/status`, `/api/pipeline/:n` (and `/diff`, `/files`, `/test-results`, `/reasoning`, `/failures`), `/api/plans/:n`, `/api/metrics/*` (history, bottlenecks, capacity, dora-trend, failure-heatmap, stage-performance, throughput-trend), `/api/costs/breakdown|trend`, `/api/activity`, `/api/agents`, `/api/timeline`, `/api/intervention/bulk` and `/api/intervention/:id/*` (POST), `/api/logs/:n` and `/stream`, `/api/machines*`, `/api/daemon/*` and `/api/daemon/config`, `/api/emergency-brake`, `/api/approval-gates*`, `/api/quality-gates`, `/api/alerts`, `/api/audit-log`, `/api/queue/detailed`, `/api/memory/{decisions,global,patterns}`, `/api/predictions/*`, `/api/patrol/recent`, `/api/notifications/*`, `/api/github/*`, `/api/linear/status`, `/api/me`, `/api/db/{costs/today,events,health,heartbeats,jobs}`, `/api/context-efficiency`, `/api/artifacts/*`, `/api/join-token` [repo, from `server.ts` and `core/api.ts`].
- **Security posture to keep.** Token auth on mutating and fleet routes, a CORS allowlist, JSON-only writes, WebSocket origin refusal (cross-site WebSocket hijacking), `127.0.0.1` binding by default, `execFileSync`/`spawn` with argv arrays only, and F12 layering with the findings ratchet [repo, `.claude/rules/dashboard.md`, `docs/architecture.md`].
- **Bundle.** `dashboard:prod` builds `dashboard/public/dist/main.js` with `bun build --minify` [repo]. The bundle was not measured. [est] Minified plus gzipped, the current bundle is probably 110 to 180 KB; the canvas and sprite code is a large share. T1 measures it before any budget is fixed.
- **Dead or gimmicky.** Shipyard, Theater and Cockpit overlap with Pipelines and Timeline. Map overlaps with Machines. Metrics and Insights overlap with each other. Activity is a raw feed that duplicates the audit log.

### 1.2 Website

- **Landing.** `website/src/pages/index.astro` is 12 lines. It reads `website/public/index.html` (37 KB, one static HTML string) and injects it with `set:html` [repo]. The landing therefore has no components, no token use from Starlight, no image pipeline, and no build-time checks on its markup. It also sits beside `src/content/docs/index.mdx`, a Starlight splash that targets the same `/` route [repo]. The build must be checked to see which one wins; T5 resolves this.
- **Docs.** 26 `.mdx` files under `src/content/docs` (guides, reference, FAQ, troubleshooting). The sidebar groups them into Getting Started, Guides (12), Reference (5) and Help [repo, `astro.config.mjs`].
- **Theming.** `custom.css` overrides Starlight accent variables (`--sl-color-accent` `#00d4ff` dark, `#0098b8` light) [repo]. It sets `--font-body` and `--font-mono` with no font loading in the site either, as far as the grep shows [repo].
- **Brand.** Logos are `logo-light.svg` and `logo-dark.svg` [repo]. `website/public/index.html` uses an emoji favicon as well [repo, same pattern as the dashboard].
- **Design guide.** `website/design-system.md` (version 3.0, March 2026) describes "Refined Depths" palette in hex and a brand voice that already says "Let the product speak" [repo]. It has no implementation-facing token file. Its colour values differ from `dashboard/src/design/tokens.ts`. The two surfaces have drifted apart.

### 1.3 Audit verdict

The bones are good: real-time transport, a store, typed tokens, strict server guards and a documented architecture. The surface is not yet award-calibre. Three things hold it back.

1. The UI does not make trust legible. Gates, breaker state, evidence and the audit trail are scattered across 13 tabs, and the most decorative views are the most prominent.
2. The design system is a set of constants that the CSS does not consume. Fonts are declared and never loaded. Colour is in hex with no contrast contract.
3. Accessibility is unverified and probably weak at the tab bar, focus and motion.

---

## 2. Competitive research (late 2026)

Search results only, mostly secondary. Items marked **unverified** need checking against the vendor's own docs before anything is published (see section 11).

| Product | Operator console for unattended agents (what to learn) | Marketing story (what to learn) | Source |
| --- | --- | --- | --- |
| Factory (Droids) | Droids take a task, plan, edit, run tests and submit a diff or PR for human approval. Governance of autonomy per workflow. Desktop app and CLI both monitor work. | Enterprise: SSO, audit logging, on-premise. "Factory 2.0" links requirements to deploy and monitoring. | [web] https://factory.ai and https://enterprisedna.co/resources/ai-map/company/factory (funding figures conflict; do not cite them) |
| StrongDM "software factory" | A non-interactive factory where humans write specifications and curate test scenarios, and agents write and ship code. Trust comes from a "Digital Twin Universe" of third-party services and layered verification. | The purest "dark factory" claim: no human code review. Strong and polarising. Critics (Willison, Stanford Law) question the trust model. | [web] https://simonwillison.net/2026/Feb/7/software-factory ; https://law.stanford.edu/2026/02/08/built-by-agents-tested-by-agents-trusted-by-whom/ (primary team write-up not opened) |
| Cognition Devin / Devin Desktop | Agent command center with a full IDE, multi-agent management, shared Spaces and PR review. Session sidebar with multi-select (late Aug/Sep 2026, unverified). Browser shows screenshots and recordings as proof of testing. Devin Review: "review every diff". | Reports 67% of Devin-created PRs merged in 2025, up from 34%. The number is a trust proxy. | [web] https://www.fast.io/resources/devin-session-tools-guide.md ; https://amplifying.ai/coding-agents/devin (secondary) |
| OpenAI Codex (cloud, /agents) | Cloud tasks run in an isolated sandbox and return a reviewable diff. Dispatch from CLI, Slack or GitHub. A `/agents` view for parallel agents (DevDay 2026, unverified). | "Read the diff before accepting." Trust is put on the reviewer. | [web] https://codex.danielvaughan.com/2026/04/08/codex-cloud-task-application/ ; https://openai.com/index/introducing-codex/ (primary, launch post) |
| Google Jules | Plan shown before code is written; user can revise; approval before PR. Jules V2 goal-driven (I/O 2026, reported, waitlist). CI auto-fix on failure (single source). | Gemini-powered; free tier; goal-setting replaces step-by-step prompting. | [web] https://www.testingcatalog.com/google-prepares-jules-v2-agent-capable-of-taking-bigger-tasks/ (speculative); https://techcrunch.com/2025/10/02/googles-jules-enters-developers-toolchains-as-ai-coding-agent-competition-heats-up |
| GitHub Copilot coding agent / Agent HQ | Mission Control: assign, steer and track many agents from one place. Branch controls govern checks. Metrics dashboard. Vendor-neutral: Claude, Codex, Cognition and others available on a paid Copilot plan. Slack and Linear integrations. | "Control tower for every coding agent." Governance and admin are the selling point. | [web] https://sdtimes.com/ai/github-unveils-agent-hq-the-next-evolution-of-its-platform-that-focuses-on-agent-based-development/ ; https://www.i-programmer.info/news/105-artificial-intelligence/18651-github-adds-claude-and-codex-to-agent-hq.html |
| Cursor (Cloud Agents, Cursor 3) | Agents Window alongside the IDE; many agents across local, worktree, cloud VM and SSH. Each cloud agent in its own VM with browser access and video recording; opens a PR and notifies by email, desktop or Slack. | "Agent-first" interface; the IDE is now one pane. | [web] https://medium.com/@tentenco/cursor-3-ships-an-agent-first-interface-heres-what-it-actually-changes-1f2bf8f383e2 ; https://www.morphllm.com/cursor-background-agents (secondary) |
| Linear (Agents, Linear Agent) | Agents are workspace members; a human stays the primary assignee and the agent is a contributor. "Understand every change at a glance; inspect the reasoning." Chat UI. | Issue tracker "moving sideways to agentic AI". Accountability stays with a person. | [web] https://linear.app/agents ; https://www.devclass.com/development/2026/03/27/linear-moves-sideways-to-agentic-ai-as-ceo-declares-issue-tracking-dead/5211661 |
| Sourcegraph Amp | Threads as the unit of work; Thread Map shows how threads relate; threads sync across terminal, web and mobile. | Agent work as a navigable history, not a chat. | [web] https://tessl.io/blog/amp-launches-thread-map-to-help-navigate-ai-coding-agent-work/ |
| Augment Code | Not researched (search returned nothing). | n/a | open item |

### 2.1 Patterns to take

- **Delegation keeps a human owner** (Linear, Copilot Mission Control). Every agent-run item shows one accountable human and one agent.
- **Evidence beside the change** (Devin screenshots and recordings, Cursor VM recording, Codex diff). Each run shows what was proven, not just what changed.
- **Plan before write** (Jules). Shipwright already has stages and gates, so show the stage plan and the gate contract up front.
- **One control tower over many agents** (Agent HQ, Cursor Agents Window). Shipwright's fleet is the same idea, self-hosted.
- **Threads and relationships** (Amp Thread Map). The daemon, pipeline and issue graph is already this data.

### 2.2 Patterns to avoid

- Dashboards that show agents "busy" with no verdict. Busy is not trust.
- Trust claimed by a single number (Devin's merge rate) with no drill-down.
- Pure marketing "dark factory" with no visible gate, which invites the criticism StrongDM is getting.

### 2.3 Award references (not verified)

The search did not return Awwwards pages for Linear, Vercel, Raycast, Warp or Resend, so this spec does not claim they won awards. The design principles used here are general and widely observed in those products: a restrained neutral base with one accent, tight type scale, keyboard-first command surfaces, and motion used only for state change. The T5 and T2 implementers should look at those sites directly, in a browser, before design review. Do not copy layouts.

---

## 3. Positioning

### 3.1 Shipwright's differentiators (all in the repo today [repo])

| Differentiator | Evidence in repo | Competitor position (from section 2) |
| --- | --- | --- |
| Self-hosted, three deployment modes (local, server, multi-machine) | `AGENTS.md` deployment modes M1/M2/M3 | Most are SaaS or vendor cloud. Copilot and Codex run on vendor infrastructure. |
| Safety gates that fail closed | `shipwright gates check`, "every gate fails closed", `docs/safety-runbook.md` (ADR-0007) | Governance is a dial in most products, not a fail-closed gate contract. |
| Differential test gate | `differential` appears in 6 docs/src/scripts files | Devin and Codex rely on the reviewer; Shipwright gates on test deltas. |
| Blast-radius guard | `blast` appears in 4 files | Not a visible feature in competitor docs. |
| Breaker and kill switch | `breaker` in 43 files; emergency brake route `/api/emergency-brake` | Agent HQ has governance controls; none shown as a fail-stop breaker. |
| Cost and DORA | DORA in 44 files; `/api/metrics/dora-trend`, `/api/costs/*` | Copilot has a metrics dashboard; DORA and per-run cost are rarer. |
| Self-improving loop | `compound` loop and STATE.md, memory and learning contexts | Amp and Devin learn in product; few show the learning as an auditable artifact. |
| Token and identity hygiene | F9: no GitHub token or permission bypass for agents | StrongDM and Factory emphasise governance; Shipwright enforces it in the architecture. |

### 3.2 The story

**"The dark factory you can trust."** Agents do the work unattended. Humans set the gates and read the evidence. Every change arrives with proof, every gate fails closed, and a single kill switch stops everything.

Message pillars, in order:

1. **Unattended, but never unsupervised.** You see what needs a human before anything ships.
2. **Evidence, not vibes.** Each run carries its gate verdicts, differential test result, blast radius and cost.
3. **Fail closed.** A gate that cannot decide stops the run. No silent pass.
4. **Yours.** Self-hosted on your machines, your keys, your audit log.
5. **Gets better.** The loop writes what it learned into durable, reviewable memory.

The UI must make pillars 2 and 3 legible on every screen where work is shown. Trust is a visible state (gate pills, breaker state, audit entries), never a footnote.

### 3.3 Tone

Short and literal. Nautical names stay in code and proper nouns (fleet, crew, shipwright). Copy says what happened: "Gate `differential-tests` failed: 3 new failures. Run stopped." Not "Your fleet is sailing".

---

## 4. Dashboard target information architecture

### 4.1 Decision: 13 tabs become 6 destinations

| Destination | Contents | Replaces |
| --- | --- | --- |
| **Triage** (default) | "Needs you" queue: failed gates, approvals pending, stalled runs, budget breaches, breaker trips, offline machines. Each row has a primary action and a reason. Fleet summary strip (running, queued, blocked, cost today). | Overview (rebuilt) |
| **Runs** | Run list with filters. Run detail: live stage timeline (11 stages), gate verdicts per stage, evidence panel (diff, files, test results, reasoning, failures), logs stream, stop/resume. | Pipelines, Timeline, Pipeline detail, Agent Cockpit (its per-agent logs fold into Run detail) |
| **Agents** | Live agent sessions, owner and agent pairing, current stage, heartbeat. **Fleet** section: machines (M3), claims, daemon state and config. | Agents, Machines |
| **Safety** | Gate and breaker state, emergency brake, approval gates, intervention history, audit log, alerts. This is the trust page. | Activity (reworked into audit log), Insights (its gate content) |
| **Cost and DORA** | Cost today and trend, per-run cost, DORA trend, throughput, failure heatmap, stage performance, bottlenecks, capacity. | Metrics, Insights (remaining) |
| **Settings** | Daemon config, notifications, auth and join tokens, team invites. | Team (moved), daemon config |

### 4.2 Cut or fold (be decisive)

- **Cut:** Shipyard view and its canvas scene, pixel sprites, submarine layout and theme, shipyard effects. They are the largest decorative code and say nothing about trust. Cut in T4.
- **Cut:** Theater (`pipeline-theater.ts`). It duplicates Runs detail. Fold any unique metric into Runs.
- **Cut:** Map (`fleet-map.ts`). Its useful part, machine placement, moves to Agents > Fleet as a plain list with status.
- **Cut:** The ambient "submarine" indicator and any animation that runs with no state change.
- **Keep:** Pipeline stage rail (`components/charts/pipeline-rail.ts`), sparkline, bar and donut (`components/charts`). They carry data.
- **Keep:** SSE log stream and WebSocket state. They are the real-time model.

Result: about 13 view modules and about 9,800 lines become roughly 6 destinations. The line count is an estimate; T4 must report the real number.

### 4.3 Operator jobs (acceptance scenarios)

1. **Triage in under 10 seconds.** Open the dashboard. The Triage queue shows what needs a human, first. Enter opens the item.
2. **Watch a run.** From Runs, see the live stage rail. A gate turning red is visible without scrolling.
3. **Inspect evidence.** Open a run's evidence. Diff, test deltas, blast radius and reasoning on one screen, keyboard only.
4. **Stop and resume.** Stop uses the existing intervention endpoint. It requires a confirmation dialog that names the run. Resume is the inverse. Both go through JSON POST with the auth token.
5. **Read the cost.** Cost today and per-run cost are on Triage (summary) and Cost and DORA (detail).
6. **Find the breaker.** The breaker and emergency-brake state is in the global header on every destination, never hidden.

### 4.4 Global chrome

- **Header.** Shipwright mark, destination tabs (`role="tablist"` with arrow-key navigation; this fixes the audit gap), connection state (live, reconnecting, stale with timestamp), breaker state pill, emergency-brake control, command palette button, user menu.
- **Command palette.** `Ctrl+K` / `⌘K`. Lists destinations, runs by number or title, and actions (stop, resume, open audit). Fuzzy match. Shows the keyboard shortcut for each item.
- **Keyboard.** `g` then `t`, `r`, `a`, `s`, `c` to go to destinations. `j` and `k` move rows, `Enter` opens, `Esc` closes the panel, `?` shows the shortcut sheet. Destructive actions are never single-key; they open a dialog and require focus on the confirm button.
- **Live run timeline.** A horizontal rail of the 11 stages from `STAGES` (`intake` to `monitor`), each segment coloured by gate verdict (pass, fail, pending, blocked, skipped). Hover and focus show the verdict text. Updated from `/ws` state; logs from `/api/logs/:n/stream`.
- **Diff and evidence viewer.** Read-only. Unified diff with file tree, from `/api/pipeline/:n/diff` and `/files`. Test results from `/test-results`, reasoning from `/reasoning`, failures from `/failures`. Lines are virtualised past 2,000 lines.
- **Empty states.** Each destination has one: "No runs yet. Label an issue `shipwright` or run `shipwright pipeline` to start one." The copy names the action; no illustrations.
- **Error states.** Each fetch failure shows the route, the HTTP status, a retry button and the last good data timestamp. No silent blank panels.
- **Offline state.** When `/ws` is down, a banner shows "Offline since 14:02. Showing data from 14:02." Actions that need the server are disabled with the reason, not hidden.
- **Loading.** Skeletons match the final layout dimensions to keep CLS under budget.

### 4.5 Security boundaries that do not change

- Token auth and CORS allowlist stay in `middleware/` and `services/request-guard.ts`.
- Writes stay JSON-only. No new route takes a shell string.
- F12 layering stays. New views import only `core/`, `components/` and `design/`, never `server.ts`.
- Optional: add a `Content-Security-Policy` header for the dashboard (`default-src 'self'`, no inline script). This needs a change to `server.ts`, which is ratcheted. It is an open question (section 11).

---

## 5. Design system

### 5.1 Principles

- One token contract. CSS custom properties are the source. `design/tokens.ts` generates or mirrors them, and a test fails on drift. Canvas, where still used, reads the same values.
- OKLCH for colour, so lightness steps are predictable and contrast is checkable.
- Dark is the default, light is a first-class theme. Both are tested.
- Motion communicates state change only. Reduced motion removes transform and keeps opacity at 100 ms or less.
- Density is a setting. Operators read dense tables; the landing reads loose.

### 5.2 Colour tokens (OKLCH; values are starting points, T1 validates contrast)

Dark (default):

| Token | Value | Use |
| --- | --- | --- |
| `--sw-bg-0` | `oklch(0.15 0.015 255)` | Page background |
| `--sw-bg-1` | `oklch(0.19 0.017 255)` | Panels, cards |
| `--sw-bg-2` | `oklch(0.24 0.02 255)` | Hover, inputs |
| `--sw-line` | `oklch(0.55 0.02 255)` | Borders, dividers (non-text, 3:1 min on bg-0, bg-1 and bg-2) |
| `--sw-text-1` | `oklch(0.96 0.005 255)` | Primary text (≥ 15:1 on bg-0) |
| `--sw-text-2` | `oklch(0.79 0.02 255)` | Secondary text (≥ 7:1) |
| `--sw-text-3` | `oklch(0.67 0.025 255)` | Muted text (≥ 4.5:1, the floor) |
| `--sw-accent` | `oklch(0.82 0.13 215)` | Primary accent (cyan, carried over from `#00d4ff`) |
| `--sw-accent-ink` | `oklch(0.15 0.015 255)` | Text on accent |
| `--sw-ok` | `oklch(0.82 0.16 150)` | Pass |
| `--sw-warn` | `oklch(0.86 0.15 85)` | Pending, attention |
| `--sw-danger` | `oklch(0.7 0.19 20)` | Fail, breaker tripped |
| `--sw-info` | `oklch(0.75 0.12 265)` | Informational |

Light (`:root[data-theme="light"]` and `prefers-color-scheme: light` when no explicit theme):

| Token | Value |
| --- | --- |
| `--sw-bg-0` | `oklch(0.985 0.004 255)` |
| `--sw-bg-1` | `oklch(1 0 0)` |
| `--sw-bg-2` | `oklch(0.955 0.008 255)` |
| `--sw-line` | `oklch(0.6 0.01 255)` |
| `--sw-text-1` | `oklch(0.2 0.02 255)` |
| `--sw-text-2` | `oklch(0.42 0.02 255)` |
| `--sw-text-3` | `oklch(0.5 0.02 255)` |
| `--sw-accent` | `oklch(0.52 0.12 230)` |
| `--sw-ok` | `oklch(0.5 0.14 150)` |
| `--sw-warn` | `oklch(0.5 0.13 70)` |
| `--sw-danger` | `oklch(0.52 0.19 25)` |

Status colours never carry meaning alone: every pill has an icon and a text label.

### 5.3 Type

- Families: body and UI in **Plus Jakarta Sans** (self-hosted woff2, latin subset, `font-display: swap`); mono in **JetBrains Mono** (self-hosted). **Instrument Serif** is for the landing display only. The dashboard must not load it.
- Licences: all three are SIL OFL. Confirm in T1 that the font files are included with their licence text.
- Scale (px, desktop; mobile steps down one): 12 (caption), 14 (body, dashboard default), 16 (body large, landing body), 20 (section), 24 (page title), 32 (landing h2), 48 and 64 (landing h1, fluid `clamp`). Ratio about 1.2 to 1.25.
- Line height: 1.5 body, 1.2 headings, 1.4 mono in tables.
- Numerals: tabular figures for every table and metric.

### 5.4 Spacing, radius, elevation, motion

- Spacing: 4 px base. Scale `1=4 2=8 3=12 4=16 5=20 6=24 8=32 10=40 12=48 16=64`. Matches the existing `tokens.ts` keys, so the migration is a rename.
- Radius: `sm 4`, `md 8`, `lg 12`, `xl 16`, `full`. Dashboard panels use `md`; landing cards use `lg`.
- Elevation: three levels. `e1` 1 px border only. `e2` `0 1px 2px oklch(0 0 0 / 0.3)`. `e3` `0 12px 32px oklch(0 0 0 / 0.4)` for palette and dialogs. No coloured glows (retire `shadows.glow.*`).
- Motion durations: `fast 120ms`, `base 200ms`, `slow 320ms`. The existing 150, 300, 500 and 1000 values are retired.
- Easing: `standard cubic-bezier(0.2, 0, 0, 1)`, `emphasized cubic-bezier(0.2, 0.8, 0.2, 1)`. Retire the spring curve.
- Reduced motion (`@media (prefers-reduced-motion: reduce)`): transforms and loops off; opacity transitions capped at 100 ms; live timeline updates without animation.

### 5.5 Component inventory

Build these once in `dashboard/src/components/ui/` and reuse on the landing where the markup matches (the landing uses Astro components with the same class names and tokens, not a shared runtime).

| Component | Notes |
| --- | --- |
| Button (primary, secondary, ghost, danger) | Danger always opens a confirm dialog |
| IconButton | Requires `aria-label` (enforced by a lint rule or test) |
| StatusPill | Gate verdicts and run states: icon plus text plus colour |
| Badge, Kbd | Keyboard hints in palette and tooltips |
| Card, Panel | `e1` border, `bg-1` |
| DataTable | Sortable, `aria-sort`, sticky header, keyboard row navigation |
| Tabs (tablist) | Arrow-key, Home, End; `aria-selected`, `aria-controls` |
| Dialog | Focus trap, `Esc`, return focus, `role="dialog"` with name |
| CommandPalette | Combobox pattern (`role="combobox"`, `aria-activedescendant`) |
| Toast | `role="status"`; errors use `role="alert"` |
| Tooltip | Hover and focus; never the only place for information |
| StageRail | The 11-stage timeline with verdict segments |
| DiffViewer | Virtualised unified diff |
| EvidenceCard | Test deltas, blast radius, reasoning excerpt |
| EmptyState, ErrorState, OfflineBanner, Skeleton | Section 4.4 |
| Sparkline, Bar, Donut | Existing `components/charts`, restyled to tokens |
| Form fields | Labelled inputs, visible focus, error text linked with `aria-describedby` |

### 5.6 Iconography and brand

- Icons: the existing inline lucide-style set in `dashboard/src/design/icons.ts` is kept. One stroke width (1.75 at 16 px and 20 px). No emoji in UI chrome.
- Mark: a new Shipwright mark (SVG, one colour, works at 16 px) replaces the `⚓` emoji. Deliver `brand/mark.svg` and a favicon set (`favicon.svg`, `favicon-32.png`, `apple-touch-icon.png`) generated from the SVG. Use the same mark on both surfaces.
- Wordmark: "Shipwright" in the body font, weight 600, no tagline in the chrome.
- Emoji policy: none in favicons, OG images, UI chrome or docs headings. Emoji in test fixtures and log content are data, not design.

### 5.7 Cross-surface consistency

- Retire the hex values in `website/design-system.md` and `dashboard/src/design/tokens.ts` in favour of the OKLCH contract in 5.2. The website reads the same CSS file (`website/src/styles/tokens.css`, generated from `dashboard/src/design/tokens.ts` or the reverse; one generator, one source).
- Starlight variables (`--sl-color-accent` and friends) are derived from the tokens in `custom.css`, so the docs and landing match.

---

## 6. Website

### 6.1 Landing narrative (sections, in order)

1. **Hero.** Headline: "The dark factory you can trust." Subhead: "Label an issue. Agents build it, prove it and open a PR. Every gate fails closed, and you hold the kill switch." Primary: Get started (`/quick-start/`). Secondary: GitHub.
2. **Interactive proof.** The hero visual is one pipeline rail (section 4.4 component) with a playback scrubber. Each stage turns green or red as the user scrubs. Shows the gate rule for the stage on hover or focus.
3. **Gates fail closed.** Three cards: a gate that cannot decide stops the run; a gate verdict is recorded with the reason; an override requires a named human and an audit entry.
4. **Evidence on every change.** Differential test gate, blast radius, reasoning, diff. A real example run in a static screenshot-free layout (SVG and text, not a screenshot).
5. **Fleet across machines.** Local, server and multi-machine as three columns. Matches `AGENTS.md` M1 to M3.
6. **Cost and DORA receipts.** Per-run cost and DORA metrics. Shows the fields the dashboard shows.
7. **It gets better.** The compound loop writes lessons to STATE.md and memory. Show the artifact, not a promise.
8. **Self-hosted, your keys.** What runs where; what leaves your network (nothing unless you configure a webhook or tracker).
9. **Compare.** Link to the comparison page (6.4).
10. **Get started.** Three commands. Copy buttons, no tracking.

Each section has one job, one heading, and no more than one primary action.

### 6.2 Interactive hero (cheap, progressive)

- Static SVG first. It renders complete with JavaScript off.
- Enhancement: a small module (≤ 4 KB gzip, no framework) that wires the scrubber. Loaded with `type="module"` and `defer`.
- No WebGL, no canvas, no third-party animation library. Pure CSS transitions on `transform` and `opacity` for stage state.
- `prefers-reduced-motion`: the scrubber starts at the final state; no autoplay.
- Keyboard: the scrubber is a native `input type="range"` with labels.

### 6.3 Docs theming

- Starlight accent and background variables come from `tokens.css` (section 5.7). Light and dark both pass contrast.
- Typography: body and mono self-hosted; no runtime font request to third parties. (A Google Fonts stylesheet is allowed on the website by the team's rule, but self-hosting is preferred for LCP.)
- Code blocks use the mono token and copy buttons with `aria-label`.
- The sidebar groups stay as they are; Starlight defaults are kept where they work.

### 6.4 Comparison page

- Route: `/compare/`. Content in `website/src/content/docs/compare.mdx`.
- Format: a factual matrix (hosting model, gate contract, evidence shown, multi-machine, cost visibility, self-hosting, license or source availability). Each cell cites the product's own public doc page with an "as of" date.
- Rule: no logos, no competitor trademark art, names used only in running text as nominative references. No claim without a dated source. Rows where a competitor is stronger stay in the table (for example, managed hosting, or a larger hosted integration catalogue).
- Tone: "Shipwright is self-hosted and fails closed. X runs on vendor infrastructure." Not "X is unsafe".
- Review gate: every row is re-verified against the vendor's own docs before publication (section 11).

### 6.5 Website technical budgets

- Landing HTML is generated from Astro components, not a single 37 KB string. The current `index.astro` injection is replaced in T5.
- Images: SVG where possible; any raster ≤ 40 KB and `loading="lazy"` below the fold.
- JS on the landing: ≤ 4 KB gzip total (hero enhancement only).
- Fonts: at most two woff2 files on the landing (body, mono), preloaded when used above the fold.

---

## 7. Hard budgets

| Area | Budget | Notes |
| --- | --- | --- |
| Accessibility | WCAG 2.2 AA on all dashboard destinations and all landing and docs pages | axe-core zero serious or critical violations; manual keyboard pass per release |
| Reduced motion | All motion honours `prefers-reduced-motion` | Test with Playwright `reducedMotion: 'reduce'` |
| Contrast | Text ≥ 4.5:1, large text and UI components ≥ 3:1, dark and light | Contrast validator in unit tests on the token values |
| LCP (landing, mobile emulation) | < 2.0 s | Lighthouse CI, Moto G profile, throttling defaults |
| INP (both surfaces) | < 200 ms at p75 | Lab proxy: Playwright event timing on the top ten interactions; real INP needs field data (open item) |
| CLS (both surfaces) | < 0.05 | Lighthouse CI on landing; Playwright layout-shift check on each dashboard destination |
| Dashboard JS, gzip, `dashboard/public/dist/main.js` | **≤ 120 KB** after T4; interim ceiling = measured baseline from T1 (no growth in T2 to T3) | The baseline is measured, not estimated. Canvas and sprites removal is the main lever |
| Dashboard CSS, gzip | ≤ 25 KB | |
| Landing JS, gzip | ≤ 4 KB | |
| Runtime CDN | 0 in the dashboard (no external origin in `dashboard/public` or `dist`) | Enforced by a test that greps built output for `http(s)://` origins other than the local host and the GitHub links |
| Security | Unchanged: token auth, CORS allowlist, JSON-only writes, F12, no shell from data, WS origin check | `bun run arch` and `dashboard:test` stay green |
| Findings ratchet | No new findings in `tools/arch/findings-baseline.json` | After any removal, run `bun tools/arch/ast-scan.ts --write-baseline` |

---

## 8. Verification plan

### 8.1 Checks per budget

| Budget | Automated check | Where | New? |
| --- | --- | --- | --- |
| Token contract and contrast | `dashboard/src/design/tokens.test.ts` extended: parse OKLCH values, compute WCAG contrast for every text and surface pair in both themes; fail on drift between `tokens.ts` and `tokens.css` | `bun run dashboard:test` | extend (T1) |
| Bundle size (JS and CSS gzip) | `tools/web/budget.ts`: runs `bun build --minify` into a temp outdir, gzips, compares to `tools/web/budget.json` | `bun run web:budget` | new (T1) |
| No runtime CDN | `tools/web/no-cdn.ts`: scans `dashboard/public` and built output for external origins | `bun run web:budget` | new (T1) |
| Dashboard a11y and keyboard | Playwright + `@axe-core/playwright` against a local dashboard with fixture data; keyboard-only flow tests for palette, tabs, run detail, stop dialog; reduced-motion run | `dashboard/e2e/` run in CI | new (T7) |
| Dashboard layout (CLS, phone width) | Playwright at 390 px and 1440 px; no horizontal scroll; layout-shift observer | `dashboard/e2e/` | new (T7) |
| Dashboard interaction latency | Playwright timing of the top ten interactions (click to next paint) against the INP budget | `dashboard/e2e/` | new (T7), lab proxy |
| Landing performance | Lighthouse CI on `website/dist` (mobile preset): LCP < 2000, CLS < 0.05, accessibility ≥ 0.95 (goal 1.0), best practices ≥ 0.95 | `lhci autorun` in CI | new (T7) |
| Landing a11y | axe on each landing and sample docs page | `website/e2e/` or Lighthouse CI | new (T7) |
| Security | `bun run arch`, `dashboard:test`, existing server API tests | existing `bun run check` | existing |
| Build | `astro build` and `bun run dashboard:build` succeed | `bun run check` plus web job | existing |

### 8.2 New CI jobs

- `web-budget` (T1): runs `web:budget` and the token tests. Fast, no browser.
- `web-e2e` (T7): installs Playwright Chromium once (cached), builds the dashboard, starts `dashboard/server.ts` on a random port with a fixture state, runs `dashboard/e2e`.
- `web-lighthouse` (T7): builds `website`, runs `lhci autorun` against `website/dist`.

These jobs are not required checks at first. They become required after one green week (maintainer decision).

### 8.3 Dependencies to add (need approval)

- `@playwright/test` and `@axe-core/playwright` (dev only, T7).
- `@lhci/cli` (dev only, T7).
- Playwright browser download runs in CI only, never in the repo.

### 8.4 Rule for "done"

A tranche is done when its acceptance criteria pass in CI and an independent verifier (the `compound-loop:verifier` agent, per the global rule for non-trivial changes) returns PASS with evidence. The author does not grade their own work.

---

## 9. Tranche plan

Seven tranches. Each is one PR. File ownership is disjoint: a file belongs to exactly one tranche. Where a tranche must touch a shared file, the owner is named and the other tranche depends on it.

Sizes: S (under 1 day), M (1 to 2 days), L (3 to 5 days). Estimates, not commitments.

### T1. Token and design-system foundation, verification harness (P1, M)

- **Owns (globs):** `dashboard/src/design/**`, `dashboard/public/fonts/**`, `dashboard/public/tokens.css` (new), `website/src/styles/tokens.css` (new, generated), `brand/**` (new), `dashboard/public/favicon.svg` (new), `tools/web/**` (new), `tools/web/budget.json`.
- **Depends on:** nothing.
- **Work:** Define the OKLCH token contract (section 5.2 to 5.4); generator or mirror into both CSS files; contrast test; self-host the three fonts with licence text; the Shipwright mark and favicon set; `web:budget` and `no-cdn` scripts; measure the current dashboard bundle and record the baseline in `tools/web/budget.json`.
- **Does not touch:** any `.ts` view or component, `styles.css`, any HTML file, `server.ts`, `website/src/pages`, `website/src/content`.
- **Acceptance:** `dashboard:test` green including the new contrast and drift tests; `web:budget` runs locally and in CI and prints the baseline; fonts load from the local origin only (verified by `no-cdn`); the mark renders at 16 px in both themes; no change to rendered UI yet.

### T2. Dashboard shell, IA and command palette (P1, L)

- **Owns (globs):** `dashboard/public/index.html`, `dashboard/public/styles.css`, `dashboard/src/components/header.ts`, `dashboard/src/components/modal.ts`, `dashboard/src/components/ui/**` (new), `dashboard/src/core/router.ts`, `dashboard/src/core/keys.ts` (new), `dashboard/src/core/keys.test.ts` (new), `dashboard/src/components/command-palette.ts` (new), `dashboard/src/components/command-palette.test.ts` (new).
- **Depends on:** T1 (tokens, fonts, favicon).
- **Work:** Tab bar becomes the six destinations with `role="tablist"`; remove the eleven retired tab buttons and panels (all except Overview and Agents, which are renamed or kept) from `index.html`; `VALID_TABS` reduced to the six plus redirects from old hashes (`#pipelines` to `#runs` and so on); global header with connection state, breaker pill and emergency brake; command palette and shortcut sheet; the UI component set (section 5.5) in `components/ui/`; focus styles; reduced motion; the favicon swap in `index.html`.
- **Does not touch:** view modules under `dashboard/src/views/**` (T3 and T4), `canvas/**`, `main.ts` (T4 owns the registration lines).
- **Acceptance:** Keyboard reaches every destination and every header control; the palette opens with `Ctrl+K`, lists destinations and runs, and closes with `Esc`; old tab hashes redirect; axe has zero serious violations on the shell; `dashboard:test` green; bundle does not grow past the T1 baseline.

### T3. Operator views: Triage, Runs, evidence, Safety (P1, L)

- **Owns (globs):** `dashboard/src/views/overview.ts`, `dashboard/src/views/overview.test.ts`, `dashboard/src/views/pipelines.ts`, `dashboard/src/views/pipelines.test.ts`, `dashboard/src/views/timeline.ts`, `dashboard/src/views/agents.ts`, `dashboard/src/views/activity.ts`, `dashboard/src/views/run-detail.ts` (new), `dashboard/src/views/evidence.ts` (new), `dashboard/src/views/safety.ts` (new), `dashboard/src/components/charts/pipeline-rail.ts` and its test, `dashboard/src/components/diff-viewer.ts` (new).
- **Depends on:** T2 (destinations, `components/ui`, router).
- **Work:** Triage queue (needs-you rows with reason and primary action); Runs list and run detail with StageRail, gate verdicts, evidence panel (diff, files, tests, reasoning, failures), log stream, stop and resume with a confirm dialog; Agents list with owner and agent pairing; Safety view (gates, breaker, approvals, interventions, audit log); empty, error and offline states per section 4.4.
- **Does not touch:** `metrics.ts`, `insights.ts`, `team.ts`, `machines.ts`, `fleet-map.ts`, `pipeline-theater.ts`, `agent-cockpit.ts`, `shipyard.ts` (T4), `canvas/**`, `core/api.ts` (add routes only in a follow-up tranche; use existing endpoints).
- **Acceptance:** Each operator job in section 4.3 is reachable by keyboard in three or fewer actions; Triage shows failed gates before idle runs in a fixture; evidence renders a 2,000-line diff without frame drops (virtualised); stop requires confirmation and sends a JSON POST with the token; `dashboard:test` green; new view tests cover loading, empty, error and offline.

### T4. Retire the decorative views and the canvas (P2, M)

- **Owns (globs):** `dashboard/src/canvas/**` (deleted), `dashboard/src/design/submarine-theme.ts` (deleted), `dashboard/src/views/shipyard.ts` (deleted), `dashboard/src/views/fleet-map.ts` (deleted), `dashboard/src/views/pipeline-theater.ts` (deleted), `dashboard/src/views/agent-cockpit.ts` (deleted), `dashboard/src/views/metrics.ts`, `dashboard/src/views/metrics.test.ts`, `dashboard/src/views/insights.ts`, `dashboard/src/views/machines.ts`, `dashboard/src/views/team.ts`, `dashboard/src/views/team.test.ts`, `dashboard/src/main.ts`, `dashboard/src/components/terminal.ts` (if unused after cuts).
- **Depends on:** T2 (tab IDs and destinations) and T3 (Fleet section lives in Agents, Cost and DORA takes metrics and insights).
- **Work:** Delete the four decorative views and the canvas; fold Machines into Agents as a Fleet section; fold Metrics and Insights into one Cost and DORA view; move Team to Settings; remove the registrations in `main.ts`; delete dead tests; regenerate `tools/arch/findings-baseline.json` (`bun tools/arch/ast-scan.ts --write-baseline`) only if findings were removed.
- **Does not touch:** `server.ts`, `services/**`, `routes/**`, `middleware/**`.
- **Acceptance:** Bundle at or below 120 KB gzip (or the T1 baseline if lower); no route or endpoint removed server-side; `dashboard:test` and `bun run arch` green; the findings baseline did not grow; the 13-tab bar is gone (verified by the e2e smoke in T7 or a manual check with the output attached).

### T5. Landing page rebuild (P1, L) [Docs area]

- **Owns (globs):** `website/src/pages/index.astro`, `website/src/components/landing/**` (new), `website/src/components/Footer.astro`, `website/public/index.html` (deleted after cut-over), `website/public/favicon.svg` (new), `website/public/brand/**`, `website/astro.config.mjs`, `website/src/assets/**`, `website/src/content/docs/index.mdx` (decision: retire or move; this tranche resolves the `/` route conflict).
- **Depends on:** T1 (tokens, mark, fonts).
- **Work:** Componentised landing with the 10 sections in 6.1; interactive pipeline hero per 6.2 (≤ 4 KB JS); favicon and OG image from the mark (no emoji); self-hosted fonts; comparison-link section; the fix for the `/` route collision (verify the built output first and record which page was served before the change).
- **Does not touch:** `website/src/styles/custom.css` (T6), `website/src/content/docs/**` other than `index.mdx`, the dashboard.
- **Acceptance:** Landing renders with JavaScript disabled; LCP < 2.0 s, CLS < 0.05 under Lighthouse mobile preset (T7 gate, or a manual run attached); JS ≤ 4 KB gzip; light and dark both pass contrast; the old 37 KB string is deleted.

### T6. Docs theming and comparison page (P2, M) [Docs area]

- **Owns (globs):** `website/src/styles/custom.css`, `website/src/content/docs/**` (except `index.mdx`, owned by T5), `website/src/content/docs/compare.mdx` (new), `website/src/components/docs/**` (new, if needed for the matrix).
- **Depends on:** T1 (tokens CSS). Independent of T2 to T4.
- **Work:** Starlight variables derived from `tokens.css`; mono and body fonts from the local origin; code-block copy buttons with labels; the comparison page per 6.4 with dated, sourced cells; update `dashboard.mdx` for the new six destinations and shortcut list.
- **Does not touch:** landing components (T5), dashboard (T2 to T4).
- **Acceptance:** Docs pages pass axe with zero serious violations on a sample of six pages; every comparison cell has a dated source URL; no competitor logo or trademark art; the dashboard guide matches the shipped destinations and shortcuts (checked by a grep against `keys.ts` in the review).

### T7. Verification in CI: a11y, performance and budgets (P1, M)

- **Owns (globs):** `dashboard/e2e/**` (new), `website/e2e/**` (new), `playwright.config.ts` (new, repo root or `dashboard/`), `lighthouserc.json` (new), `.github/workflows/web-quality.yml` (new), `tools/web/e2e-fixture/**` (new fixture state).
- **Depends on:** T1 (scripts), T2 and T3 (stable selectors and destinations), T5 (landing for Lighthouse). Start the Playwright harness on T2 and extend.
- **Work:** The three CI jobs in section 8.2; the fixture server state; keyboard and reduced-motion tests; the layout checks at 390 px and 1440 px; Lighthouse assertions; dependency additions per 8.3 with approval.
- **Does not touch:** source components. The e2e tests fail on regressions; they do not change UI.
- **Acceptance:** `web-budget`, `web-e2e` and `web-lighthouse` run green on `main`; a deliberate contrast regression fails the job (demonstrated once, output attached); the jobs are documented in `docs/` (CI section) and not yet required.

### 9.1 Dependency graph

```
T1 ──┬── T2 ── T3 ── T4
     │     └──────────┘ (T4 after T2 and T3)
     ├── T5
     ├── T6
     └── T2 ─┬─ T7 (dashboard e2e, starts after T2; extended after T3)
             └─ T5 ── T7 (Lighthouse)
```

Parallel after T1: T2 and T5 and T6 can run concurrently (disjoint files). T3 waits for T2. T4 waits for T3. T7 starts after T2 and finishes after T5.

### 9.2 Ordering rationale

- T1 first: every later check and every later visual change needs the token contract and the budget baseline.
- T2 before T3: the destinations and component set must exist before views use them.
- T4 late: deleting views is safe only after their unique content is folded in T3.
- T7 last in build order but starts early for the harness.

---

## 10. Risks

- **Scope.** The dashboard change touches about 13 views and 5,900 lines of CSS. Mitigation: T2 and T3 keep existing data endpoints; no server routes change in this epic.
- **Epic count.** The epic says 17 views; the repo has 13. The plan uses the real number.
- **Bundle baseline unknown.** Budgets in section 7 are firm once T1 measures. Until then they are estimates.
- **Competitor facts are secondary.** Several claims (Jules V2, Codex DevDay, Devin session sidebar, Factory valuation, Amp "rebrand") are unverified or conflicting. None goes on a public page unverified.
- **Trust framing.** StrongDM's no-human-review position is polarising. Shipwright's copy must contrast on evidence and fail-closed gates, not disparage.
- **Accessibility claims rest on grep.** No browser run was done for this audit. T7 is the first real measurement; expect findings.
- **Route collision on `/`.** The landing override and the docs splash both target the root. T5 must verify the built output.
- **Self-hosting fonts.** Adds about 3 to 6 woff2 files to the repo (size to check on a disk that is 99% full).

---

## 11. Open questions for the maintainer

1. **Cut list.** Confirm: retire Shipyard (view, canvas, sprites), Theater, Map and Cockpit; move Machines into Agents; merge Metrics and Insights; move Team to Settings. This is the single largest UX decision.
2. **CSP header.** Add `Content-Security-Policy` to the dashboard? It requires touching `dashboard/server.ts`, which is ratcheted. Approve a one-line header change, or defer?
3. **Dependencies.** Approve `@playwright/test`, `@axe-core/playwright` and `@lhci/cli` as dev dependencies (T7).
4. **Brand mark.** Approve retiring the `⚓` emoji for a new mark, and who owns the design (a generated SVG from the spec, or an external designer)?
5. **Required checks.** When do `web-e2e` and `web-lighthouse` become required on `main`?
6. **Real INP.** Lab INP is a proxy. Do we want field data (for example the `web-vitals` beacon to a self-hosted endpoint)? That adds a route and needs a privacy decision.
7. **Comparison page.** Publish a named comparison with competitors, or a category comparison ("self-hosted vs vendor-hosted agents") with no names? The spec assumes named but factual; the maintainer decides.
8. **Augment Code.** Not researched. Add it, or drop it from the set?
9. **Award references.** Confirm which award-calibre sites the maintainer wants used as the design bar; this spec did not verify any awards.
10. **Primary-source pass.** Before T5 and T6 publish, someone re-verifies every competitor claim against the vendor's own docs.

---

## 12. Sources

Repo (read at `origin/main` `24d24a489`):
- `AGENTS.md`, `.claude/rules/dashboard.md`, `docs/architecture.md` (F12), `docs/dashboard-exposure.md`, `docs/safety-runbook.md`
- `dashboard/server.ts`, `dashboard/src/core/router.ts`, `dashboard/src/core/api.ts`, `dashboard/src/core/ws.ts`, `dashboard/src/core/sse.ts`, `dashboard/src/main.ts`, `dashboard/src/design/tokens.ts`, `dashboard/src/design/submarine-theme.ts`, `dashboard/src/design/icons.ts`, `dashboard/public/index.html`, `dashboard/public/styles.css`
- `website/src/pages/index.astro`, `website/public/index.html`, `website/src/styles/custom.css`, `website/astro.config.mjs`, `website/design-system.md`, `website/src/content/docs/index.mdx`
- `package.json` scripts `dashboard:build`, `dashboard:prod`, `dashboard:test`, `arch`, `check`

Web (search results, Oct 2026 context):
- Factory: https://enterprisedna.co/resources/ai-map/company/factory
- StrongDM / dark factory: https://simonwillison.net/2026/Feb/7/software-factory ; https://law.stanford.edu/2026/02/08/built-by-agents-tested-by-agents-trusted-by-whom/
- Devin: https://www.fast.io/resources/devin-session-tools-guide.md ; https://amplifying.ai/coding-agents/devin
- OpenAI Codex: https://openai.com/index/introducing-codex/ ; https://codex.danielvaughan.com/2026/04/08/codex-cloud-task-application/
- Google Jules: https://techcrunch.com/2025/10/02/googles-jules-enters-developers-toolchains-as-ai-coding-agent-competition-heats-up ; https://www.testingcatalog.com/google-prepares-jules-v2-agent-capable-of-taking-bigger-tasks/
- GitHub Agent HQ: https://sdtimes.com/ai/github-unveils-agent-hq-the-next-evolution-of-its-platform-that-focuses-on-agent-based-development/ ; https://www.i-programmer.info/news/105-artificial-intelligence/18651-github-adds-claude-and-codex-to-agent-hq.html
- Cursor: https://medium.com/@tentenco/cursor-3-ships-an-agent-first-interface-heres-what-it-actually-changes-1f2bf8f383e2 ; https://www.morphllm.com/cursor-background-agents
- Linear: https://linear.app/agents ; https://www.devclass.com/development/2026/03/27/linear-moves-sideways-to-agentic-ai-as-ceo-declares-issue-tracking-dead/5211661
- Sourcegraph Amp: https://tessl.io/blog/amp-launches-thread-map-to-help-navigate-ai-coding-agent-work/

Not verified: Augment Code (no results); Linear, Vercel, Raycast, Warp, Resend award pages (no results).

---

## Appendix A. Files this spec touches or creates (summary)

- New: `brand/**`, `dashboard/public/tokens.css`, `dashboard/public/favicon.svg`, `dashboard/public/fonts/**`, `dashboard/src/components/ui/**`, `dashboard/src/core/keys.ts`, `dashboard/src/components/command-palette.ts`, `dashboard/src/views/run-detail.ts`, `dashboard/src/views/evidence.ts`, `dashboard/src/views/safety.ts`, `dashboard/src/components/diff-viewer.ts`, `website/src/styles/tokens.css`, `website/src/components/landing/**`, `website/src/content/docs/compare.mdx`, `tools/web/**`, `dashboard/e2e/**`, `website/e2e/**`, `playwright.config.ts`, `lighthouserc.json`, `.github/workflows/web-quality.yml`.
- Deleted (T4, T5): `dashboard/src/canvas/**`, `dashboard/src/design/submarine-theme.ts`, `dashboard/src/views/{shipyard,fleet-map,pipeline-theater,agent-cockpit}.ts`, `website/public/index.html`.
- Committed later to: `docs/superpowers/specs/2026-10-25-web-experience-design.md` (this file, after review).
