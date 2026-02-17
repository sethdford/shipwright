// Activity tab - filterable event feed with pagination

import { store } from "../core/state";
import {
  escapeHtml,
  formatDuration,
  formatTime,
  getBadgeClass,
  getTypeShort,
} from "../core/helpers";
import { icon } from "../design/icons";
import * as api from "../core/api";
import type { FleetState, View } from "../types/api";

function setupActivityFilters(): void {
  const chips = document.querySelectorAll("#activity-filters .filter-chip");
  chips.forEach((chip) => {
    chip.addEventListener("click", () => {
      store.set("activityFilter", chip.getAttribute("data-filter") || "all");
      const siblings = document.querySelectorAll(
        "#activity-filters .filter-chip",
      );
      siblings.forEach((s) => s.classList.remove("active"));
      chip.classList.add("active");
      renderActivityTimeline();
    });
  });

  const issueFilter = document.getElementById(
    "activity-issue-filter",
  ) as HTMLInputElement;
  if (issueFilter) {
    issueFilter.addEventListener("input", () => {
      store.set(
        "activityIssueFilter",
        issueFilter.value.replace(/[^0-9]/g, ""),
      );
      renderActivityTimeline();
    });
  }

  const loadMoreBtn = document.getElementById("load-more-btn");
  if (loadMoreBtn) loadMoreBtn.addEventListener("click", loadMoreActivity);
}

function loadActivity(): void {
  store.update({ activityOffset: 0, activityEvents: [] });

  api
    .fetchActivity({ limit: 50, offset: 0 })
    .then((result) => {
      store.update({
        activityEvents: result.events || [],
        activityHasMore: result.hasMore || false,
        activityOffset: (result.events || []).length,
      });
      renderActivityTimeline();
    })
    .catch((err) => {
      const el = document.getElementById("activity-timeline");
      if (el)
        el.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function loadMoreActivity(): void {
  const btn = document.getElementById("load-more-btn") as HTMLButtonElement;
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Loading...";
  }

  const offset = store.get("activityOffset");
  api
    .fetchActivity({ limit: 50, offset })
    .then((result) => {
      const existing = store.get("activityEvents");
      const newEvents = result.events || [];
      store.update({
        activityEvents: [...existing, ...newEvents],
        activityHasMore: result.hasMore || false,
        activityOffset: existing.length + newEvents.length,
      });
      renderActivityTimeline();
      if (btn) {
        btn.disabled = false;
        btn.textContent = "Load more";
      }
    })
    .catch(() => {
      if (btn) {
        btn.disabled = false;
        btn.textContent = "Load more";
      }
    });
}

function renderActivityTimeline(): void {
  const container = document.getElementById("activity-timeline");
  const loadMoreWrap = document.getElementById("activity-load-more");
  if (!container) return;

  const activityEvents = store.get("activityEvents");
  const activityFilter = store.get("activityFilter");
  const activityIssueFilter = store.get("activityIssueFilter");
  const activityHasMore = store.get("activityHasMore");

  const filtered = activityEvents.filter((ev) => {
    const typeRaw = String(ev.type || "");
    const badge = getBadgeClass(typeRaw);
    if (
      activityFilter !== "all" &&
      badge !== activityFilter &&
      !typeRaw.includes(activityFilter)
    )
      return false;
    if (activityIssueFilter && String(ev.issue || "") !== activityIssueFilter)
      return false;
    return true;
  });

  if (filtered.length === 0) {
    container.innerHTML =
      '<div class="empty-state"><p>No matching events</p></div>';
    if (loadMoreWrap)
      loadMoreWrap.style.display = activityHasMore ? "" : "none";
    return;
  }

  let html = "";
  for (const ev of filtered) {
    const typeRaw = String(ev.type || "unknown");
    const typeShort = getTypeShort(typeRaw);
    const badgeClass = getBadgeClass(typeRaw);

    let detail = "";
    if (ev.stage) detail += "stage=" + ev.stage + " ";
    if (ev.issueTitle) detail += ev.issueTitle;
    else if (ev.title) detail += ev.title;
    detail = detail.trim();

    if (!detail) {
      const skip: Record<string, boolean> = {
        ts: true,
        type: true,
        timestamp: true,
        issue: true,
        stage: true,
        duration_s: true,
        issueTitle: true,
        title: true,
      };
      const dparts: string[] = [];
      for (const [key, val] of Object.entries(ev)) {
        if (!skip[key]) dparts.push(key + "=" + val);
      }
      detail = dparts.join(" ");
    }

    html +=
      `<div class="timeline-row">` +
      `<span class="timeline-ts">${formatTime(String(ev.ts || ev.timestamp || ""))}</span>` +
      `<span class="activity-badge ${badgeClass}">${escapeHtml(typeShort)}</span>` +
      (ev.issue ? `<span class="timeline-issue">#${ev.issue}</span>` : "") +
      `<span class="timeline-detail">${escapeHtml(detail)}</span>` +
      (ev.duration_s != null
        ? `<span class="timeline-duration">${formatDuration(Number(ev.duration_s))}</span>`
        : "") +
      `</div>`;
  }

  container.innerHTML = html;
  if (loadMoreWrap) loadMoreWrap.style.display = activityHasMore ? "" : "none";
}

export const activityView: View = {
  init() {
    setupActivityFilters();
    if (store.get("activityEvents").length === 0) loadActivity();
  },
  render(_data: FleetState) {
    renderActivityTimeline();
  },
  destroy() {},
};
