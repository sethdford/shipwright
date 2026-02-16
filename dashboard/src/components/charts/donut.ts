// SVG Donut Chart

export function renderSVGDonut(rate: number): string {
  const size = 120;
  const strokeW = 12;
  const r = (size - strokeW) / 2;
  const c = Math.PI * 2 * r;
  const pct = Math.max(0, Math.min(100, rate));
  const offset = c - (pct / 100) * c;

  let svg = `<svg class="svg-donut" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">`;
  svg +=
    '<defs><linearGradient id="donut-grad" x1="0%" y1="0%" x2="100%" y2="100%">' +
    '<stop offset="0%" stop-color="#00d4ff"/><stop offset="100%" stop-color="#7c3aed"/></linearGradient></defs>';
  svg += `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="#0d1f3c" stroke-width="${strokeW}"/>`;
  svg +=
    `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="url(#donut-grad)" stroke-width="${strokeW}" ` +
    `stroke-linecap="round" stroke-dasharray="${c}" stroke-dashoffset="${offset}" ` +
    `transform="rotate(-90 ${size / 2} ${size / 2})" style="transition: stroke-dashoffset 0.8s ease"/>`;
  svg +=
    `<text x="${size / 2}" y="${size / 2 + 8}" text-anchor="middle" fill="#e8ecf4" ` +
    `font-family="'Instrument Serif', serif" font-size="24">${pct.toFixed(1)}%</text>`;
  svg += "</svg>";
  return svg;
}
