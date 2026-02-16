// SVG Pipeline Stage Visualization

import { STAGES, STAGE_SHORT, STAGE_HEX } from "../../design/tokens";
import { escapeHtml } from "../../core/helpers";
import type { PipelineInfo } from "../../types/api";

export function renderPipelineSVG(pipeline: PipelineInfo): string {
  const stagesDone = pipeline.stagesDone || [];
  const currentStage = pipeline.stage || "";
  const failed = pipeline.status === "failed";

  const nodeSpacing = 80;
  const nodeR = 14;
  const svgWidth = STAGES.length * nodeSpacing + 40;
  const svgHeight = 72;
  const yCenter = 28;
  const yLabel = 60;

  let svg = `<svg class="pipeline-svg" viewBox="0 0 ${svgWidth} ${svgHeight}" width="100%" height="${svgHeight}" xmlns="http://www.w3.org/2000/svg">`;

  // Connecting lines
  for (let i = 0; i < STAGES.length - 1; i++) {
    const x1 = 20 + i * nodeSpacing + nodeR;
    const x2 = 20 + (i + 1) * nodeSpacing - nodeR;
    const isDone = stagesDone.indexOf(STAGES[i]) !== -1;
    const lineColor = isDone ? "#4ade80" : "#1a3a6a";
    const dashAttr = isDone ? "" : ' stroke-dasharray="4,3"';
    svg += `<line x1="${x1}" y1="${yCenter}" x2="${x2}" y2="${yCenter}" stroke="${lineColor}" stroke-width="2"${dashAttr}/>`;
  }

  // Stage nodes
  for (let i = 0; i < STAGES.length; i++) {
    const s = STAGES[i];
    const cx = 20 + i * nodeSpacing;
    const isDone = stagesDone.indexOf(s) !== -1;
    const isActive = s === currentStage;
    const isFailed = failed && isActive;

    let fillColor = "#0d1f3c";
    let strokeColor = "#1a3a6a";
    let textColor = "#5a6d8a";
    let extra = "";

    if (isDone) {
      fillColor = "#4ade80";
      strokeColor = "#4ade80";
      textColor = "#060a14";
    } else if (isFailed) {
      fillColor = "#f43f5e";
      strokeColor = "#f43f5e";
      textColor = "#fff";
    } else if (isActive) {
      fillColor = "#00d4ff";
      strokeColor = "#00d4ff";
      textColor = "#060a14";
      extra = ' class="stage-node-active"';
    }

    if (isActive && !isFailed) {
      svg +=
        `<circle cx="${cx}" cy="${yCenter}" r="${nodeR + 4}" fill="none" stroke="${strokeColor}" stroke-width="1" opacity="0.3"${extra}>` +
        `<animate attributeName="r" values="${nodeR + 2};${nodeR + 6};${nodeR + 2}" dur="2s" repeatCount="indefinite"/>` +
        `<animate attributeName="opacity" values="0.3;0.1;0.3" dur="2s" repeatCount="indefinite"/></circle>`;
    }

    svg += `<circle cx="${cx}" cy="${yCenter}" r="${nodeR}" fill="${fillColor}" stroke="${strokeColor}" stroke-width="2"/>`;
    svg += `<text x="${cx}" y="${yCenter + 4}" text-anchor="middle" fill="${textColor}" font-family="'JetBrains Mono', monospace" font-size="8" font-weight="600">${STAGE_SHORT[s]}</text>`;
    svg += `<text x="${cx}" y="${yLabel}" text-anchor="middle" fill="#5a6d8a" font-family="'JetBrains Mono', monospace" font-size="7">${escapeHtml(s === "compound_quality" ? "quality" : s)}</text>`;
  }

  svg += "</svg>";
  return svg;
}

export function renderDoraGrades(
  dora:
    | Record<string, { grade: string; value: number; unit: string }>
    | null
    | undefined,
): string {
  if (!dora) return "";

  const metrics = [
    { key: "deploy_freq", label: "Deploy Frequency" },
    { key: "lead_time", label: "Lead Time" },
    { key: "cfr", label: "Change Failure Rate" },
    { key: "mttr", label: "Mean Time to Recovery" },
  ];

  let html = '<div class="dora-grades-row">';
  for (const m of metrics) {
    const d = (dora as Record<string, any>)[m.key];
    if (!d) continue;
    const grade = (d.grade || "N/A").toLowerCase();
    const gradeClass = "dora-" + grade;
    html +=
      `<div class="dora-grade-card">` +
      `<span class="dora-grade-label">${escapeHtml(m.label)}</span>` +
      `<span class="dora-badge ${gradeClass}">${escapeHtml(d.grade || "N/A")}</span>` +
      `<span class="dora-grade-value">${d.value != null ? d.value.toFixed(1) : "\u2014"} ${escapeHtml(d.unit || "")}</span>` +
      `</div>`;
  }
  html += "</div>";
  return html;
}
