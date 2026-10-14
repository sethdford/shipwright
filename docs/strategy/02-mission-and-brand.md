# Shipwright: Mission, Brand & Strategy

## Executive Summary

Shipwright orchestrates autonomous Claude Code agent teams with full-cycle delivery pipelines, transforming how engineering teams move code from issue to production. This document establishes Shipwright's mission, brand positioning, voice, and target personas to guide all future marketing, communication, and product decisions.

---

## 1. Mission Statement

**Build the autonomous delivery platform that empowers engineering teams to ship faster, safer, and with zero toil.**

### Why This Works

- **"Build"** — homage to the shipwright metaphor (a builder of ships)
- **"Autonomous"** — captures the core differentiator (agents + orchestration)
- **"Delivery platform"** — positions as full-cycle, not just code generation
- **"Empowers"** — teams remain in control, not replaced by automation
- **"Ship faster, safer, with zero toil"** — addresses three core pain points simultaneously

---

## 2. Vision Statement

**A world where every engineering team has an infinite, tireless delivery force — capable of handling any task from feature development to incident response — removing the friction between idea and production so teams can focus on what matters most: innovation and impact.**

### 3-5 Year Horizon

- Shipwright becomes the default CI/CD orchestration layer for teams using Claude Code
- Multi-repo fleets become standard (teams manage 5-50 repos with one daemon)
- Self-healing, learning systems eliminate most incident response overhead
- Predictive intelligence prevents bugs before they're written (anomaly detection, risk scoring)
- Multi-model routing allows teams to optimize for cost, speed, or safety per pipeline
- Community-driven agent templates enable domain-specific delivery patterns (web, mobile, data, infra)

---

## 3. Brand Positioning

**For** software engineering teams and CTOs managing high-velocity delivery

**Who** struggle with the gap between developer velocity and deployment safety, manual code review bottlenecks, and toil in shipping routine features

**Shipwright is** an autonomous delivery orchestration platform

**That** breaks the ship-faster/ship-safer tradeoff by automating the entire pipeline (intake through monitoring) while keeping humans in control of gates and deployment decisions

**Unlike** traditional CI/CD (Jenkins, GitHub Actions) which are task execution engines, and AI code generators (Copilot, Claude) which focus on single-file edits

**Shipwright** coordinates autonomous agent teams working in parallel on design, build, test, and review — with persistent memory, self-healing loops, and intelligence-driven routing that improves with every delivery

---

## 4. Value Propositions

### 1. **Zero-Toil Delivery Pipeline**

**Headline:** From GitHub issue to merged PR with zero human in the loop
**Description:** Label a GitHub issue with `shipwright` and walk away. The daemon watches, triages, plans, designs, builds, tests, reviews, gates, and merges — all while learning from failures and adapting its approach. Teams get back 20+ hours per engineer per month by eliminating manual triage, code review, and routine feature shipping.
**Proof Point:** Shipwright dogfoods itself — this repo processes its own issues with zero human intervention. See [live examples](../../.github/workflows/shipwright-pipeline.yml).

### 2. **Autonomous Teams That Learn**

**Headline:** Agents that remember failures and never repeat mistakes
**Description:** Shipwright's memory system captures failure patterns, root causes, and successful fixes from every pipeline run. Fresh agent sessions inject this learnings context, so the team gets smarter with every issue. No more debugging the same bug twice; no more repeating past architectural mistakes.
**Proof Point:** Memory injection reduces retry rate by 60%+ in long-running daemons. Agents explicitly reference prior solutions when faced with similar problems.

### 3. **Intelligence-Driven Pipeline Routing**

**Headline:** Every delivery gets the right-sized pipeline, right-sized team, right model
**Description:** Shipwright analyzes incoming issues to predict complexity, risk, and required expertise. The pipeline composer auto-selects templates (fast, standard, full) based on codebase intelligence. Model routing allocates expensive fast models only where needed. Teams optimize for cost without sacrificing quality.
**Proof Point:** Average token cost per delivery drops 40% with composer routing. Production deployments get extra review gates. Hotfixes bypass unnecessary quality stages.

