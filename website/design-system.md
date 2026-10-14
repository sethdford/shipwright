# Shipwright Design System — Refined Depths

Version 3.0 — March 2026

---

## 1. Brand Strategy

### Direction

"Refined Depths" — Apple-level restraint applied to the existing nautical identity. The ocean palette stays, but gets quieter and deeper. One primary accent color (cyan) carries the entire brand. Purple and blue exist only as gradient endpoints for hero moments.

### Brand Voice

Short. Confident. Let the product speak.

- **Before:** "Your fleet awaits, captain. Set sail with a single command."
- **After:** "One command. Issue to production."

Nautical metaphors live in naming (fleet, crew, shipwright, launch) not in UI copy. The metaphor is architectural, not decorative.

### Brand Pillars

- **Autonomy** — Zero human intervention from issue to PR
- **Quality** — Compound quality loops, self-healing builds, automated review
- **Scale** — One daemon, one fleet, one org — the architecture grows with you
- **Intelligence** — Persistent memory, adaptive templates, self-optimizing metrics

### Scope

Unified across all surfaces:

- Website / marketing pages
- Skipper dashboard (light + dark modes)
- Terminal output (ANSI colors, box-drawing)
- README / documentation
- Public dashboard

---

## 2. Color Palette

### Dark Mode (Default)

#### Backgrounds — Ocean Depths, Quieted

Near-black with subtle cool undertones. Less saturated than V2.

| Token       | Hex       | Usage                                  |
| ----------- | --------- | -------------------------------------- |
| `--abyss`   | `#050508` | Page background, deepest layer         |
| `--deep`    | `#0a0d14` | Card backgrounds, nav backdrop         |
| `--ocean`   | `#111520` | Elevated surfaces, hover states        |
| `--surface` | `#171c28` | Active states, input fields            |
| `--foam`    | `#1e2536` | Tooltips, dropdowns, highest elevation |

#### Accent — Cyan Primary

| Token           | Value                     | Usage                                      |
| --------------- | ------------------------- | ------------------------------------------ |
| `--cyan`        | `#00d4ff`                 | Primary accent, CTAs, active states, links |
| `--cyan-subtle` | `rgba(0, 212, 255, 0.08)` | Hover backgrounds, active nav items        |
| `--cyan-muted`  | `rgba(0, 212, 255, 0.25)` | Borders, dividers, scrollbar thumbs        |
| `--purple`      | `#7c3aed`                 | Gradient endpoints only. Never standalone. |
| `--blue`        | `#0066ff`                 | Gradient endpoints only. Never standalone. |

#### Status

| Token     | Hex       | Usage                       |
| --------- | --------- | --------------------------- |
| `--green` | `#4ade80` | Success, completed, passing |
| `--amber` | `#fbbf24` | Warning, in-progress        |
| `--rose`  | `#f43f5e` | Error, failed, critical     |

#### Text

| Token              | Hex       | Usage                        |
| ------------------ | --------- | ---------------------------- |
| `--text-primary`   | `#e8eaed` | Headlines, body text         |
| `--text-secondary` | `#8b8f9a` | Descriptions, subtitles      |
| `--text-muted`     | `#555a66` | Labels, timestamps, disabled |

### Light Mode

Cool grays with ocean undertones. No warm beige.

| Token              | Hex       | Usage                               |
| ------------------ | --------- | ----------------------------------- |
| `--abyss`          | `#f8f9fa` | Page background                     |
| `--deep`           | `#ffffff` | Card backgrounds                    |
| `--ocean`          | `#f1f3f5` | Elevated surfaces                   |
| `--surface`        | `#e9ecef` | Active states, inputs               |
| `--foam`           | `#dee2e6` | Tooltips, dropdowns                 |
| `--cyan`           | `#0091b3` | Darker cyan for light-mode contrast |
| `--text-primary`   | `#1a1d21` | Body text                           |
| `--text-secondary` | `#495057` | Secondary text                      |
| `--text-muted`     | `#868e96` | Labels, timestamps                  |

### Gradients — Restrained

One primary gradient for hero moments and primary CTAs:

```css
background: linear-gradient(135deg, #00d4ff, #7c3aed);
```

No shimmer animations. No gradient text on body copy. One or two anchor moments per page.

### ANSI Terminal Colors

| Role           | ANSI        | Hex equivalent |
| -------------- | ----------- | -------------- |
| Primary accent | Cyan (36)   | `#00d4ff`      |
| Success        | Green (32)  | `#4ade80`      |
| Warning        | Yellow (33) | `#fbbf24`      |
| Error          | Red (31)    | `#f43f5e`      |
| Muted text     | Dim (2)     | —              |
| Box-drawing    | Cyan dim    | —              |

