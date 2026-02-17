// Stage-column layout algorithm for fleet topology map

import { STAGES, STAGE_HEX, type StageName } from "../design/tokens";
import { colors } from "../design/tokens";
import type { PipelineInfo } from "../types/api";

export interface LayoutNode {
  issue: number;
  title: string;
  stage: string;
  stageIndex: number;
  x: number;
  y: number;
  targetX: number;
  targetY: number;
  radius: number;
  color: string;
  status: string;
  progress: number; // 0-1 within current stage
  velocity: number;
}

export interface StageColumn {
  name: string;
  x: number;
  width: number;
  color: string;
}

export function computeLayout(
  pipelines: PipelineInfo[],
  width: number,
  height: number,
): { nodes: LayoutNode[]; columns: StageColumn[] } {
  const padding = 60;
  const colWidth = (width - padding * 2) / STAGES.length;
  const columns: StageColumn[] = STAGES.map((stage, i) => ({
    name: stage === "compound_quality" ? "quality" : stage,
    x: padding + i * colWidth,
    width: colWidth,
    color: STAGE_HEX[stage],
  }));

  const stageNodes: Record<string, PipelineInfo[]> = {};
  for (const p of pipelines) {
    const stage = p.stage || "intake";
    if (!stageNodes[stage]) stageNodes[stage] = [];
    stageNodes[stage].push(p);
  }

  const nodes: LayoutNode[] = [];
  for (const p of pipelines) {
    const stage = p.stage || "intake";
    const stageIdx = STAGES.indexOf(stage as StageName);
    const col = columns[stageIdx >= 0 ? stageIdx : 0];
    const pipelinesInStage = stageNodes[stage] || [];
    const indexInStage = pipelinesInStage.indexOf(p);
    const spacing = Math.min(
      60,
      (height - padding * 2) / (pipelinesInStage.length + 1),
    );
    const yOffset = padding + (indexInStage + 1) * spacing;

    const nodeColor = p.status === "failed" ? colors.semantic.error : col.color;
    const progress = (p.stagesDone?.length || 0) / STAGES.length;

    nodes.push({
      issue: p.issue,
      title: p.title || "",
      stage,
      stageIndex: stageIdx >= 0 ? stageIdx : 0,
      x: col.x + col.width / 2,
      y: yOffset,
      targetX: col.x + col.width / 2,
      targetY: yOffset,
      radius: 18,
      color: nodeColor,
      status: p.status || "active",
      progress,
      velocity: 0.5 + Math.random() * 0.5,
    });
  }

  return { nodes, columns };
}
