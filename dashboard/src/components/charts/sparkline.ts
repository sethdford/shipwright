// SVG Sparkline / Line Chart

export function renderSparkline(
  points: Array<number | { value: number }>,
  color: string,
  width: number,
  height: number,
): string {
  if (!points || points.length < 2) return "";

  let maxVal = 0;
  let minVal = Infinity;
  for (const p of points) {
    const v = typeof p === "object" ? p.value || 0 : p;
    if (v > maxVal) maxVal = v;
    if (v < minVal) minVal = v;
  }
  const range = maxVal - minVal || 1;
  const padding = 2;
  const w = width - padding * 2;
  const h = height - padding * 2;

  const pathParts: string[] = [];
  for (let i = 0; i < points.length; i++) {
    const v =
      typeof points[i] === "object"
        ? (points[i] as { value: number }).value || 0
        : (points[i] as number);
    const x = padding + (i / (points.length - 1)) * w;
    const y = padding + h - ((v - minVal) / range) * h;
    pathParts.push((i === 0 ? "M" : "L") + x.toFixed(1) + "," + y.toFixed(1));
  }

  return (
    `<svg class="sparkline" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">` +
    `<path d="${pathParts.join(" ")}" fill="none" stroke="${color}" stroke-width="1.5" stroke-linecap="round"/></svg>`
  );
}

export function renderSVGLineChart(
  points: Array<Record<string, number>>,
  valueKey: string,
  color: string,
  width: number,
  height: number,
): string {
  if (!points || points.length < 2)
    return '<div class="empty-state"><p>Not enough data</p></div>';

  let maxVal = 0;
  for (const p of points) {
    const v = p[valueKey] ?? p.value ?? 0;
    if (v > maxVal) maxVal = v;
  }
  if (maxVal === 0) maxVal = 1;

  const padding = 20;
  const chartW = width - padding * 2;
  const chartH = height - padding * 2;

  let svg = `<svg class="svg-line-chart" viewBox="0 0 ${width} ${height}" width="100%" height="${height}">`;

  for (let g = 0; g <= 4; g++) {
    const gy = padding + (g / 4) * chartH;
    svg += `<line x1="${padding}" y1="${gy}" x2="${width - padding}" y2="${gy}" stroke="#1a3a6a" stroke-width="0.5"/>`;
  }

  const pathParts: string[] = [];
  for (let i = 0; i < points.length; i++) {
    const v = points[i][valueKey] ?? points[i].value ?? 0;
    const x = padding + (i / (points.length - 1)) * chartW;
    const y = padding + chartH - (v / maxVal) * chartH;
    pathParts.push((i === 0 ? "M" : "L") + x.toFixed(1) + "," + y.toFixed(1));
  }

  const lastX = padding + chartW;
  const firstX = padding;
  svg += `<path d="${pathParts.join(" ")} L${lastX},${padding + chartH} L${firstX},${padding + chartH} Z" fill="${color}" opacity="0.1"/>`;
  svg += `<path d="${pathParts.join(" ")}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round"/>`;
  svg += "</svg>";
  return svg;
}