---

## 3. Typography

### Font Stacks

Zero web fonts. Native platform rendering.

```css
--font-body:
  -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, "Helvetica Neue",
  sans-serif;
--font-mono: "SF Mono", ui-monospace, "Cascadia Code", "Geist Mono", monospace;
```

No `--font-display`. Headlines use the same sans-serif stack at heavier weights.

### Type Scale

Base: 16px. Ratio: 1.200 (minor third).

| Token         | Size              | Weight | Line-height | Letter-spacing |
| ------------- | ----------------- | ------ | ----------- | -------------- |
| `--text-5xl`  | `3rem` (48px)     | 700    | 1.1         | `-0.02em`      |
| `--text-4xl`  | `2.5rem` (40px)   | 700    | 1.1         | `-0.02em`      |
| `--text-3xl`  | `2rem` (32px)     | 600    | 1.15        | `-0.02em`      |
| `--text-2xl`  | `1.5rem` (24px)   | 600    | 1.2         | `-0.02em`      |
| `--text-xl`   | `1.25rem` (20px)  | 500    | 1.3         | `-0.01em`      |
| `--text-lg`   | `1.125rem` (18px) | 400    | 1.5         | `0`            |
| `--text-base` | `1rem` (16px)     | 400    | 1.6         | `0`            |
| `--text-sm`   | `0.875rem` (14px) | 400    | 1.5         | `0`            |
| `--text-xs`   | `0.75rem` (12px)  | 500    | 1.4         | `0.02em`       |

### Rules

- No gradient text on headlines. Solid `--text-primary`.
- Body text max-width: `65ch`.
- Mono reserved for: code blocks, CLI output, metric values, keyboard shortcuts.

---

## 4. Spacing

4px base unit. Same scale as V2, stricter usage.

| Token        | Value  | Usage                      |
| ------------ | ------ | -------------------------- |
| `--space-1`  | `4px`  | Inline gaps, icon padding  |
| `--space-2`  | `8px`  | Tight gaps, badge padding  |
| `--space-3`  | `12px` | Compact internal padding   |
| `--space-4`  | `16px` | Standard component spacing |
| `--space-5`  | `20px` | —                          |
| `--space-6`  | `24px` | Section labels, list gaps  |
| `--space-8`  | `32px` | Card padding               |
| `--space-10` | `40px` | —                          |
| `--space-12` | `48px` | Large section padding      |
| `--space-16` | `64px` | Section gaps               |
| `--space-20` | `80px` | Page vertical rhythm       |
| `--space-24` | `96px` | Hero sections              |

**Rule:** When in doubt, more space. Apple pages breathe.

---

## 5. Shadows & Effects

### Shadows — Dark Mode

Layered, subtle:

```css
--shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
--shadow-md: 0 4px 8px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
--shadow-lg: 0 12px 24px rgba(0, 0, 0, 0.4), 0 0 1px rgba(0, 0, 0, 0.1);
--shadow-xl: 0 24px 48px rgba(0, 0, 0, 0.5), 0 0 1px rgba(0, 0, 0, 0.1);
```

### Shadows — Light Mode

```css
--shadow-sm: 0 1px 3px rgba(0, 0, 0, 0.08), 0 0 1px rgba(0, 0, 0, 0.04);
--shadow-md: 0 4px 12px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);
--shadow-lg: 0 12px 28px rgba(0, 0, 0, 0.1), 0 4px 8px rgba(0, 0, 0, 0.04);
--shadow-xl: 0 24px 48px rgba(0, 0, 0, 0.12), 0 8px 16px rgba(0, 0, 0, 0.06);
```

No accent-colored shadows.

### Frosted Glass

```css
--glass-bg: rgba(10, 13, 20, 0.7);
--glass-blur: blur(20px) saturate(180%);
--glass-border: 1px solid rgba(255, 255, 255, 0.06);
```

Used for: nav bars, modals, floating panels, tooltips. Not every card.

### Transitions

```css
--ease: cubic-bezier(0.4, 0, 0.2, 1);
--ease-out: cubic-bezier(0, 0, 0.2, 1);
--ease-spring: cubic-bezier(0.34, 1.2, 0.64, 1);
--duration-fast: 150ms;
--duration-normal: 250ms;
--duration-slow: 400ms;
```

Removed: shimmer, pulse-ring, bouncy spring (1.56). Stagger delays stay for list entries.

### Border Radius

```css
--radius-sm: 6px; /* Badges, tags */
--radius-md: 10px; /* Buttons, inputs */
--radius-lg: 14px; /* Cards */
--radius-xl: 20px; /* Panels, modals */
--radius-full: 9999px; /* Pills */
```