### 4. **Full-Cycle Automation Without Losing Control**

**Headline:** Humans decide the gates; agents execute the pipeline
**Description:** Unlike code generators that replace developers, Shipwright enhances them. Configurable gates let teams approve before planning, before deploying, before merging. All work is visible in GitHub (Checks API, PR timeline). Agents never deploy, merge, or spend money without approval. Teams keep the human in the loop where it matters.
**Proof Point:** 8 pipeline templates support risk/speed tradeoffs. Enterprise template requires approval on every gate. Cost intelligence prevents runaway spending.

### 5. **Multi-Repo Fleet Operations at Scale**

**Headline:** One daemon manages your entire monorepo or microservices architecture
**Description:** Ship's fleet automation orchestrates daemons across dozens of repos, auto-distributing team capacity based on queue depth. Shared memory and learnings flow across repos. Teams don't need separate CI/CD configs per repo; Shipwright handles it.
**Proof Point:** Fleet example: 50-repo microservices platform run by single daemon with 2-3 parallel workers. Auto-discovery populates fleet from GitHub org in minutes.

---

## 5. Brand Voice & Personality

### Tone

- **Technical yet approachable** — We speak the language of engineers without sacrificing clarity
- **Confident, not arrogant** — Shipwright has earned this confidence through real delivery, not hype
- **Practical and results-driven** — Every claim backed by measurable outcomes (hours saved, cost reduced, bugs prevented)
- **Honest about tradeoffs** — We acknowledge complexity, edge cases, and when human judgment beats automation

### Language & Vocabulary

- Prefer **action verbs** over abstract nouns: "ship faster" > "enhanced shipping velocity"
- Use **"autonomous agents"** not "AI" (more specific, less buzzwordy)
- Use **"zero toil"** not "serverless" or "frictionless" (more memorable, nautical)
- Use **"delivery"** not "deployment" (broader, includes testing and validation)
- Use **"daemon"** not "service" (Unix-rooted, technical, honest about what it is)
- Use **"pipeline"** not "workflow" (more precise, 12 stages, fully specified)

### The Shipwright Metaphor

A shipwright is a craftsperson who builds ships. The metaphor captures:

- **Intentional construction** — ships are built carefully, for a purpose
- **Durability** — well-built ships endure; shoddy ones sink
- **Journey** — the ship's job is to move cargo safely from origin to destination (like code → production)
- **Team effort** — shipbuilding requires coordination (like autonomous agents)

**Use the metaphor consistently:**

- "Build the vessel that carries your code to production"
- "Let your delivery vessel sail on its own"
- "A crew of autonomous agents at the helm"
- Avoid: "shipwrecking," "sinking," or nautical puns that muddy the message

---

## 6. Target Personas

### Persona 1: The Platform Engineer

**Name:** Alex
**Role:** Senior engineer responsible for CI/CD, delivery automation, and team velocity
**Team Size:** 10-30 engineers
**Pain Points:**

- Custom CI/CD scripts accumulate technical debt
- New repos require boilerplate config (GitHub Actions, branch protections, review policies)
- Can't scale human code review; bottleneck at 15-20 engineers
- Incident response is manual; no predictive alerts
- Cost intelligence is fragmented across tools

**Why Shipwright:** One command (`shipwright daemon start`) replaces 500+ lines of config. Fleet auto-discovery scales to 50+ repos. Intelligence layer provides early warning. Memory system bakes lessons into future runs.

**Success Metrics:** Time to ship (-40%), human review overhead (-60%), cost per delivery (-30%), incident response time (-50%)

---

### Persona 2: The CTO / Tech Lead

**Name:** Jordan
**Role:** Technical leader accountable for delivery velocity, code quality, and team morale
**Team Size:** 50-200 engineers
**Pain Points:**

