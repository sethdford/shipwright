// Fleet Map - Canvas2D topology with stage columns, animated pipeline particles

import { store } from "../core/state";
import { colors, STAGES, STAGE_HEX, STAGE_SHORT } from "../design/tokens";
import { formatDuration } from "../core/helpers";
import {
  CanvasRenderer,
  drawText,
  drawCircle,
  drawRoundRect,
  type CanvasScene,
} from "../canvas/renderer";
import {
  computeLayout,
  type LayoutNode,
  type StageColumn,
} from "../canvas/layout";
import { ParticleSystem } from "../canvas/particles";
import { hitTestNode, ZoomPan } from "../canvas/interactions";
import { drawTooltip, drawStageLabel } from "../canvas/overlays";
import * as api from "../core/api";
import type { FleetState, View } from "../types/api";

let renderer: CanvasRenderer | null = null;
let scene: FleetMapScene | null = null;

class FleetMapScene implements CanvasScene {
  nodes: LayoutNode[] = [];
  columns: StageColumn[] = [];
  particles = new ParticleSystem();
  zoomPan = new ZoomPan();
  hoveredNode: LayoutNode | null = null;
  predictions: Record<
    number,
    { eta_s?: number; success_probability?: number; estimated_cost?: number }
  > = {};
  time = 0;
  width = 0;
  height = 0;

  updateData(data: FleetState): void {
    if (!data.pipelines) return;
    const { nodes, columns } = computeLayout(
      data.pipelines,
      this.width,
      this.height,
    );

    // Smooth transition: find matching nodes and lerp
    for (const newNode of nodes) {
      const existing = this.nodes.find((n) => n.issue === newNode.issue);
      if (existing) {
        newNode.x = existing.x;
        newNode.y = existing.y;
      }
    }

    this.nodes = nodes;
    this.columns = columns;

    // Fetch predictions for active pipelines
    for (const p of data.pipelines) {
      if (!this.predictions[p.issue]) {
        api.fetchPredictions(p.issue).then((pred) => {
          this.predictions[p.issue] = pred;
        });
      }
    }
  }

  update(dt: number): void {
    this.time += dt;

    // Smooth node movement
    for (const node of this.nodes) {
      const dx = node.targetX - node.x;
      const dy = node.targetY - node.y;
      node.x += dx * 5 * dt;
      node.y += dy * 5 * dt;
    }

    // Emit trail particles for active nodes
    for (const node of this.nodes) {
      if (node.status === "active" || node.status === "running") {
        if (Math.random() < 0.3) {
          this.particles.emit(
            node.x + (Math.random() - 0.5) * node.radius,
            node.y + (Math.random() - 0.5) * node.radius,
            "trail",
            node.color,
            1,
          );
        }
      }
    }

    // Ambient particles along columns
    if (Math.random() < 0.05) {
      const col = this.columns[Math.floor(Math.random() * this.columns.length)];
      if (col) {
        this.particles.emit(
          col.x + Math.random() * col.width,
          Math.random() * this.height,
          "ambient",
          col.color,
          1,
        );
      }
    }

    this.particles.update(dt);
  }

