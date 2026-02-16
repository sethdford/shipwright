// SVG Bar Chart

import { escapeHtml } from "../../core/helpers";
import type { DailyCount } from "../../types/api";

export function renderSVGBarChart(dailyCounts: DailyCount[]): string {
  if (!dailyCounts || dailyCounts.length === 0) return "";

  const chartW = 700;
  const chartH = 100;
  const barGap = 4;
  const barW = Math.max(
    8,
    (chartW - (dailyCounts.length - 1) * barGap) / dailyCounts.length,
  );

  let maxCount = 0;
  for (const day of dailyCounts) {
    const total = (day.completed || 0) + (day.failed || 0);
    if (total > maxCount) maxCount = total;
  }
  if (maxCount === 0) maxCount = 1;

  let svg = `<svg class="svg-bar-chart" viewBox="0 0 ${chartW} ${chartH + 20}" width="100%" height="${chartH + 20}">`;

  for (let i = 0; i < dailyCounts.length; i++) {
    const day = dailyCounts[i];
    const completed = day.completed || 0;
    const failed = day.failed || 0;
    const x = i * (barW + barGap);
    const cH = (completed / maxCount) * chartH;
    const fH = (failed / maxCount) * chartH;

    if (cH > 0) {
      svg += `<rect x="${x}" y="${chartH - cH - fH}" width="${barW}" height="${cH}" rx="3" fill="#4ade80" opacity="0.85"/>`;
    }
    if (fH > 0) {
      svg += `<rect x="${x}" y="${chartH - fH}" width="${barW}" height="${fH}" rx="3" fill="#f43f5e" opacity="0.85"/>`;
    }
    if (cH === 0 && fH === 0) {
      svg += `<rect x="${x}" y="${chartH - 1}" width="${barW}" height="1" fill="#0d1f3c"/>`;
    }

    const dateStr = day.date || "";
    const parts = dateStr.split("-");
    const label = parts.length >= 3 ? parts[1] + "/" + parts[2] : dateStr;
    svg +=
      `<text x="${x + barW / 2}" y="${chartH + 14}" text-anchor="middle" fill="#5a6d8a" ` +
      `font-family="'JetBrains Mono', monospace" font-size="8">${escapeHtml(label)}</text>`;
  }

  svg += "</svg>";
  return svg;
}
