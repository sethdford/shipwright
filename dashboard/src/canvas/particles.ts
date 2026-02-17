// Pipeline particle system - movement, trail effects, completion bursts

import { colors } from "../design/tokens";

export interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
  size: number;
  color: string;
  type: "trail" | "burst" | "ambient";
  alpha: number;
}

export class ParticleSystem {
  private particles: Particle[] = [];
  private maxParticles = 500;

  emit(
    x: number,
    y: number,
    type: "trail" | "burst" | "ambient",
    color: string,
    count = 1,
  ): void {
    for (let i = 0; i < count; i++) {
      if (this.particles.length >= this.maxParticles) break;

      const angle = Math.random() * Math.PI * 2;
      const speed =
        type === "burst"
          ? 30 + Math.random() * 60
          : type === "trail"
            ? 5 + Math.random() * 10
            : 2 + Math.random() * 5;

      this.particles.push({
        x,
        y,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed,
        life:
          type === "burst"
            ? 0.5 + Math.random() * 0.5
            : type === "trail"
              ? 0.3 + Math.random() * 0.3
              : 2 + Math.random() * 3,
        maxLife: type === "burst" ? 1 : type === "trail" ? 0.6 : 5,
        size:
          type === "burst"
            ? 2 + Math.random() * 3
            : type === "trail"
              ? 1 + Math.random() * 2
              : 1,
        color,
        type,
        alpha: 1,
      });
    }
  }

  update(dt: number): void {
    for (let i = this.particles.length - 1; i >= 0; i--) {
      const p = this.particles[i];
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.life -= dt;
      p.alpha = Math.max(0, p.life / p.maxLife);

      // Slow down
      p.vx *= 0.98;
      p.vy *= 0.98;

      if (p.life <= 0) {
        this.particles.splice(i, 1);
      }
    }
  }

  draw(ctx: CanvasRenderingContext2D): void {
    for (const p of this.particles) {
      ctx.globalAlpha = p.alpha * 0.8;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
      ctx.fillStyle = p.color;
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  burstAt(x: number, y: number, color: string): void {
    this.emit(x, y, "burst", color, 20);
  }

  clear(): void {
    this.particles = [];
  }

  get count(): number {
    return this.particles.length;
  }
}
