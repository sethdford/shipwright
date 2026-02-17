// Timeline tab - Canvas2D interactive timeline with scrub, playback, prediction overlays

import { escapeHtml, formatDuration, padZero } from "../core/helpers";
import { icon } from "../design/icons";
import { colors, STAGES, STAGE_HEX } from "../design/tokens";
import {
  CanvasRenderer,
  drawText,
  drawRoundRect,
  type CanvasScene,
} from "../canvas/renderer";
import * as api from "../core/api";
import type {
  FleetState,
  View,
  TimelineEntry,
  TimelineSegment,
} from "../types/api";

let timelineRange = "24h";
let timelineCache: TimelineEntry[] | null = null;
let renderer: CanvasRenderer | null = null;
let scene: TimelineScene | null = null;

class TimelineScene implements CanvasScene {
  entries: TimelineEntry[] = [];
  earliest = 0;
  latest = 0;
  totalSpan = 1;
  width = 0;
  height = 0;
  scrollY = 0;
  hoverRow = -1;
  hoverX = -1;
  playbackTime = -1;
  isPlaying = false;
  playbackSpeed = 1;
  rowHeight = 44;
  headerHeight = 40;
  labelWidth = 160;

  setData(entries: TimelineEntry[]): void {
    this.entries = entries;
    this.earliest = Infinity;
    this.latest = -Infinity;

    for (const entry of entries) {
      for (const seg of entry.segments) {
        const s = new Date(seg.start).getTime();
        if (s < this.earliest) this.earliest = s;
        const e = seg.end ? new Date(seg.end).getTime() : Date.now();
        if (e > this.latest) this.latest = e;
      }
    }
    if (!isFinite(this.earliest)) this.earliest = Date.now() - 3600000;
    if (!isFinite(this.latest)) this.latest = Date.now();
    this.totalSpan = this.latest - this.earliest || 1;
    this.playbackTime = -1;
  }

  update(dt: number): void {
    if (this.isPlaying && this.entries.length > 0) {
      if (this.playbackTime < 0) this.playbackTime = this.earliest;
      this.playbackTime += dt * this.playbackSpeed * this.totalSpan * 0.1;
      if (this.playbackTime > this.latest) {
        this.playbackTime = this.earliest;
      }
    }
  }

  draw(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    const {
      entries,
      earliest,
      totalSpan,
      rowHeight,
      headerHeight,
      labelWidth,
      scrollY,
    } = this;

    // Background
    ctx.fillStyle = colors.bg.abyss;
    ctx.fillRect(0, 0, width, height);

    const trackWidth = width - labelWidth;
    const trackX = labelWidth;

    // Time axis header
    ctx.fillStyle = colors.bg.deep;
    ctx.fillRect(0, 0, width, headerHeight);

    // Time ticks
    const tickCount = Math.max(4, Math.floor(trackWidth / 100));
    for (let i = 0; i <= tickCount; i++) {
      const t = earliest + (i / tickCount) * totalSpan;
      const d = new Date(t);
      const label = padZero(d.getHours()) + ":" + padZero(d.getMinutes());
      const x = trackX + (i / tickCount) * trackWidth;

      // Tick line
      ctx.strokeStyle = colors.bg.foam + "40";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(x, headerHeight);
      ctx.lineTo(x, height);
      ctx.stroke();

      drawText(ctx, label, x, 12, {
        font: "monoSm",
        color: colors.text.muted,
        align: "center",
      });
    }

    // Playback cursor
    if (this.playbackTime >= 0) {
      const cursorX =
        trackX + ((this.playbackTime - earliest) / totalSpan) * trackWidth;
      ctx.strokeStyle = colors.accent.cyan;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(cursorX, headerHeight);
      ctx.lineTo(cursorX, height);
      ctx.stroke();

      // Cursor time label
      const cursorDate = new Date(this.playbackTime);
      const cursorLabel =
        padZero(cursorDate.getHours()) +
        ":" +
        padZero(cursorDate.getMinutes()) +
        ":" +
        padZero(cursorDate.getSeconds());
      ctx.fillStyle = colors.accent.cyan;
      drawRoundRect(ctx, cursorX - 30, 2, 60, 16, 4);
      ctx.fill();
      drawText(ctx, cursorLabel, cursorX, 4, {
        font: "monoSm",
        color: colors.bg.abyss,
        align: "center",
      });
    }

    // Entries
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, headerHeight, width, height - headerHeight);
    ctx.clip();

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      const y = headerHeight + i * rowHeight - scrollY;
      if (y + rowHeight < headerHeight || y > height) continue;