  draw(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    // Background
    ctx.fillStyle = colors.bg.abyss;
    ctx.fillRect(0, 0, width, height);

    ctx.save();
    this.zoomPan.apply(ctx);

    // Stage columns
    for (const col of this.columns) {
      // Column separator
      ctx.fillStyle = colors.bg.deep;
      ctx.fillRect(col.x, 0, col.width, height);

      // Column border
      ctx.strokeStyle = colors.bg.foam + "40";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(col.x, 0);
      ctx.lineTo(col.x, height);
      ctx.stroke();

      // Stage label at top
      drawStageLabel(ctx, col.name, col.x + col.width / 2, 20, col.color);
    }

    // Connection lines between pipeline stages
    for (const node of this.nodes) {
      if (node.stageIndex > 0) {
        const prevCol = this.columns[node.stageIndex - 1];
        if (prevCol) {
          const fromX = prevCol.x + prevCol.width / 2;
          ctx.globalAlpha = 0.15;
          ctx.strokeStyle = node.color;
          ctx.lineWidth = 1;
          ctx.setLineDash([4, 4]);
          ctx.beginPath();
          ctx.moveTo(fromX, node.y);
          ctx.lineTo(node.x, node.y);
          ctx.stroke();
          ctx.setLineDash([]);
          ctx.globalAlpha = 1;
        }
      }
    }

    // Particles (behind nodes)
    this.particles.draw(ctx);

    // Pipeline nodes
    for (const node of this.nodes) {
      const isHovered = this.hoveredNode === node;
      const r = isHovered ? node.radius * 1.2 : node.radius;

      // Glow
      if (node.status !== "failed") {
        ctx.globalAlpha = 0.2 + 0.1 * Math.sin(this.time * 2 + node.issue);
        drawCircle(ctx, node.x, node.y, r + 6, undefined, node.color, 2);
        ctx.globalAlpha = 1;
      }

      // Node circle
      drawCircle(ctx, node.x, node.y, r, node.color);

      // Issue number
      drawText(ctx, "#" + node.issue, node.x, node.y - 4, {
        font: "monoSm",
        color: colors.bg.abyss,
        align: "center",
        baseline: "middle",
      });

      // Progress arc
      if (node.progress > 0 && node.progress < 1) {
        ctx.beginPath();
        ctx.arc(
          node.x,
          node.y,
          r + 3,
          -Math.PI / 2,
          -Math.PI / 2 + node.progress * Math.PI * 2,
        );
        ctx.strokeStyle = colors.accent.cyan;
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    }

    ctx.restore();

    // Tooltip (drawn in screen space)
    if (this.hoveredNode) {
      drawTooltip(
        ctx,
        this.hoveredNode,
        this.predictions[this.hoveredNode.issue],
      );
    }

    // HUD: pipeline count
    drawText(
      ctx,
      `${this.nodes.length} active pipeline${this.nodes.length !== 1 ? "s" : ""}`,
      16,
      height - 30,
      {
        font: "caption",
        color: colors.text.muted,
      },
    );
    drawText(ctx, `${this.particles.count} particles`, 16, height - 16, {
      font: "tiny",
      color: colors.text.muted,
    });
  }

  onResize(width: number, height: number): void {
    this.width = width;
    this.height = height;
    // Recompute layout
    const data = store.get("fleetState");
    if (data?.pipelines) {
      const { nodes, columns } = computeLayout(data.pipelines, width, height);
      this.nodes = nodes;
      this.columns = columns;
    }
  }

  onMouseMove(x: number, y: number): void {
    const world = this.zoomPan.screenToWorld(x, y);
    this.hoveredNode = hitTestNode(this.nodes, world.x, world.y);
    if (renderer) {
      renderer.getCanvas().style.cursor = this.hoveredNode
        ? "pointer"
        : "default";
    }
  }

  onMouseClick(x: number, y: number): void {
    const world = this.zoomPan.screenToWorld(x, y);
    const node = hitTestNode(this.nodes, world.x, world.y);
    if (node) {
      this.particles.burstAt(node.x, node.y, node.color);
      import("../core/router").then(({ switchTab }) => {
        switchTab("pipelines");
        import("./pipelines").then(({ fetchPipelineDetail }) => {
          fetchPipelineDetail(node.issue);
        });
      });
    }
  }

  onMouseWheel(delta: number): void {
    this.zoomPan.zoom(delta, this.width / 2, this.height / 2);
  }
}

export const fleetMapView: View = {
  init() {
    const container = document.getElementById("panel-fleet-map");
    if (!container) return;

    container.innerHTML =
      '<div class="fleet-map-canvas" style="width:100%;height:calc(100vh - 160px);position:relative;"></div>';
    const canvasContainer = container.querySelector(
      ".fleet-map-canvas",
    ) as HTMLElement;

    renderer = new CanvasRenderer(canvasContainer);
    scene = new FleetMapScene();
    renderer.setScene(scene);
    renderer.start();
  },

  render(data: FleetState) {
    if (scene) scene.updateData(data);
  },

  destroy() {
    if (renderer) {
      renderer.destroy();
      renderer = null;
    }
    scene = null;
  },
};
