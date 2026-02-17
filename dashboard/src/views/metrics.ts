// Metrics tab - success rate, duration, throughput, DORA, costs, stage performance

import { store } from "../core/state";
import {
  escapeHtml,
  fmtNum,
  formatDuration,
  animateValue,
} from "../core/helpers";
import { renderSVGDonut } from "../components/charts/donut";
import { renderSVGBarChart } from "../components/charts/bar";
import {
  renderSparkline,
  renderSVGLineChart,
} from "../components/charts/sparkline";
import { renderDoraGrades } from "../components/charts/pipeline-rail";
import { STAGES, STAGE_COLORS, STAGE_HEX } from "../design/tokens";
import * as api from "../core/api";
import type { FleetState, View, MetricsData } from "../types/api";

function fetchMetrics(): void {
  api
    .fetchMetricsHistory()
    .then((data) => {
      store.set("metricsCache", data);
      renderMetrics(data);
    })
    .catch((err) => {
      const el = document.getElementById("metrics-grid");
      if (el)
        el.innerHTML = `<div class="empty-state"><p>Failed to load metrics: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderMetrics(data: MetricsData): void {
  const firstRender = store.get("firstRender");

  // Success rate donut
  const rate = data.success_rate ?? 0;
  const donutWrap = document.getElementById("metric-donut-wrap");
  if (donutWrap) donutWrap.innerHTML = renderSVGDonut(rate);

  // Avg duration
  const avgDurEl = document.getElementById("metric-avg-duration");
  if (avgDurEl) avgDurEl.textContent = formatDuration(data.avg_duration_s);

  // Throughput
  const tp = data.throughput_per_hour ?? 0;
  const tpEl = document.getElementById("metric-throughput");
  if (tpEl) tpEl.textContent = tp.toFixed(2);

  // Totals
  const totalCompleted = data.total_completed ?? 0;
  const totalFailed = data.total_failed ?? 0;
  const tcEl = document.getElementById("metric-total-completed");
  if (tcEl) {
    if (firstRender && totalCompleted > 0)
      animateValue(tcEl, 0, totalCompleted, 800, "");
    else tcEl.textContent = fmtNum(totalCompleted);
  }
  const failedEl = document.getElementById("metric-total-failed");
  if (failedEl) {
    failedEl.textContent = fmtNum(totalFailed) + " failed";
    failedEl.style.color = totalFailed > 0 ? "var(--rose)" : "";
  }

  // Stage breakdown
  renderStageBreakdown(data.stage_durations || {});
  // Daily chart
  renderDailyChart(data.daily_counts || []);
  // DORA grades
  const doraContainer = document.getElementById("dora-grades-container");
  if (doraContainer && data.dora_grades) {
    doraContainer.innerHTML = renderDoraGrades(
      data.dora_grades as unknown as Record<
        string,
        { grade: string; value: number; unit: string }
      >,
    );
    doraContainer.style.display = "";
  } else if (doraContainer) {
    doraContainer.style.display = "none";
  }

  // Cost breakdown/trend
  if (document.getElementById("cost-breakdown-container"))
    renderCostBreakdown();
  if (document.getElementById("cost-trend-container")) renderCostTrend();
  if (document.getElementById("dora-trend-container")) renderDoraTrend();
  if (document.getElementById("stage-performance-container"))
    renderStagePerformance();
  if (document.getElementById("bottleneck-alert-container"))
    renderBottleneckAlert();
  if (document.getElementById("throughput-trend-container"))
    renderThroughputTrend();
  if (document.getElementById("capacity-forecast-container"))
    renderCapacityForecast();
}

function renderStageBreakdown(stageDurations: Record<string, number>): void {
  const container = document.getElementById("stage-breakdown");
  if (!container) return;
  const keys = Object.keys(stageDurations);
  if (keys.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>No data</p></div>';
    return;
  }

  let maxVal = 0;
  for (const k of keys) {
    if (stageDurations[k] > maxVal) maxVal = stageDurations[k];
  }
  if (maxVal === 0) maxVal = 1;

  let html = "";
  keys.forEach((stage, i) => {
    const val = stageDurations[stage];
    const pct = (val / maxVal) * 100;
    const colorIdx = i % STAGE_COLORS.length;
    html +=
      `<div class="stage-bar-row">` +
      `<span class="stage-bar-label">${escapeHtml(stage)}</span>` +
      `<div class="stage-bar-track-h"><div class="stage-bar-fill-h ${STAGE_COLORS[colorIdx]}" style="width:${pct}%"></div></div>` +
      `<span class="stage-bar-value">${formatDuration(val)}</span></div>`;
  });
  container.innerHTML = html;
}

function renderDailyChart(dailyCounts: any[]): void {
  const container = document.getElementById("daily-chart");
  if (!container) return;
  if (!dailyCounts || dailyCounts.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>No data</p></div>';
    return;
  }
  container.innerHTML = renderSVGBarChart(dailyCounts);
}

function renderCostBreakdown(): void {
  const container = document.getElementById("cost-breakdown-container");
  if (!container) return;

  api
    .fetchCostBreakdown()
    .then((data) => {
      store.set("costBreakdownCache", data as any);
      let html = "";

      if (data.by_model) {
        html +=
          '<div class="cost-section"><div class="cost-section-label">COST BY MODEL</div>';
        const modelColors: Record<string, string> = {
          opus: "#7c3aed",
          sonnet: "#00d4ff",
          haiku: "#4ade80",
        };
        const models = Object.keys(data.by_model);
        let maxModel = 0;
        models.forEach((m) => {
          if (data.by_model![m] > maxModel) maxModel = data.by_model![m];
        });
        if (maxModel === 0) maxModel = 1;
        models.forEach((m) => {
          const val = data.by_model![m];
          const pct = (val / maxModel) * 100;
          const color = modelColors[m.toLowerCase()] || "#5a6d8a";
          html +=
            `<div class="cost-bar-row"><span class="cost-bar-label">${escapeHtml(m)}</span>` +
            `<div class="cost-bar-track-h"><div class="cost-bar-fill-h" style="width:${pct}%;background:${color}"></div></div>` +
            `<span class="cost-bar-value">$${val.toFixed(2)}</span></div>`;
        });
        html += "</div>";
      }

      if (data.by_stage) {
        html +=
          '<div class="cost-section"><div class="cost-section-label">COST BY STAGE</div>';
        const stages = Object.keys(data.by_stage);
        let maxStage = 0;
        stages.forEach((s) => {
          if (data.by_stage![s] > maxStage) maxStage = data.by_stage![s];
        });
        if (maxStage === 0) maxStage = 1;
        stages.forEach((s) => {
          const val = data.by_stage![s];
          const pct = (val / maxStage) * 100;
          const barColor =
            (STAGE_HEX as Record<string, string>)[s] || "#5a6d8a";
          html +=
            `<div class="cost-bar-row"><span class="cost-bar-label">${escapeHtml(s)}</span>` +
            `<div class="cost-bar-track-h"><div class="cost-bar-fill-h" style="width:${pct}%;background:${barColor}"></div></div>` +
            `<span class="cost-bar-value">$${val.toFixed(2)}</span></div>`;
        });
        html += "</div>";
      }

      if (data.by_issue?.length) {
        html +=
          '<div class="cost-section"><div class="cost-section-label">COST PER ISSUE</div>';
        html +=
          '<table class="cost-issue-table"><thead><tr><th>Issue</th><th>Cost</th></tr></thead><tbody>';
        const sorted = [...data.by_issue].sort(
          (a, b) => (b.cost || 0) - (a.cost || 0),
        );
        sorted.forEach((item) => {
          html += `<tr><td>#${item.issue}</td><td>$${(item.cost || 0).toFixed(2)}</td></tr>`;
        });
        html += "</tbody></table></div>";
      }

      if (data.budget != null && data.spent != null) {
        const budgetPct =
          data.budget > 0 ? Math.min((data.spent / data.budget) * 100, 100) : 0;
        const budgetClass =
          budgetPct >= 80
            ? "cost-over"
            : budgetPct >= 60
              ? "cost-warn"
              : "cost-ok";
        html +=
          `<div class="cost-section"><div class="cost-section-label">BUDGET UTILIZATION</div>` +
          `<div class="budget-util-bar"><div class="cost-bar-track"><div class="cost-bar-fill ${budgetClass}" style="width:${budgetPct.toFixed(0)}%"></div></div>` +
          `<span class="budget-util-text">$${data.spent.toFixed(2)} / $${data.budget.toFixed(2)} (${budgetPct.toFixed(0)}%)</span></div></div>`;
      }

      container.innerHTML =
        html || '<div class="empty-state"><p>No cost data</p></div>';
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderCostTrend(): void {
  const container = document.getElementById("cost-trend-container");
  if (!container) return;
  api
    .fetchCostTrend()
    .then((data) => {
      const points = data.points || [];
      if (points.length === 0) {
        container.innerHTML =
          '<div class="empty-state"><p>No trend data</p></div>';
        return;
      }
      container.innerHTML = renderSVGLineChart(
        points,
        "cost",
        "#00d4ff",
        300,
        100,
      );
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderDoraTrend(): void {
  const container = document.getElementById("dora-trend-container");
  if (!container) return;
  api
    .fetchDoraTrend()
    .then((data) => {
      const metrics = [
        { key: "deploy_freq", label: "Deploy Freq", color: "#00d4ff" },
        { key: "lead_time", label: "Lead Time", color: "#0066ff" },
        { key: "cfr", label: "Change Fail Rate", color: "#f43f5e" },
        { key: "mttr", label: "MTTR", color: "#4ade80" },
      ];
      let html = '<div class="dora-trend-grid">';
      for (const m of metrics) {
        const points = data[m.key] || [];
        html += `<div class="dora-trend-card"><span class="dora-trend-label">${escapeHtml(m.label)}</span>`;
        html +=
          points.length > 0
            ? renderSparkline(
                points as Array<number | { value: number }>,
                m.color,
                120,
                30,
              )
            : '<span class="dora-trend-empty">\u2014</span>';
        html += "</div>";
      }
      html += "</div>";
      container.innerHTML = html;
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderStagePerformance(): void {
  const container = document.getElementById("stage-performance-container");
  if (!container) return;
  api
    .fetchStagePerformance()
    .then((data) => {
      const stages = data.stages || [];
      if (stages.length === 0) {
        container.innerHTML =
          '<div class="empty-state"><p>No stage performance data</p></div>';
        return;
      }
      let html =
        '<table class="stage-perf-table"><thead><tr><th>Stage</th><th>Avg</th><th>Min</th><th>Max</th><th>Count</th><th>Trend</th></tr></thead><tbody>';
      for (const s of stages) {
        let trendArrow = "";
        if (s.trend_pct != null) {
          if (s.trend_pct > 5)
            trendArrow = `<span class="trend-up">\u2191 ${s.trend_pct.toFixed(0)}%</span>`;
          else if (s.trend_pct < -5)
            trendArrow = `<span class="trend-down">\u2193 ${Math.abs(s.trend_pct).toFixed(0)}%</span>`;
          else trendArrow = '<span class="trend-flat">\u2192</span>';
        }
        html +=
          `<tr><td>${escapeHtml(s.name || s.stage || "")}</td><td>${formatDuration(s.avg_s)}</td><td>${formatDuration(s.min_s)}</td>` +
          `<td>${formatDuration(s.max_s)}</td><td>${s.count || 0}</td><td>${trendArrow}</td></tr>`;
      }
      html += "</tbody></table>";
      container.innerHTML = html;
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderBottleneckAlert(): void {
  const container = document.getElementById("bottleneck-alert-container");
  if (!container) return;
  api
    .fetchBottlenecks()
    .then((data) => {
      const bottlenecks = data.bottlenecks || [];
      if (bottlenecks.length === 0) {
        container.innerHTML = "";
        return;
      }
      let html = "";
      for (const b of bottlenecks) {
        if (b.impact === "low") continue;
        const msg =
          escapeHtml(b.stage || "Unknown") +
          " stage averages " +
          formatDuration(b.avgDuration) +
          " (" +
          escapeHtml(b.impact) +
          " impact)";
        const suggestion = b.suggestion
          ? `<div class="bottleneck-suggestion">${escapeHtml(b.suggestion)}</div>`
          : "";
        html += `<div class="bottleneck-alert"><span class="bottleneck-icon">\u26A0</span><span class="bottleneck-msg">${msg}</span>${suggestion}</div>`;
      }
      container.innerHTML = html;
    })
    .catch(() => {
      container.innerHTML = "";
    });
}

function renderThroughputTrend(): void {
  const container = document.getElementById("throughput-trend-container");
  if (!container) return;
  api
    .fetchThroughputTrend()
    .then((data) => {
      const points = data.points || [];
      if (points.length === 0) {
        container.innerHTML =
          '<div class="empty-state"><p>No throughput data</p></div>';
        return;
      }
      container.innerHTML = renderSVGLineChart(
        points,
        "throughput",
        "#4ade80",
        300,
        100,
      );
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderCapacityForecast(): void {
  const container = document.getElementById("capacity-forecast-container");
  if (!container) return;
  api
    .fetchCapacity()
    .then((data) => {
      if (!data.rate && !data.queue_clear_hours) {
        container.innerHTML =
          '<div class="empty-state"><p>No capacity data</p></div>';
        return;
      }
      const rate = data.rate != null ? data.rate.toFixed(1) : "?";
      const clearTime =
        data.queue_clear_hours != null
          ? data.queue_clear_hours.toFixed(1)
          : "?";
      container.innerHTML = `<div class="capacity-forecast"><span class="capacity-text">At current rate (${rate}/hr), queue will clear in <strong>${clearTime} hours</strong></span></div>`;
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

export const metricsView: View = {
  init() {
    fetchMetrics();
  },
  render(_data: FleetState) {
    // Metrics use cached data; don't re-fetch on every WS push
    const cache = store.get("metricsCache");
    if (cache) renderMetrics(cache);
  },
  destroy() {},
};