      const isHovered = i === this.hoverRow;

      // Row background
      if (isHovered) {
        ctx.fillStyle = colors.bg.surface + "60";
        ctx.fillRect(0, y, width, rowHeight);
      }

      // Row separator
      ctx.strokeStyle = colors.bg.foam + "20";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, y + rowHeight);
      ctx.lineTo(width, y + rowHeight);
      ctx.stroke();

      // Label
      const issueLabel = `#${entry.issue}`;
      const titleLabel = entry.title ? " " + entry.title.substring(0, 20) : "";
      drawText(ctx, issueLabel + titleLabel, 12, y + 14, {
        font: "caption",
        color: isHovered ? colors.text.primary : colors.text.secondary,
        maxWidth: labelWidth - 20,
      });

      // Status badge — derive from last segment
      const lastSeg = entry.segments[entry.segments.length - 1];
      const statusColor =
        lastSeg?.status === "failed"
          ? colors.semantic.error
          : lastSeg?.status === "complete"
            ? colors.semantic.success
            : colors.accent.cyan;
      ctx.fillStyle = statusColor;
      ctx.beginPath();
      ctx.arc(labelWidth - 16, y + rowHeight / 2, 4, 0, Math.PI * 2);
      ctx.fill();

      // Stage bars
      for (const stage of entry.segments) {
        const stageStart = new Date(stage.start).getTime();
        const stageEnd = stage.end ? new Date(stage.end).getTime() : Date.now();
        const left =
          trackX + ((stageStart - earliest) / totalSpan) * trackWidth;
        const barWidth = Math.max(
          3,
          ((stageEnd - stageStart) / totalSpan) * trackWidth,
        );
        const color =
          (STAGE_HEX as Record<string, string>)[stage.stage] ||
          colors.text.muted;

        const barY = y + 8;
        const barH = rowHeight - 16;

        ctx.fillStyle = color;
        ctx.globalAlpha = stage.status === "failed" ? 0.5 : 0.85;
        drawRoundRect(ctx, left, barY, barWidth, barH, 3);
        ctx.fill();
        ctx.globalAlpha = 1;

        // Stage name if bar is wide enough
        if (barWidth > 40) {
          drawText(ctx, stage.stage, left + 4, barY + 4, {
            font: "tiny",
            color: colors.bg.abyss,
            maxWidth: barWidth - 8,
          });
        }
      }
    }

    ctx.restore();

    // Hover tooltip
    if (
      this.hoverRow >= 0 &&
      this.hoverRow < entries.length &&
      this.hoverX >= trackX
    ) {
      const entry = entries[this.hoverRow];
      const hoverTime =
        earliest + ((this.hoverX - trackX) / trackWidth) * totalSpan;
      const hoverStage = entry.segments.find((s: TimelineSegment) => {
        const ss = new Date(s.start).getTime();
        const se = s.end ? new Date(s.end).getTime() : Date.now();
        return hoverTime >= ss && hoverTime <= se;
      });

      if (hoverStage) {
        const tooltipY =
          headerHeight + this.hoverRow * rowHeight - scrollY - 30;
        const dur =
          (hoverStage.end ? new Date(hoverStage.end).getTime() : Date.now()) -
          new Date(hoverStage.start).getTime();
        const tooltipText = `${hoverStage.stage}: ${formatDuration(dur / 1000)}`;

        ctx.fillStyle = colors.bg.ocean;
        const tw = ctx.measureText(tooltipText).width + 16;
        drawRoundRect(ctx, this.hoverX - tw / 2, tooltipY, tw, 22, 4);
        ctx.fill();
        ctx.strokeStyle = colors.accent.cyanDim;
        ctx.lineWidth = 1;
        drawRoundRect(ctx, this.hoverX - tw / 2, tooltipY, tw, 22, 4);
        ctx.stroke();

        drawText(ctx, tooltipText, this.hoverX, tooltipY + 5, {
          font: "monoSm",
          color: colors.text.primary,
          align: "center",
        });
      }
    }

    // Playback controls indicator
    const controlsY = height - 30;
    const playIcon = this.isPlaying ? "||" : "\u25B6";
    drawText(ctx, playIcon + " " + this.playbackSpeed + "x", 12, controlsY, {
      font: "caption",
      color: colors.text.muted,
    });
    drawText(
      ctx,
      `${entries.length} pipeline${entries.length !== 1 ? "s" : ""}`,
      width - 12,
      controlsY,
      {
        font: "caption",
        color: colors.text.muted,
        align: "right",
      },
    );
  }

  onResize(width: number, height: number): void {
    this.width = width;
    this.height = height;
  }

  onMouseMove(x: number, y: number): void {
    const row = Math.floor(
      (y - this.headerHeight + this.scrollY) / this.rowHeight,
    );
    this.hoverRow = row >= 0 && row < this.entries.length ? row : -1;
    this.hoverX = x;
    if (renderer) {
      renderer.getCanvas().style.cursor =
        this.hoverRow >= 0 ? "crosshair" : "default";
    }
  }

  onMouseClick(x: number, y: number): void {
    if (y < this.headerHeight) {
      // Click on time axis: set playback cursor
      const trackX = this.labelWidth;
      const trackWidth = this.width - this.labelWidth;
      const pct = (x - trackX) / trackWidth;
      if (pct >= 0 && pct <= 1) {
        this.playbackTime = this.earliest + pct * this.totalSpan;
      }
    } else if (x < 60 && y > this.height - 40) {
      // Click on play button
      this.isPlaying = !this.isPlaying;
    }
  }

  onMouseWheel(delta: number): void {
    const maxScroll = Math.max(
      0,
      this.entries.length * this.rowHeight - (this.height - this.headerHeight),
    );
    this.scrollY = Math.max(0, Math.min(maxScroll, this.scrollY + delta * 0.5));
  }
}

