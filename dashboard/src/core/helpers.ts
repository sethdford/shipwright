// Shared utility helpers

export function formatDuration(s: number | null | undefined): string {
  if (s == null) return "\u2014";
  s = Math.floor(s);
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
  return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
}

export function formatTime(iso: string | null | undefined): string {
  if (!iso) return "\u2014";
  const d = new Date(iso);
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  return `${h}:${m}:${s}`;
}

export function escapeHtml(str: string | null | undefined): string {
  if (!str) return "";
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function fmtNum(n: number | null | undefined): string {
  if (n == null) return "0";
  return Number(n).toLocaleString();
}

export function truncate(
  str: string | null | undefined,
  maxLen: number,
): string {
  if (!str) return "";
  return str.length > maxLen ? str.substring(0, maxLen) + "\u2026" : str;
}

export function padZero(n: number): string {
  return n < 10 ? "0" + n : "" + n;
}

export function getBadgeClass(typeRaw: string): string {
  if (typeRaw.includes("intervention")) return "intervention";
  if (typeRaw.includes("heartbeat")) return "heartbeat";
  if (typeRaw.includes("recovery") || typeRaw.includes("checkpoint"))
    return "recovery";
  if (typeRaw.includes("remote") || typeRaw.includes("distributed"))
    return "remote";
  if (typeRaw.includes("poll")) return "poll";
  if (typeRaw.includes("spawn")) return "spawn";
  if (typeRaw.includes("started")) return "started";
  if (typeRaw.includes("completed") || typeRaw.includes("reap"))
    return "completed";
  if (typeRaw.includes("failed")) return "failed";
  if (typeRaw.includes("stage")) return "stage";
  if (typeRaw.includes("scale")) return "scale";
  return "default";
}

export function getTypeShort(typeRaw: string): string {
  const parts = String(typeRaw || "unknown").split(".");
  return parts[parts.length - 1];
}

export function animateValue(
  el: HTMLElement | null,
  start: number,
  end: number,
  duration: number,
  suffix = "",
): void {
  if (!el) return;
  const diff = end - start;
  if (diff === 0) {
    el.textContent = fmtNum(end) + suffix;
    return;
  }
  let startTime: number | null = null;
  function step(timestamp: number) {
    if (!startTime) startTime = timestamp;
    const progress = Math.min((timestamp - startTime) / duration, 1);
    const current = Math.floor(start + diff * progress);
    el!.textContent = fmtNum(current) + suffix;
    if (progress < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

export function timeAgo(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
  if (seconds < 60) return seconds + "s ago";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + "m ago";
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + "h ago";
  return Math.floor(hours / 24) + "d ago";
}

export function formatMarkdown(text: string | null | undefined): string {
  if (!text) return "";
  let escaped = escapeHtml(text);
  escaped = escaped.replace(
    /^#{1,3}\s+(.+)$/gm,
    (_m, content) => "<strong>" + content + "</strong>",
  );
  escaped = escaped.replace(/```[\s\S]*?```/g, (block) => {
    const inner = block.replace(/^```\w*\n?/, "").replace(/\n?```$/, "");
    return '<pre class="artifact-code">' + inner + "</pre>";
  });
  escaped = escaped.replace(/`([^`]+)`/g, "<code>$1</code>");
  escaped = escaped.replace(/^[-*]\s+(.+)$/gm, "<li>$1</li>");
  escaped = escaped.replace(/\n/g, "<br>");
  return escaped;
}