---

## 6. Components

### Buttons

**Primary:**

```css
background: var(--cyan);
color: #050508;
font-weight: 600;
border-radius: var(--radius-md);
padding: 10px 20px;
transition: opacity var(--duration-fast) var(--ease);
```

Hover: `opacity: 0.85`. No glow, no gradient.

**Secondary:**

```css
background: var(--cyan-subtle);
border: 1px solid var(--cyan-muted);
color: var(--cyan);
```

**Ghost:** Text-only, subtle hover background.

**Destructive:** Rose-tinted variant of secondary.

### Cards

```css
background: var(--deep);
border: 1px solid rgba(255, 255, 255, 0.06);
border-radius: var(--radius-lg);
padding: var(--space-8);
transition:
  transform var(--duration-normal) var(--ease),
  box-shadow var(--duration-normal) var(--ease);
```

Hover: `translateY(-1px)` + `--shadow-md`. No colored border reveals.

### Navigation (Sidebar)

Frosted glass background. Active item: `--cyan-subtle` background + `2px` left border in `--cyan`.

### Terminal Blocks

```css
background: var(--abyss);
border: 1px solid rgba(255, 255, 255, 0.06);
border-radius: var(--radius-lg);
font-family: var(--font-mono);
font-size: 0.82rem;
line-height: 1.8;
```

Traffic light dots: `#ff5f57` (red), `#febc2e` (yellow), `#28c840` (green).

Syntax: `--cyan` for prompts/commands, `--text-secondary` for output, `--green`/`--rose` for pass/fail.

### Status Badges

Minimal pills with tinted backgrounds:

```css
/* Running */
background: rgba(0, 212, 255, 0.1);
color: var(--cyan);

/* Success */
background: rgba(74, 222, 128, 0.1);
color: var(--green);

/* Failed */
background: rgba(244, 63, 94, 0.1);
color: var(--rose);

/* Warning */
background: rgba(251, 191, 36, 0.1);
color: var(--amber);
```

---

## 7. Logo & Brand Mark

Simplified ship silhouette — geometric, works at 16x16 favicon size. Clean stroke or fill, no gradients in the mark itself. Cyan on dark, dark on light.

SVG uses a 32x32 viewBox. No gradient fills in the logo mark — solid `--cyan` or `--text-primary` depending on context.

---

## 8. README Badge Colors

| Badge    | Color     |
| -------- | --------- |
| Tests    | `#4ade80` |
| Version  | `#00d4ff` |
| Platform | `#555a66` |

---

## 9. Migration Notes

### What Changes

| Surface               | From                                                                | To                                       |
| --------------------- | ------------------------------------------------------------------- | ---------------------------------------- |
| Dashboard backgrounds | Warm beige (light) / charcoal (dark)                                | Cool gray (light) / near-black (dark)    |
| Dashboard accent      | Orange `#FF5C00`                                                    | Cyan `#00d4ff` (dark), `#0091b3` (light) |
| Dashboard fonts       | Inter + Geist Mono (web fonts)                                      | System stack + SF Mono (zero loading)    |
| Website backgrounds   | Heavy ocean-blue tints                                              | Subtle cool undertones                   |
| Website fonts         | Instrument Serif + Plus Jakarta Sans + JetBrains Mono (3 web fonts) | System stack (zero loading)              |
| Gradients             | Shimmer animations, gradient text throughout                        | One hero gradient, no animations         |
| Glow effects          | Cyan/purple glows on hover                                          | Frosted glass + subtle shadows           |
| Button style          | Gradient CTAs                                                       | Solid cyan, no gradient                  |

### What Stays

- Cyan `#00d4ff` as primary accent
- Purple `#7c3aed` and blue `#0066ff` as gradient accents
- Status colors (green, amber, rose)
- 4px spacing base unit
- Terminal traffic light dots
- Nautical naming conventions
- Stagger animation delays for lists

### Files to Update

1. `website/design-system.md` — Replace with this spec
2. `skipper/crates/skipper-api/static/css/theme.css` — New unified tokens
3. `skipper/crates/skipper-api/static/css/layout.css` — Updated spacing/layout
4. `skipper/crates/skipper-api/static/css/components.css` — Updated component styles
5. `skipper/crates/skipper-api/static/index_head.html` — Remove Google Fonts import
6. `dashboard/public/` — Shipwright dashboard styles
7. `docs/reference/legacy-guide.md` — Update color references
8. `README.md` — Update badge colors
9. Shell scripts — Update ANSI color helpers if needed