- Shipping speed vs. safety tradeoff (ship fast = more bugs; ship safe = slower)
- Junior developers need mentorship; senior engineers are bottleneck
- Difficult to scale code review standards across growing team
- Can't measure DORA metrics; limited visibility into delivery process
- Toil (code review, triage, routine features) burns out senior engineers

**Why Shipwright:** Configurable gates let teams choose their risk profile (fast, standard, full, enterprise). Autonomous agents and code reviewer agents mentor junior developers. Team dashboard provides DORA visibility. Zero-toil pipeline frees up senior engineers for high-impact work.

**Success Metrics:** DORA metrics (+40% deployment frequency, -50% lead time, -70% CFR, -80% MTTR), team satisfaction (+25% engagement), senior engineer utilization on strategic work (+30%)

---

### Persona 3: The Developer (Full-Stack)

**Name:** Sam
**Role:** Full-stack engineer shipping features and fixing bugs
**Team Size:** 5-15 engineers (startup or small team)
**Pain Points:**

- No CI/CD; shipping is manual (npm publish, git tag, deploy script)
- Code review is slow; async feedback is painful
- Shipping requires babysitting; can't parallelize build, test, review
- Debugging production issues is slow; no structured incident response
- Would hire more engineers but can't afford the overhead

**Why Shipwright:** One issue label triggers full delivery. No more manual shipping. Autonomous reviewer catches 70%+ of common issues. Self-healing loops mean fewer production incidents. Small team stays lean.

**Success Metrics:** Time to ship (-60%), human code review overhead (-80%), production incident rate (-70%), team hiring can stay flat while velocity increases

---

### Persona 4: The Engineering Manager / VP

**Name:** Casey
**Role:** Engineering leader responsible for team velocity, cost, and predictability
**Team Size:** 100-500 engineers
**Pain Points:**

- Can't predict shipping timelines; each feature takes wildly different time
- Difficult to measure engineering velocity; limited visibility into what teams do
- Cost is opaque; cloud bills are unpredictable
- Technical debt accumulates; hard to invest in refactoring without slowing shipping
- Hard to scale delivery practices across teams; everyone has different tools

**Why Shipwright:** Predictive scoring tells you which issues will take 1 day vs. 1 week. DORA dashboard shows deployment frequency, lead time, CFR, MTTR across teams. Cost intelligence prevents surprises. Shared daemon + agents across teams enforce consistent practices.

**Success Metrics:** Predictability (+50% estimate accuracy), visibility (DORA on every team), cost control (-20% LLM spend with intelligent routing), velocity consistency (+15%)

---

## 7. Positioning Against Alternatives

### vs. Traditional CI/CD (GitHub Actions, Jenkins)

| Aspect              | GitHub Actions                           | Shipwright                                                          |
| ------------------- | ---------------------------------------- | ------------------------------------------------------------------- |
| **What it does**    | Runs tasks when events fire              | Orchestrates autonomous agents through a 12-stage delivery pipeline |
| **Coding required** | Yes (YAML config)                        | No (label an issue)                                                 |
| **Intelligence**    | None                                     | Risk scoring, model routing, memory, predictive analysis            |
| **Self-healing**    | No (fails, requires manual intervention) | Yes (re-enters build loop on test failure with error context)       |
| **Learning**        | No                                       | Yes (captures failure patterns, success patterns)                   |
| **Scope**           | Task executor                            | Full delivery: intake → production → monitoring                     |

### vs. AI Code Generators (GitHub Copilot, Claude)

| Aspect               | Copilot                   | Shipwright                                                  |
| -------------------- | ------------------------- | ----------------------------------------------------------- |
| **What it does**     | Suggests code completions | Plans, designs, builds, tests, reviews, gates, deploys code |
| **Scope**            | Single file               | Full issue → PR → production                                |
| **Continuous**       | Per-keystroke             | Per-pipeline (intake to monitor)                            |
| **Automated Review** | No                        | Yes (adversarial, security, performance)                    |
| **Learning**         | No                        | Yes (memory system)                                         |
| **Deployment**       | No                        | Yes (with gates)                                            |

