# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Container Image                                           ║
# ║  Orchestrate autonomous Claude Code agent teams in tmux                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   docker build -t shipwright .
#   docker run -it --env ANTHROPIC_API_KEY shipwright doctor
#   docker compose up -d
#
# Multi-stage build: deps → runtime (keeps image small)

# ─── Stage 1: Build dashboard assets ─────────────────────────────────────────
FROM oven/bun:1 AS dashboard-builder

WORKDIR /build
COPY package.json ./
COPY dashboard/ dashboard/
RUN bun install --frozen-lockfile 2>/dev/null || bun install
RUN bun build dashboard/src/main.ts --target=browser --outdir=dashboard/public/dist --minify

# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Shipwright"
LABEL org.opencontainers.image.description="Orchestrate autonomous Claude Code agent teams in tmux"
LABEL org.opencontainers.image.source="https://github.com/sethdford/shipwright"
LABEL org.opencontainers.image.licenses="MIT"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    jq \
    sqlite3 \
    tmux \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 (for Claude CLI and npm postinstall)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Bun (for dashboard server)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Set up Shipwright
WORKDIR /opt/shipwright

# Copy project files
COPY scripts/ scripts/
COPY templates/ templates/
COPY tmux/ tmux/
COPY config/ config/
# TypeScript CLI (tests and src/testing excluded via .dockerignore)
COPY src/ src/
COPY completions/ completions/
COPY .claude/agents/ .claude/agents/
COPY .claude/hooks/ .claude/hooks/
COPY package.json LICENSE README.md ./

# Copy built dashboard assets
COPY dashboard/server.ts dashboard/server.ts
COPY dashboard/public/ dashboard/public/
COPY --from=dashboard-builder /build/dashboard/public/dist/ dashboard/public/dist/

# Make all scripts executable
RUN chmod +x scripts/* scripts/lib/* 2>/dev/null || true

# Create symlinks for CLI
RUN ln -sf /opt/shipwright/scripts/sw /usr/local/bin/shipwright \
    && ln -sf /opt/shipwright/scripts/sw /usr/local/bin/sw

# Create shipwright home directory
RUN mkdir -p /root/.shipwright

# Copy pipeline and team templates
RUN mkdir -p /root/.shipwright/templates /root/.shipwright/pipelines \
    && cp tmux/templates/*.json /root/.shipwright/templates/ 2>/dev/null || true \
    && cp templates/pipelines/*.json /root/.shipwright/pipelines/ 2>/dev/null || true

# Install shell completions
RUN mkdir -p /usr/share/bash-completion/completions \
    && cp completions/shipwright.bash /usr/share/bash-completion/completions/shipwright \
    && cp completions/shipwright.bash /usr/share/bash-completion/completions/sw

# Dashboard port
EXPOSE 8767

# Health check via doctor
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD shipwright doctor --json 2>/dev/null | jq -e '.status != "error"' || exit 1

# Default: interactive shell with tmux
ENTRYPOINT ["shipwright"]
CMD ["help"]
