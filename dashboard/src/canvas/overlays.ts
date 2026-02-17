// Floating labels, tooltips, prediction overlays

import {
  colors,
  fonts,
  typeScale,
  radius as borderRadius,
} from "../design/tokens";
import { drawRoundRect, drawText } from "./renderer";
import { formatDuration } from "../core/helpers";
import type { LayoutNode } from "./layout";

export function drawTooltip(
  ctx: CanvasRenderingContext2D,
  node: LayoutNode,
  predictions?: {
    eta_s?: number;
    success_probability?: number;
    estimated_cost?: number;
  },
): void {
  const padding = 12;
  const lineHeight = 20;
  const lines: string[] = [
    `#${node.issue} ${node.title.substring(0, 40)}`,
    `Stage: ${node.stage}`,
    `Status: ${node.status}`,
  ];

  if (predictions) {
    if (predictions.eta_s != null)
      lines.push(`ETA: ${formatDuration(predictions.eta_s)}`);
    if (predictions.success_probability != null)
      lines.push(
        `Success: ${(predictions.success_probability * 100).toFixed(0)}%`,
      );
    if (predictions.estimated_cost != null)
      lines.push(`Est. cost: $${predictions.estimated_cost.toFixed(2)}`);
  }

  const style = typeScale.caption;
  ctx.font = `${style.weight} ${style.size}px ${style.family}`;

  let maxWidth = 0;
  for (const line of lines) {
    const w = ctx.measureText(line).width;
    if (w > maxWidth) maxWidth = w;
  }

  const boxWidth = maxWidth + padding * 2;
  const boxHeight = lines.length * lineHeight + padding * 2;
  const x = node.x + node.radius + 10;
  const y = node.y - boxHeight / 2;

  // Background
  ctx.fillStyle = colors.bg.ocean;
  drawRoundRect(ctx, x, y, boxWidth, boxHeight, borderRadius.md);
  ctx.fill();

  // Border
  ctx.strokeStyle = colors.accent.cyanDim;
  ctx.lineWidth = 1;
  drawRoundRect(ctx, x, y, boxWidth, boxHeight, borderRadius.md);
  ctx.stroke();

  // Text
  for (let i = 0; i < lines.length; i++) {
    drawText(ctx, lines[i], x + padding, y + padding + i * lineHeight, {
      font: "caption",
      color: i === 0 ? colors.text.primary : colors.text.secondary,
    });
  }
}

export function drawPredictionGhost(
  ctx: CanvasRenderingContext2D,
  fromX: number,
  fromY: number,
  toX: number,
  toY: number,
  progress: number,
  color: string,
): void {
  const x = fromX + (toX - fromX) * progress;
  const y = fromY + (toY - fromY) * progress;

  ctx.globalAlpha = 0.3;
  ctx.beginPath();
  ctx.arc(x, y, 8, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();

  // Dashed line to destination
  ctx.setLineDash([4, 4]);
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x, y);
  ctx.lineTo(toX, toY);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.globalAlpha = 1;
}

export function drawStageLabel(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  color: string,
): void {
  drawText(ctx, text.toUpperCase(), x, y, {
    font: "monoSm",
    color,
    align: "center",
  });
}
