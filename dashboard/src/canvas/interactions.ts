// Hit testing, hover, click, zoom handlers for canvas

import type { LayoutNode, StageColumn } from "./layout";

export interface HoverState {
  node: LayoutNode | null;
  column: StageColumn | null;
}

export function hitTestNode(
  nodes: LayoutNode[],
  x: number,
  y: number,
): LayoutNode | null {
  for (const node of nodes) {
    const dx = x - node.x;
    const dy = y - node.y;
    if (dx * dx + dy * dy <= node.radius * node.radius) {
      return node;
    }
  }
  return null;
}

export function hitTestColumn(
  columns: StageColumn[],
  x: number,
  _y: number,
): StageColumn | null {
  for (const col of columns) {
    if (x >= col.x && x <= col.x + col.width) {
      return col;
    }
  }
  return null;
}

export class ZoomPan {
  public scale = 1;
  public offsetX = 0;
  public offsetY = 0;
  private minScale = 0.5;
  private maxScale = 3;

  zoom(delta: number, cx: number, cy: number): void {
    const factor = delta > 0 ? 0.95 : 1.05;
    const newScale = Math.max(
      this.minScale,
      Math.min(this.maxScale, this.scale * factor),
    );
    const ratio = newScale / this.scale;
    this.offsetX = cx - (cx - this.offsetX) * ratio;
    this.offsetY = cy - (cy - this.offsetY) * ratio;
    this.scale = newScale;
  }

  screenToWorld(sx: number, sy: number): { x: number; y: number } {
    return {
      x: (sx - this.offsetX) / this.scale,
      y: (sy - this.offsetY) / this.scale,
    };
  }

  apply(ctx: CanvasRenderingContext2D): void {
    ctx.translate(this.offsetX, this.offsetY);
    ctx.scale(this.scale, this.scale);
  }

  reset(): void {
    this.scale = 1;
    this.offsetX = 0;
    this.offsetY = 0;
  }
}