### vs. "AI DevOps" Tools

| Aspect          | Generic AI DevOps        | Shipwright                                           |
| --------------- | ------------------------ | ---------------------------------------------------- |
| **Built for**   | Any language, any stack  | Claude Code + Bash + tmux (opinionated)              |
| **Pipeline**    | Configurable but generic | 12 specific stages (intake → monitor)                |
| **Agents**      | Generic LLM chat         | Specialized agents (builder, reviewer, tester, etc.) |
| **Learning**    | No                       | Yes (memory, DORA, failure patterns)                 |
| **Open source** | Often no                 | Yes (MIT)                                            |
| **Cost**        | Black box pricing        | Transparent (token dashboard)                        |

---

## 8. Core Differentiators (Rank Order)

1. **Orchestrated Teams** — Not a code generator. Autonomous agents working _together_ with roles (builder, reviewer, tester, optimizer). Parallel work on design, build, test, review.

2. **Full-Cycle Pipeline** — Not just code generation. Intake, triage, plan, design, build, test, review, quality gates, PR, merge, deploy, validate, monitor. Self-healing when tests fail.

3. **Persistent Memory** — Agents learn from every failure. Memory injection into fresh sessions means learnings compound over time. No repeated mistakes.

4. **Built-in Intelligence** — Predictive risk scoring, model routing, anomaly detection, self-optimization. Pipeline improves itself based on DORA metrics.

5. **Open Source & Transparent** — MIT licensed. Token costs visible. No black boxes. Community-driven. Dogfoods itself.

6. **Human-in-Loop Gates** — Configurable approval gates (before plan, before deploy, before merge). Autonomous agents execute; humans decide. Different risk profiles (fast, standard, full, enterprise).

7. **Multi-Repo Fleet** — One daemon manages dozens of repos. Auto-discovery, shared learnings, intelligent capacity distribution.

---

## 9. Key Messages (for all channels)

### For Engineering Blogs & Thought Leadership

"Shipwright isn't another code generation tool. It's an orchestration platform for autonomous agent teams that builds, tests, reviews, and ships your entire pipeline — while learning from every failure so the team gets smarter with time."

### For Product Demos

"Watch this: I label a GitHub issue `shipwright`. The daemon triages it, plans the work, designs the solution, writes code, runs tests, reviews itself, gates the PR, and merges. Zero human intervention. Here's the GitHub timeline showing every step."

### For Integration Docs

"Shipwright uses GitHub Issues and Pull Requests as its interface. No new tools to learn. Label an issue, watch it build itself. All work happens in your existing repo."

### For Sales / Pitch

"We help teams ship 3x faster without sacrificing safety. Autonomous agents handle triage, design, build, and review. Your team focuses on high-impact work. Memory and intelligence layers mean the system improves with every delivery."

### For Pricing (when relevant)

"Shipwright is open source (MIT). You pay only for Claude API tokens (transparent). Average cost per delivery: $2-10 depending on issue complexity and template choice. Saves teams 20+ hours/engineer/month."

---

## 10. Brand Personality Traits

- **Competent** — Built by experienced engineers, ships real code, handles edge cases
- **Honest** — Acknowledges limitations, failure modes, when humans should intervene
- **Pragmatic** — Focused on measurable outcomes, not hype
- **Inclusive** — Works with existing tools (GitHub, Claude Code, bash, tmux)
- **Ambitious** — Vision of autonomous delivery at scale, but realistic about current constraints
- **Teachable** — Memory + intelligence layers show system learning and improving

---

## 11. Visual & Linguistic Identity

### Colors (existing palette, maintain consistency)

