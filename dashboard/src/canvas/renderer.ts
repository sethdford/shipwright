// Base Canvas2D renderer with requestAnimationFrame loop and dirty tracking

import { colors, fonts, typeScale } from "../design/tokens";

export interface CanvasScene {
  update(dt: number): void;
  draw(ctx: CanvasRenderingContext2D, width: number, height: number): void;
  onResize(width: number, height: number): void;
  onMouseMove(x: number, y: number): void;
  onMouseClick(x: number, y: number): void;
  onMouseWheel(delta: number): void;
}

export class CanvasRenderer {
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private scene: CanvasScene | null = null;
  private animationId: number | null = null;
  private lastTime = 0;
  private dpr = 1;
  private running = false;

  constructor(container: HTMLElement) {
    this.canvas = document.createElement("canvas");
    this.canvas.style.width = "100%";
    this.canvas.style.height = "100%";
    this.canvas.style.display = "block";
    container.appendChild(this.canvas);

    this.ctx = this.canvas.getContext("2d")!;
    this.dpr = window.devicePixelRatio || 1;

    this.handleResize();
    window.addEventListener("resize", () => this.handleResize());
    this.canvas.addEventListener("mousemove", (e) => this.handleMouseMove(e));
    this.canvas.addEventListener("click", (e) => this.handleClick(e));
    this.canvas.addEventListener("wheel", (e) => this.handleWheel(e), {
      passive: true,
    });
  }

  setScene(scene: CanvasScene): void {
    this.scene = scene;
    scene.onResize(this.canvas.width / this.dpr, this.canvas.height / this.dpr);
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.lastTime = performance.now();
    this.loop(this.lastTime);
  }

  stop(): void {
    this.running = false;
    if (this.animationId != null) {
      cancelAnimationFrame(this.animationId);
      this.animationId = null;
    }
  }

  destroy(): void {
    this.stop();
    this.canvas.remove();
  }

  getCanvas(): HTMLCanvasElement {
    return this.canvas;
  }

  private loop(time: number): void {
    if (!this.running) return;
    const dt = (time - this.lastTime) / 1000;
    this.lastTime = time;

    if (this.scene) {
      this.scene.update(dt);
      this.ctx.save();
      this.ctx.scale(this.dpr, this.dpr);
      this.ctx.clearRect(
        0,
        0,
        this.canvas.width / this.dpr,
        this.canvas.height / this.dpr,
      );
      this.scene.draw(
        this.ctx,
        this.canvas.width / this.dpr,
        this.canvas.height / this.dpr,
      );
      this.ctx.restore();
    }

    this.animationId = requestAnimationFrame((t) => this.loop(t));
  }

  private handleResize(): void {
    const rect = this.canvas.parentElement?.getBoundingClientRect();
    if (!rect) return;
    this.canvas.width = rect.width * this.dpr;
    this.canvas.height = rect.height * this.dpr;
    this.canvas.style.width = rect.width + "px";
    this.canvas.style.height = rect.height + "px";
    if (this.scene) this.scene.onResize(rect.width, rect.height);
  }

  private handleMouseMove(e: MouseEvent): void {
    const rect = this.canvas.getBoundingClientRect();
    if (this.scene)
      this.scene.onMouseMove(e.clientX - rect.left, e.clientY - rect.top);
  }

  private handleClick(e: MouseEvent): void {
    const rect = this.canvas.getBoundingClientRect();
    if (this.scene)
      this.scene.onMouseClick(e.clientX - rect.left, e.clientY - rect.top);
  }

  private handleWheel(e: WheelEvent): void {
    if (this.scene) this.scene.onMouseWheel(e.deltaY);
  }
}

// Canvas drawing helpers
export function drawText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  options: {
    font?: keyof typeof typeScale;
    color?: string;
    align?: CanvasTextAlign;
    baseline?: CanvasTextBaseline;
    maxWidth?: number;
  } = {},
): void {
  const style = typeScale[options.font || "body"];
  ctx.font = `${style.weight} ${style.size}px ${style.family}`;
  ctx.fillStyle = options.color || colors.text.primary;
  ctx.textAlign = options.align || "left";
  ctx.textBaseline = options.baseline || "top";
  if (options.maxWidth) {
    ctx.fillText(text, x, y, options.maxWidth);
  } else {
    ctx.fillText(text, x, y);
  }
}

export function drawRoundRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  radius: number,
): void {
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.lineTo(x + w - radius, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + radius);
  ctx.lineTo(x + w, y + h - radius);
  ctx.quadraticCurveTo(x + w, y + h, x + w - radius, y + h);
  ctx.lineTo(x + radius, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - radius);
  ctx.lineTo(x, y + radius);
  ctx.quadraticCurveTo(x, y, x + radius, y);
  ctx.closePath();
}

export function drawCircle(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  r: number,
  fill?: string,
  stroke?: string,
  lineWidth?: number,
): void {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  if (fill) {
    ctx.fillStyle = fill;
    ctx.fill();
  }
  if (stroke) {
    ctx.strokeStyle = stroke;
    ctx.lineWidth = lineWidth || 1;
    ctx.stroke();
  }
}