function setupTimelineControls(): void {
  const select = document.getElementById(
    "timeline-range",
  ) as HTMLSelectElement | null;
  if (select) {
    select.addEventListener("change", () => {
      timelineRange = select.value || "24";
      fetchTimeline();
    });
  }
}

function fetchTimeline(): void {
  api
    .fetchTimeline(timelineRange)
    .then((data) => {
      timelineCache = Array.isArray(data) ? data : [];
      if (scene) scene.setData(timelineCache);
    })
    .catch((err) => {
      const container = document.getElementById("gantt-chart");
      if (container)
        container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

export const timelineView: View = {
  init() {
    setupTimelineControls();

    // Replace the HTML gantt container with a canvas
    const ganttChart = document.getElementById("gantt-chart");
    if (ganttChart) {
      ganttChart.innerHTML = "";
      ganttChart.style.height = "calc(100vh - 220px)";
      ganttChart.style.minHeight = "400px";
      ganttChart.style.position = "relative";

      renderer = new CanvasRenderer(ganttChart);
      scene = new TimelineScene();
      renderer.setScene(scene);
      renderer.start();
    }

    fetchTimeline();
  },

  render(_data: FleetState) {
    if (!timelineCache) fetchTimeline();
  },

  destroy() {
    if (renderer) {
      renderer.destroy();
      renderer = null;
    }
    scene = null;
  },
};