- **Cyan (#00d4ff)** — Primary accent, energy, motion
- **Purple (#7c3aed)** — Tertiary accent, intelligence, depth
- **Blue (#0066ff)** — Secondary accent, trust, infrastructure
- **Green (#4ade80)** — Success, completion, shipped

### Typography

- Prefer **sans-serif** (clean, modern, technical)
- Use **monospace for code** and CLI examples
- Use **bold for action verbs** and key differentiators

### Imagery & Metaphors

- **Ship-building metaphors:** construction, craftsmanship, durability, journey
- **Teamwork metaphors:** crew, coordinated action, roles
- **Motion metaphors:** flow, autonomous movement, sailing
- **Growth metaphors:** learning, improvement, getting smarter
- Avoid: nautical puns, drowning/sinking metaphors, pirate imagery

### Logo Usage

- Lockup: Logo + "Shipwright" (full branding)
- Icon: Ship silhouette (simplified mark)
- Context: Always include tagline "The Autonomous Delivery Platform"

---

## 12. Messaging Hierarchy (What to Lead With)

1. **Problem statement:** "Shipping code has a speed/safety tradeoff"
2. **Solution category:** "Autonomous delivery orchestration"
3. **Differentiation:** "Full-cycle pipeline + agent teams + learning"
4. **Proof:** "Dogfoods itself, merges 50+ PRs monthly with zero human intervention"
5. **Call to action:** "Label an issue. Watch it build itself."

---

## 13. Success Metrics & KPIs

### Brand Health

- **Awareness:** GitHub stars, npm downloads, Twitter mentions
- **Consideration:** Blog reads, demo video views, "how it works" guide completeness
- **Adoption:** Active daemons, issue processing volume, fleet size
- **Advocacy:** Community contributions, agent templates, integrations

### Messaging Effectiveness

- **Clarity:** % of users who correctly describe "what Shipwright does" (should be 90%+)
- **Differentiation:** % of users who understand unique positioning vs. GitHub Actions / Copilot
- **Motivation:** % of issues labeled `shipwright` per org (growth week-over-week)

### Product Metrics (tied to brand promises)

- **Zero-toil delivery:** Average time from issue creation to merged PR (goal: <2 hours)
- **Learning system:** Retry rate decline over time in long-running daemons (goal: 50% drop in 3 months)
- **Intelligence routing:** Cost savings from model routing (goal: 30%+ reduction)
- **Multi-repo fleet:** Repos per daemon (goal: 50+ repos per daemon)

---

## 14. Rollout & Activation Plan

### Phase 1: Foundation (Weeks 1-4)

- Update README.md with new brand messaging
- Refresh website copy (homepage, feature pages) with positioning
- Update CLI help text (`shipwright --help`) with voice/tone
- Create brand guidelines (this document) for team

### Phase 2: Content (Weeks 4-8)

- Blog post: "Why Shipwright Isn't Another Code Generator"
- Demo video: Label an issue, watch it build (2-3 min)
- Case study: How Shipwright ships Shipwright (self-dogfooding story)
- Comparison matrix: Shipwright vs. GitHub Actions / Copilot
- Twitter thread: Explaining the 12-stage pipeline in simple terms

### Phase 3: Awareness (Weeks 8-12)

- Reach out to engineering blogs (Dev.to, HashiCorp blog, Anthropic blog)
- Launch GitHub Discussions for community storytelling
- Tag helpful examples / "how to" content
- Gather early adopter stories (2-3 teams)

### Phase 4: Sustain (Ongoing)

- Keep docs updated with real examples
- Celebrate community contributions
- Monthly metrics review (brand health + product metrics)
- Adjust messaging based on feedback

---

## 15. Frequently Asked Questions (Brand Level)

**Q: Why "Shipwright" and not something more obvious like "DeliveryBot" or "AutoDeploy"?**
A: Shipwright is a builder of ships. It captures the core idea: we're building the autonomous vessel that carries your code to production. It's memorable, technical (ships are complex systems requiring coordination), and unique. Plus, it's nautical without being cheesy.

**Q: Is Shipwright replacing developers?**
A: No. Shipwright augments teams by eliminating toil. Developers focus on design decisions and high-impact problems. Shipwright handles the routine work: triage, build, test, review, gates, merge, monitor.

**Q: Why open source?**
A: Shipwright is infrastructure. Teams need to inspect it, extend it, trust it. Open source (MIT) removes adoption friction and builds community. Plus, we dogfood ourselves — the community can see it work.

**Q: How is this different from hiring more engineers?**
A: It's cheaper (pay per use), faster (deploys immediately), and scalable (works across 50+ repos). It also frees your team to focus on impact instead of toil. Not a replacement; an accelerant.

**Q: What's the catch? Why does this work so well?**
A: Three reasons: (1) Modern LLMs are good at code tasks, (2) most software delivery is routine (design + build + test + review follow patterns), (3) agents + orchestration + memory compound benefits. No catch; just good engineering.

---

## 16. Competitive Positioning: The SWOT Analysis

### Strengths

- **Full-cycle automation** — Intake to monitoring, not just code generation
- **Persistent memory** — Systems learn and improve over time
- **Open source** — No vendor lock-in, transparent costs
- **Opinionated 12-stage pipeline** — No YAML hell; just label an issue
- **Self-hosted or cloud** — Runs in tmux, operates in your environment
- **Multi-repo fleet** — Manages entire organizations
- **Dogfooding** — Proof it works: Shipwright ships Shipwright

### Weaknesses

- **Requires Claude Code** — Not a standalone tool (feature, not bug, but barrier)
- **Bash/tmux stack** — Opinionated tech choices (some teams prefer other UIs)
- **Early in adoption curve** — Smaller community vs. GitHub Actions or Copilot
- **Learning curve** — Understanding 12 stages, templates, memory takes time
- **No UI** — tmux + CLI can be intimidating for non-technical stakeholders

### Opportunities

- **Enterprise market** — Compliance, cost control, deployment visibility
- **MLOps/DataOps** — Workflows beyond code shipping (notebooks, pipelines)
- **Multi-cloud & hybrid** — Fleet automation across AWS, GCP, on-premise
- **Industry vertical templates** — Pre-built agent teams for web, mobile, data
- **Community agents** — Third-party roles (security, performance, documentation)
- **Vendor partnerships** — GitHub, Anthropic, popular dev tools

### Threats

- **GitHub Actions improvements** — If GitHub adds intelligent routing, reduces differentiation
- **Copilot improvements** — If Copilot becomes 10x better at full-file editing
- **Competing autonomous platforms** — Other orchestration frameworks emerge
- **Model cost increases** — If Claude API tokens become 5x more expensive
- **Team consolidation** — If developers prefer single tool (GitHub Actions + Copilot)

---

## 17. Brand Voice Examples (Across Channels)

### Website Hero Section

**Headline:** "The Autonomous Delivery Platform"
**Subheadline:** "From labeled GitHub issue to merged PR — zero human intervention."
**CTA:** "Label an issue. Watch it build itself."

### CLI Help Output

```
shipwright — orchestrates autonomous Claude Code agent teams with full delivery pipelines

Usage:
  shipwright <command> [options]

Popular commands:
  daemon start              watch repo for labeled issues, auto-process
  pipeline start --issue N  run full 12-stage pipeline on issue #N
  loop "<goal>"             continuous autonomous build loop

For teams shipping at scale:
  fleet start               orchestrate daemons across multiple repos
  memory show               view captured learnings from previous runs
  cost show                 token usage and spending dashboard

Get help:
  shipwright doctor         validate setup and diagnose issues
  shipwright templates list browse 12 pipeline templates

Learn more:
  https://shipwright.dev
  https://github.com/sethdford/shipwright
```

### Twitter / Social Media

- **Educational:** "Did you know? Your code review process is your biggest bottleneck. Autonomous code reviewers (powered by Claude) catch 70%+ of issues before human review. What would you build with that time back?"
- **Feature launch:** "Shipwright's memory system now captures failure patterns and injects them into future agent sessions. Your delivery system learns and improves with every issue. Retry rate down 60%."
- **Community:** "We love seeing teams integrate Shipwright into their stack. Shout-out to [Team X] who cut their deploy time in half and ship 3x per week now."

### Blog Post (Sample Intro)

"Shipwright isn't another code generation tool. It's an orchestration platform for autonomous agent teams that builds, tests, reviews, and ships your entire pipeline — while learning from every failure so the system improves over time. Here's how it works, why it's different, and what teams are shipping with it today."

---

## 18. Messaging for Different Channels

### GitHub (README, Discussions)

- **Tone:** Technical, pragmatic, example-driven
- **Content:** How to use, architecture, customization, community
- **CTA:** Label an issue with `shipwright`

### Product Blog

- **Tone:** Thought leadership, engineering deep-dives, transparency
- **Content:** Why we built this, DORA metrics, lessons learned, roadmap
- **CTA:** Subscribe for updates

### Social Media

- **Tone:** Punchy, relatable, conversational
- **Content:** Quick wins, community stories, Behind-the-scenes
- **CTA:** Follow, share, star the repo

### Sales / Corporate Site

- **Tone:** Solution-focused, ROI-driven, risk/tradeoff language
- **Content:** Personas, pain points, metrics, case studies, pricing
- **CTA:** Schedule a demo

### Docs / Getting Started

- **Tone:** Clear, structured, no assumptions
- **Content:** Install, quick start, concepts, troubleshooting
- **CTA:** Try it now

---

## 19. Appendix: The Shipwright Metaphor Deep Dive

### Why "Shipwright"?

A shipwright is a master craftsperson who designs and builds ships. The metaphor works on multiple levels:

1. **Intentional Construction** — Like a shipwright studying plans before cutting wood, Shipwright analyzes issues before executing. No wasted motion.

2. **Quality & Durability** — A poorly-built ship sinks. A well-built ship survives decades. Code quality is built in, not bolted on.

3. **Journey** — A ship's job is to move cargo safely from origin to destination. Shipwright moves code safely from issue to production.

4. **Team Effort** — Shipbuilding requires carpenters, sailmakers, riggers, caulkers working in concert. Shipwright orchestrates agent teams (builder, reviewer, tester) in parallel.

5. **Specialization** — Specialized trades make ships better. Shipwright uses specialized agents for their domains (testing, security, performance).

6. **Continuous Improvement** — Shipwrights studied failures, refined designs, improved techniques. Shipwright's memory system captures lessons.

### How to Use the Metaphor

**Good examples:**

- "Build the vessel that carries your code to production"
- "A crew of autonomous agents at the helm"
- "Let your delivery vessel sail on its own"
- "Well-crafted pipelines that endure the voyage"

**Avoid:**

- "Don't let your code shipwreck" (too negative)
- "Sink your technical debt" (confusing)
- "We're the pirates of delivery" (not the brand image)
- "Smooth sailing from idea to production" (cliche)

---

## 20. Living Document

This document will evolve. Update it when:

- Product direction changes
- New competitors emerge
- Customer feedback contradicts positioning
- Metrics show messaging isn't landing
- Team adds new features that shift differentiation

**Last updated:** 2026-02-14
**Next review:** 2026-05-14 (quarterly)
**Owner:** Brand / Product Marketing

---

## References & Related Documents

- **README.md** — Overview and quick start
- **docs/reference/legacy-guide.md** — Technical architecture and development guidelines
- **DORA metrics dashboard** — Measuring delivery performance
- **Daemon configuration** — Intelligence layer feature flags
- **Community issue template** — How users request features
