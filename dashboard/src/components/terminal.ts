// ANSI terminal renderer for log streaming and live output

import { escapeHtml } from "../core/helpers";

const ANSI_COLORS: Record<string, string> = {
  "30": "#060a14",
  "31": "#f43f5e",
  "32": "#4ade80",
  "33": "#fbbf24",
  "34": "#0066ff",
  "35": "#7c3aed",
  "36": "#00d4ff",
  "37": "#e8ecf4",
  "90": "#5a6d8a",
  "91": "#f43f5e",
  "92": "#4ade80",
  "93": "#fbbf24",
  "94": "#0066ff",
  "95": "#7c3aed",
  "96": "#00d4ff",
  "97": "#e8ecf4",
};

export function renderAnsiToHtml(text: string): string {
  let result = "";
  let openSpans = 0;
  let i = 0;

  while (i < text.length) {
    if (text[i] === "\x1b" && text[i + 1] === "[") {
      const end = text.indexOf("m", i + 2);
      if (end !== -1) {
        const codes = text.substring(i + 2, end).split(";");
        for (const code of codes) {
          if (code === "0" || code === "") {
            while (openSpans > 0) {
              result += "</span>";
              openSpans--;
            }
          } else if (code === "1") {
            result += '<span style="font-weight:bold">';
            openSpans++;
          } else if (code === "2") {
            result += '<span style="opacity:0.7">';
            openSpans++;
          } else if (code === "3") {
            result += '<span style="font-style:italic">';
            openSpans++;
          } else if (code === "4") {
            result += '<span style="text-decoration:underline">';
            openSpans++;
          } else if (ANSI_COLORS[code]) {
            result += `<span style="color:${ANSI_COLORS[code]}">`;
            openSpans++;
          }
        }
        i = end + 1;
        continue;
      }
    }
    result += escapeHtml(text[i]);
    i++;
  }
  while (openSpans > 0) {
    result += "</span>";
    openSpans--;
  }
  return result;
}

export function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

export function renderLogViewer(content: string): string {
  if (!content)
    return '<div class="empty-state"><p>No logs available</p></div>';
  const clean = stripAnsi(content);
  const lines = clean.split("\n");
  let html = '<div class="log-viewer">';
  for (let i = 0; i < lines.length; i++) {
    const lineNum = i + 1;
    const lower = lines[i].toLowerCase();
    const lineClass =
      lower.indexOf("error") !== -1 || lower.indexOf("fail") !== -1
        ? " log-line-error"
        : "";
    html +=
      `<div class="log-line${lineClass}">` +
      `<span class="log-line-num">${lineNum}</span>` +
      `<span class="log-line-text">${escapeHtml(lines[i])}</span></div>`;
  }
  html += "</div>";
  return html;
}

export class LiveTerminal {
  private container: HTMLElement;
  private lines: string[] = [];
  private autoScroll = true;
  private maxLines = 5000;

  constructor(container: HTMLElement) {
    this.container = container;
    this.container.classList.add("live-terminal");
  }

  append(text: string): void {
    const newLines = text.split("\n");
    this.lines.push(...newLines);
    if (this.lines.length > this.maxLines) {
      this.lines = this.lines.slice(-this.maxLines);
    }
    this.render();
  }

  clear(): void {
    this.lines = [];
    this.render();
  }

  private render(): void {
    const html = this.lines
      .map((line, i) => {
        const rendered = renderAnsiToHtml(line);
        return `<div class="terminal-line"><span class="terminal-line-num">${i + 1}</span><span class="terminal-line-text">${rendered}</span></div>`;
      })
      .join("");
    this.container.innerHTML = html;

    if (this.autoScroll) {
      this.container.scrollTop = this.container.scrollHeight;
    }
  }

  setAutoScroll(enabled: boolean): void {
    this.autoScroll = enabled;
  }

  destroy(): void {
    this.container.innerHTML = "";
    this.lines = [];
  }
}
