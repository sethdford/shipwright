// ── Fleet Command Dashboard ─────────────────────────────────────
// Multi-tab command center with WebSocket state + REST detail views

const STAGES = [
  "intake",
  "plan",
  "design",
  "build",
  "test",
  "review",
  "compound_quality",
  "pr",
  "merge",
  "deploy",
  "monitor",
];
const STAGE_SHORT = {
  intake: "INT",
  plan: "PLN",
  design: "DSN",
  build: "BLD",
  test: "TST",
  review: "REV",
  compound_quality: "QA",
  pr: "PR",
  merge: "MRG",
  deploy: "DPL",
  monitor: "MON",
};
const STAGE_COLORS = [
  "c-cyan",
  "c-blue",
  "c-purple",
  "c-green",
  "c-amber",
  "c-cyan",
  "c-blue",
  "c-purple",
  "c-green",
  "c-amber",
  "c-cyan",
];

// ── State ───────────────────────────────────────────────────────
let currentData = null;
let activeTab = "overview";
let metricsCache = null;
let pipelineDetail = null;
let selectedPipelineIssue = null;
let activityEvents = [];
let activityOffset = 0;
let activityHasMore = false;
let activityFilter = "all";
let activityIssueFilter = "";
let pipelineFilter = "all";
let firstRender = true;

// ── WebSocket ───────────────────────────────────────────────────
const wsUrl = `ws://${location.host}/ws`;
let ws;
let reconnectDelay = 1000;
let connectedAt = null;
let connectionTimer = null;

function connect() {
  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    reconnectDelay = 1000;
    connectedAt = Date.now();
    updateConnectionStatus("LIVE");
    startConnectionTimer();
  };

  ws.onclose = () => {
    connectedAt = null;
    stopConnectionTimer();
    updateConnectionStatus("OFFLINE");
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 10000);
  };

  ws.onerror = () => {};

  ws.onmessage = (e) => {
    try {
      const data = JSON.parse(e.data);
      currentData = data;
      renderCostTicker(data);
      renderActiveTab();
      firstRender = false;
    } catch (err) {
      console.error("Failed to parse message:", err);
    }
  };
}

// ── Connection Timer ────────────────────────────────────────────
function startConnectionTimer() {
  stopConnectionTimer();
  connectionTimer = setInterval(() => {
    if (connectedAt) {
      const elapsed = Math.floor((Date.now() - connectedAt) / 1000);
      const h = String(Math.floor(elapsed / 3600)).padStart(2, "0");
      const m = String(Math.floor((elapsed % 3600) / 60)).padStart(2, "0");
      const s = String(elapsed % 60).padStart(2, "0");
      document.getElementById("connection-text").textContent =
        "LIVE \u2014 " + h + ":" + m + ":" + s;
    }
  }, 1000);
}

function stopConnectionTimer() {
  if (connectionTimer) {
    clearInterval(connectionTimer);
    connectionTimer = null;
  }
}

function updateConnectionStatus(status) {
  const dot = document.getElementById("connection-dot");
  const text = document.getElementById("connection-text");
  if (status === "LIVE") {
    dot.className = "connection-dot live";
    text.textContent = "LIVE \u2014 00:00:00";
  } else {
    dot.className = "connection-dot offline";
    text.textContent = "OFFLINE";
  }
}

// ── Helpers ─────────────────────────────────────────────────────
function formatDuration(s) {
  if (s == null) return "\u2014";
  s = Math.floor(s);
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
  return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
}

function formatTime(iso) {
  if (!iso) return "\u2014";
  const d = new Date(iso);
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  return h + ":" + m + ":" + s;
}

function escapeHtml(str) {
  if (!str) return "";
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtNum(n) {
  if (n == null) return "0";
  return Number(n).toLocaleString();
}

function getBadgeClass(typeRaw) {
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

function getTypeShort(typeRaw) {
  var parts = String(typeRaw || "unknown").split(".");
  return parts[parts.length - 1];
}

// ── User Menu ───────────────────────────────────────────────────
let currentUser = null;

function fetchUser() {
  fetch("/api/me")
    .then(function (r) {
      if (!r.ok) throw new Error(r.status);
      return r.json();
    })
    .then(function (user) {
      currentUser = user;
      var initialsEl = document.getElementById("avatar-initials");
      var avatarBtn = document.getElementById("user-avatar");
      var usernameEl = document.getElementById("dropdown-username");

      usernameEl.textContent = escapeHtml(user.name || user.username || "User");

      if (user.avatar_url) {
        var img = document.createElement("img");
        img.src = user.avatar_url;
        img.alt = escapeHtml(user.name || "User");
        avatarBtn.innerHTML = "";
        avatarBtn.appendChild(img);
      } else {
        var name = user.name || user.username || "?";
        var parts = name.split(" ");
        var initials =
          parts.length >= 2
            ? (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
            : name.substring(0, 2).toUpperCase();
        initialsEl.textContent = initials;
      }
    })
    .catch(function () {});
}

function setupUserMenu() {
  var avatar = document.getElementById("user-avatar");
  var dropdown = document.getElementById("user-dropdown");

  avatar.addEventListener("click", function (e) {
    e.stopPropagation();
    dropdown.classList.toggle("open");
  });

  document.addEventListener("click", function () {
    dropdown.classList.remove("open");
  });
}

// ══════════════════════════════════════════════════════════════════
// TAB NAVIGATION
// ══════════════════════════════════════════════════════════════════

function setupTabs() {
  var btns = document.querySelectorAll(".tab-btn");
  for (var i = 0; i < btns.length; i++) {
    btns[i].addEventListener("click", function () {
      switchTab(this.getAttribute("data-tab"));
    });
  }

  // Read initial hash
  var hash = location.hash.replace("#", "");
  if (
    [
      "overview",
      "agents",
      "pipelines",
      "timeline",
      "activity",
      "metrics",
    ].indexOf(hash) !== -1
  ) {
    switchTab(hash);
  }

  window.addEventListener("hashchange", function () {
    var hash = location.hash.replace("#", "");
    if (
      [
        "overview",
        "agents",
        "pipelines",
        "timeline",
        "activity",
        "metrics",
      ].indexOf(hash) !== -1 &&
      hash !== activeTab
    ) {
      switchTab(hash);
    }
  });
}

function switchTab(tab) {
  activeTab = tab;
  location.hash = "#" + tab;

  // Update tab buttons
  var btns = document.querySelectorAll(".tab-btn");
  for (var i = 0; i < btns.length; i++) {
    if (btns[i].getAttribute("data-tab") === tab) {
      btns[i].classList.add("active");
    } else {
      btns[i].classList.remove("active");
    }
  }

  // Update panels
  var panels = document.querySelectorAll(".tab-panel");
  for (var i = 0; i < panels.length; i++) {
    if (panels[i].id === "panel-" + tab) {
      panels[i].classList.add("active");
    } else {
      panels[i].classList.remove("active");
    }
  }

  // Trigger renders for the activated tab
  if (tab === "activity" && activityEvents.length === 0) {
    loadActivity();
  }
  if (tab === "metrics") {
    fetchMetrics();
  }
  if (tab === "timeline") {
    fetchTimeline();
  }
  if (currentData) {
    renderActiveTab();
  }
}

function renderActiveTab() {
  if (!currentData) return;
  switch (activeTab) {
    case "overview":
      renderOverview(currentData);
      break;
    case "agents":
      renderAgentsTab(currentData);
      break;
    case "pipelines":
      renderPipelinesTab(currentData);
      break;
    case "timeline":
      // Timeline uses its own fetch; don't re-fetch on every WS push
      break;
    case "activity":
      // Activity tab uses its own data from /api/activity; just re-render filtered list
      renderActivityTimeline();
      break;
    case "metrics":
      // Metrics use cached data; don't re-fetch on every WS push
      break;
  }
}

// ══════════════════════════════════════════════════════════════════
// OVERVIEW TAB
// ══════════════════════════════════════════════════════════════════

function renderOverview(data) {
  renderStats(data);
  renderOverviewPipelines(data);
  renderQueue(data);
  renderOverviewActivity(data);
  renderResources(data);
  renderCostTicker(data);
  renderMachines(data);
}

// ── Stats ───────────────────────────────────────────────────────
function renderStats(data) {
  var d = data.daemon || {};
  var m = data.metrics || {};

  var statusEl = document.getElementById("stat-status");
  var statusDot = document.getElementById("status-dot");
  if (d.running) {
    statusEl.textContent = "OPERATIONAL";
    statusEl.className = "stat-value status-green";
    statusDot.className = "pulse-dot operational";
  } else {
    statusEl.textContent = "OFFLINE";
    statusEl.className = "stat-value status-rose";
    statusDot.className = "pulse-dot offline";
  }

  var active = data.pipelines ? data.pipelines.length : 0;
  var max = d.maxParallel || 0;
  document.getElementById("stat-active").textContent =
    fmtNum(active) + " / " + fmtNum(max);
  var barPct = max > 0 ? Math.min((active / max) * 100, 100) : 0;
  document.getElementById("stat-active-bar").style.width = barPct + "%";

  var queued = data.queue ? data.queue.length : 0;
  var queueEl = document.getElementById("stat-queue");
  queueEl.textContent = fmtNum(queued);
  queueEl.className =
    queued > 0 ? "stat-value status-amber" : "stat-value status-green";
  document.getElementById("stat-queue-sub").textContent =
    queued === 1 ? "issue waiting" : "issues waiting";

  var completed = m.completed != null ? m.completed : 0;
  document.getElementById("stat-completed").textContent = fmtNum(completed);
  var failed = m.failed != null ? m.failed : 0;
  var failedSub = document.getElementById("stat-failed-sub");
  failedSub.textContent = fmtNum(failed) + " failed";
  failedSub.className =
    failed > 0 ? "stat-subtitle failed-some" : "stat-subtitle failed-none";
}

// ── Overview Pipeline Cards ─────────────────────────────────────
function renderOverviewPipelines(data) {
  var container = document.getElementById("active-pipelines");

  if (!data.pipelines || data.pipelines.length === 0) {
    container.innerHTML =
      '<div class="empty-state">' +
      '<svg class="empty-icon" viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5">' +
      '<path d="M12 6v6l4 2M12 2a10 10 0 100 20 10 10 0 000-20z"/>' +
      "</svg>" +
      "<p>No active pipelines</p>" +
      "</div>";
    return;
  }

  var html = "";
  for (var idx = 0; idx < data.pipelines.length; idx++) {
    var p = data.pipelines[idx];
    var stagesDone = p.stagesDone || [];
    var currentStage = p.stage || "";

    var stageBar = "";
    for (var si = 0; si < STAGES.length; si++) {
      var s = STAGES[si];
      var cls = "stage-seg";
      if (stagesDone.indexOf(s) !== -1) cls += " done";
      else if (s === currentStage) cls += " active";
      stageBar += '<div class="' + cls + '">' + STAGE_SHORT[s] + "</div>";
    }

    var maxIter = p.maxIterations || 20;
    var curIter = p.iteration || 0;
    var iterPct = maxIter > 0 ? Math.min((curIter / maxIter) * 100, 100) : 0;

    var linesText =
      p.linesWritten != null ? fmtNum(p.linesWritten) + " lines" : "";
    var testsText =
      p.testsPassing === true
        ? '<span class="tests-pass">Tests \u2713</span>'
        : p.testsPassing === false
          ? '<span class="tests-fail">Tests \u2717</span>'
          : "";
    var metaParts = [linesText, testsText].filter(Boolean);

    var animDelay = firstRender
      ? ' style="animation-delay:' + idx * 0.05 + 's"'
      : "";

    html +=
      '<div class="pipeline-card" data-issue="' +
      p.issue +
      '"' +
      animDelay +
      ">" +
      '<div class="pipeline-header">' +
      '<span class="pipeline-issue">#' +
      p.issue +
      "</span>" +
      '<span class="pipeline-title">' +
      escapeHtml(p.title) +
      "</span>" +
      '<span class="pipeline-elapsed">' +
      formatDuration(p.elapsed_s) +
      "</span>" +
      "</div>" +
      '<div class="stage-bar">' +
      stageBar +
      "</div>" +
      '<div class="pipeline-iter">' +
      '<span class="pipeline-iter-label">Iteration ' +
      curIter +
      "/" +
      maxIter +
      "</span>" +
      '<div class="iter-bar-track"><div class="iter-bar-fill" style="width:' +
      iterPct +
      '%"></div></div>' +
      "</div>" +
      '<div class="pipeline-meta">' +
      metaParts.join(" <span>\u00b7</span> ") +
      "</div>" +
      (p.worktree
        ? '<div class="pipeline-worktree">WORKTREE: ' +
          escapeHtml(p.worktree) +
          "</div>"
        : "") +
      "</div>";
  }

  container.innerHTML = html;

  // Click handlers to switch to pipelines tab and show detail
  var cards = container.querySelectorAll(".pipeline-card");
  for (var i = 0; i < cards.length; i++) {
    cards[i].addEventListener("click", function () {
      var issue = this.getAttribute("data-issue");
      switchTab("pipelines");
      fetchPipelineDetail(issue);
    });
  }
}

// ── Queue ───────────────────────────────────────────────────────
function renderQueue(data) {
  var container = document.getElementById("queue-list");

  if (!data.queue || data.queue.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>Queue clear</p></div>';
    return;
  }

  var html = "";
  for (var i = 0; i < data.queue.length; i++) {
    var q = data.queue[i];
    html +=
      '<div class="queue-row">' +
      '<span class="queue-issue">#' +
      q.issue +
      "</span>" +
      '<span class="queue-title-text">' +
      escapeHtml(q.title) +
      "</span>" +
      '<span class="queue-score">' +
      (q.score != null ? q.score : "\u2014") +
      "</span>" +
      "</div>";
  }
  container.innerHTML = html;
}

// ── Overview Activity Feed (compact, 10 items) ──────────────────
function renderOverviewActivity(data) {
  var container = document.getElementById("activity-feed");

  if (!data.events || data.events.length === 0) {
    container.innerHTML =
      '<div class="empty-state"><p>Awaiting events...</p></div>';
    return;
  }

  var events = data.events.slice(-10).reverse();
  var html = "";
  for (var i = 0; i < events.length; i++) {
    var ev = events[i];
    var typeRaw = String(ev.type || "unknown");
    var typeShort = getTypeShort(typeRaw);
    var badgeClass = getBadgeClass(typeRaw);

    var detail = "";
    var skip = { ts: 1, type: 1, timestamp: 1 };
    var keys = Object.keys(ev);
    var dparts = [];
    for (var k = 0; k < keys.length; k++) {
      if (!skip[keys[k]]) dparts.push(keys[k] + "=" + ev[keys[k]]);
    }
    detail = dparts.join(" ");

    html +=
      '<div class="activity-row">' +
      '<span class="activity-ts">' +
      formatTime(ev.ts || ev.timestamp) +
      "</span>" +
      '<span class="activity-badge ' +
      badgeClass +
      '">' +
      escapeHtml(typeShort) +
      "</span>" +
      '<span class="activity-detail">' +
      escapeHtml(detail) +
      "</span>" +
      "</div>";
  }
  container.innerHTML = html;
}

// ── Resources ───────────────────────────────────────────────────
function renderResources(data) {
  var s = data.scale || {};
  var m = data.metrics || {};

  var cores = m.cpuCores || s.cpuCores || 0;
  var maxByCpu = s.maxByCpu != null ? s.maxByCpu : null;
  var maxByMem = s.maxByMem != null ? s.maxByMem : null;
  var maxByBudget = s.maxByBudget != null ? s.maxByBudget : null;
  var active = data.pipelines ? data.pipelines.length : 0;

  var cpuBar = document.getElementById("res-cpu-bar");
  var cpuInfo = document.getElementById("res-cpu-info");
  if (maxByCpu != null) {
    var cpuPct = maxByCpu > 0 ? Math.min((active / maxByCpu) * 100, 100) : 0;
    cpuBar.style.width = cpuPct + "%";
    cpuBar.className = "resource-bar-fill";
    cpuInfo.textContent = maxByCpu + " max (" + cores + " cores)";
  } else {
    cpuBar.style.width = "0%";
    cpuInfo.textContent = "\u2014";
  }

  var memBar = document.getElementById("res-mem-bar");
  var memInfo = document.getElementById("res-mem-info");
  if (maxByMem != null) {
    var memPct = maxByMem > 0 ? Math.min((active / maxByMem) * 100, 100) : 0;
    memBar.style.width = memPct + "%";
    memBar.className =
      maxByMem <= 1
        ? "resource-bar-fill critical"
        : maxByMem <= 2
          ? "resource-bar-fill warning"
          : "resource-bar-fill";
    var memGb = s.availMemGb != null ? s.availMemGb + "GB free" : "";
    memInfo.textContent = maxByMem + " max" + (memGb ? " (" + memGb + ")" : "");
  } else {
    memBar.style.width = "0%";
    memInfo.textContent = "\u2014";
  }

  var budgetBar = document.getElementById("res-budget-bar");
  var budgetInfo = document.getElementById("res-budget-info");
  if (maxByBudget != null) {
    var budgetPct =
      maxByBudget > 0 ? Math.min((active / maxByBudget) * 100, 100) : 0;
    budgetBar.style.width = budgetPct + "%";
    budgetBar.className = "resource-bar-fill";
    budgetInfo.textContent = maxByBudget + " max";
  } else {
    budgetBar.style.width = "0%";
    budgetInfo.textContent = "unlimited";
  }

  var constraintEl = document.getElementById("resource-constraint");
  if (maxByMem != null && maxByCpu != null) {
    var minFactor = Math.min(
      maxByCpu || Infinity,
      maxByMem || Infinity,
      maxByBudget != null ? maxByBudget : Infinity,
    );
    if (minFactor === maxByMem && maxByMem <= 2) {
      constraintEl.innerHTML =
        '<span class="constraint-badge warning">MEM-BOUND</span>';
    } else if (maxByBudget != null && minFactor === maxByBudget) {
      constraintEl.innerHTML =
        '<span class="constraint-badge warning">BUDGET-BOUND</span>';
    } else {
      constraintEl.innerHTML =
        '<span class="constraint-badge nominal">NOMINAL</span>';
    }
  } else {
    constraintEl.innerHTML =
      '<span class="constraint-badge nominal">NOMINAL</span>';
  }
}

// ══════════════════════════════════════════════════════════════════
// PIPELINES TAB
// ══════════════════════════════════════════════════════════════════

function setupPipelineFilters() {
  var chips = document.querySelectorAll("#pipeline-filters .filter-chip");
  for (var i = 0; i < chips.length; i++) {
    chips[i].addEventListener("click", function () {
      pipelineFilter = this.getAttribute("data-filter");
      var siblings = document.querySelectorAll(
        "#pipeline-filters .filter-chip",
      );
      for (var j = 0; j < siblings.length; j++)
        siblings[j].classList.remove("active");
      this.classList.add("active");
      if (currentData) renderPipelinesTab(currentData);
    });
  }

  document
    .getElementById("detail-panel-close")
    .addEventListener("click", function () {
      closePipelineDetail();
    });
}

function renderPipelinesTab(data) {
  var tbody = document.getElementById("pipeline-table-body");
  var pipelines = data.pipelines || [];
  var events = data.events || [];

  // Build unified list: active pipelines + completed/failed from events
  var rows = [];

  // Active pipelines
  for (var i = 0; i < pipelines.length; i++) {
    var p = pipelines[i];
    rows.push({
      issue: p.issue,
      title: p.title || "",
      status: "active",
      stage: STAGE_SHORT[p.stage] || p.stage || "\u2014",
      elapsed_s: p.elapsed_s,
      branch: p.worktree || "",
      _raw: p,
    });
  }

  // Completed/failed from events
  var seen = {};
  for (var i = 0; i < rows.length; i++) seen[rows[i].issue] = true;

  for (var i = events.length - 1; i >= 0; i--) {
    var ev = events[i];
    if (!ev.issue || seen[ev.issue]) continue;
    var typeRaw = String(ev.type || "");
    if (typeRaw.includes("completed") || typeRaw.includes("failed")) {
      var st = typeRaw.includes("failed") ? "failed" : "completed";
      rows.push({
        issue: ev.issue,
        title: ev.issueTitle || ev.title || "",
        status: st,
        stage: st === "completed" ? "DONE" : "FAIL",
        elapsed_s: ev.duration_s || null,
        branch: "",
        _raw: ev,
      });
      seen[ev.issue] = true;
    }
  }

  // Filter
  var filtered = rows;
  if (pipelineFilter !== "all") {
    filtered = [];
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].status === pipelineFilter) filtered.push(rows[i]);
    }
  }

  if (filtered.length === 0) {
    tbody.innerHTML =
      '<tr><td colspan="6" class="empty-state"><p>No pipelines match filter</p></td></tr>';
    return;
  }

  var html = "";
  for (var i = 0; i < filtered.length; i++) {
    var r = filtered[i];
    var selectedClass = selectedPipelineIssue == r.issue ? " row-selected" : "";
    html +=
      '<tr class="pipeline-row' +
      selectedClass +
      '" data-issue="' +
      r.issue +
      '">' +
      '<td class="col-issue">#' +
      r.issue +
      "</td>" +
      '<td class="col-title">' +
      escapeHtml(r.title) +
      "</td>" +
      '<td><span class="status-badge ' +
      r.status +
      '">' +
      r.status.toUpperCase() +
      "</span></td>" +
      '<td class="col-stage">' +
      escapeHtml(r.stage) +
      "</td>" +
      '<td class="col-duration">' +
      formatDuration(r.elapsed_s) +
      "</td>" +
      '<td class="col-branch">' +
      escapeHtml(r.branch) +
      "</td>" +
      "</tr>";
  }
  tbody.innerHTML = html;

  // Click handlers
  var trs = tbody.querySelectorAll(".pipeline-row");
  for (var i = 0; i < trs.length; i++) {
    trs[i].addEventListener("click", function () {
      var issue = this.getAttribute("data-issue");
      if (selectedPipelineIssue == issue) {
        closePipelineDetail();
      } else {
        fetchPipelineDetail(issue);
      }
    });
  }
}

function fetchPipelineDetail(issue) {
  selectedPipelineIssue = issue;

  // Highlight row
  var trs = document.querySelectorAll("#pipeline-table-body .pipeline-row");
  for (var i = 0; i < trs.length; i++) {
    if (trs[i].getAttribute("data-issue") == issue) {
      trs[i].classList.add("row-selected");
    } else {
      trs[i].classList.remove("row-selected");
    }
  }

  var panel = document.getElementById("pipeline-detail-panel");
  var title = document.getElementById("detail-panel-title");
  var body = document.getElementById("detail-panel-body");

  title.textContent = "Pipeline #" + issue;
  body.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
  panel.classList.add("open");

  fetch("/api/pipeline/" + encodeURIComponent(issue))
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (detail) {
      pipelineDetail = detail;
      renderPipelineDetail(detail);
    })
    .catch(function (err) {
      body.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderPipelineDetail(detail) {
  var body = document.getElementById("detail-panel-body");
  var html = "";

  // Stage timeline
  var history = detail.stageHistory || [];
  if (history.length > 0) {
    html += '<div class="stage-timeline">';
    for (var i = 0; i < history.length; i++) {
      var sh = history[i];
      var isActive = sh.stage === detail.stage;
      var dotCls = isActive ? "active" : "done";
      html +=
        '<div class="stage-timeline-item">' +
        '<div class="stage-timeline-dot ' +
        dotCls +
        '"></div>' +
        '<span class="stage-timeline-name">' +
        escapeHtml(sh.stage) +
        "</span>" +
        '<span class="stage-timeline-duration">' +
        formatDuration(sh.duration_s) +
        "</span>" +
        "</div>";
    }
    html += "</div>";
  }

  // Meta row
  html += '<div class="detail-meta-row">';
  if (detail.branch) {
    html +=
      '<div class="detail-meta-item">Branch: <span>' +
      escapeHtml(detail.branch) +
      "</span></div>";
  }
  if (detail.elapsed_s != null) {
    html +=
      '<div class="detail-meta-item">Elapsed: <span>' +
      formatDuration(detail.elapsed_s) +
      "</span></div>";
  }
  if (detail.prLink) {
    html +=
      '<div class="detail-meta-item">PR: <a href="' +
      escapeHtml(detail.prLink) +
      '" target="_blank">' +
      escapeHtml(detail.prLink) +
      "</a></div>";
  }
  html += "</div>";

  // Plan
  if (detail.plan) {
    html +=
      '<div class="detail-section">' +
      '<div class="detail-section-label">PLAN</div>' +
      '<div class="detail-plan-content">' +
      escapeHtml(detail.plan) +
      "</div>" +
      "</div>";
  }

  // Design
  if (detail.design) {
    html +=
      '<div class="detail-section">' +
      '<div class="detail-section-label">DESIGN</div>' +
      '<div class="detail-plan-content">' +
      escapeHtml(detail.design) +
      "</div>" +
      "</div>";
  }

  // Definition of Done
  if (detail.dod) {
    html +=
      '<div class="detail-section">' +
      '<div class="detail-section-label">DEFINITION OF DONE</div>' +
      '<div class="detail-plan-content">' +
      escapeHtml(detail.dod) +
      "</div>" +
      "</div>";
  }

  body.innerHTML = html;
}

function closePipelineDetail() {
  selectedPipelineIssue = null;
  pipelineDetail = null;
  document.getElementById("pipeline-detail-panel").classList.remove("open");

  var trs = document.querySelectorAll("#pipeline-table-body .pipeline-row");
  for (var i = 0; i < trs.length; i++) {
    trs[i].classList.remove("row-selected");
  }
}

// ══════════════════════════════════════════════════════════════════
// ACTIVITY TAB
// ══════════════════════════════════════════════════════════════════

function setupActivityFilters() {
  var chips = document.querySelectorAll("#activity-filters .filter-chip");
  for (var i = 0; i < chips.length; i++) {
    chips[i].addEventListener("click", function () {
      activityFilter = this.getAttribute("data-filter");
      var siblings = document.querySelectorAll(
        "#activity-filters .filter-chip",
      );
      for (var j = 0; j < siblings.length; j++)
        siblings[j].classList.remove("active");
      this.classList.add("active");
      renderActivityTimeline();
    });
  }

  document
    .getElementById("activity-issue-filter")
    .addEventListener("input", function () {
      activityIssueFilter = this.value.replace(/[^0-9]/g, "");
      renderActivityTimeline();
    });

  document
    .getElementById("load-more-btn")
    .addEventListener("click", function () {
      loadMoreActivity();
    });
}

function loadActivity() {
  activityOffset = 0;
  activityEvents = [];

  fetch("/api/activity?limit=50&offset=0")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (result) {
      activityEvents = result.events || [];
      activityHasMore = result.hasMore || false;
      activityOffset = activityEvents.length;
      renderActivityTimeline();
    })
    .catch(function (err) {
      document.getElementById("activity-timeline").innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function loadMoreActivity() {
  var btn = document.getElementById("load-more-btn");
  btn.disabled = true;
  btn.textContent = "Loading...";

  fetch("/api/activity?limit=50&offset=" + activityOffset)
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (result) {
      var newEvents = result.events || [];
      for (var i = 0; i < newEvents.length; i++) {
        activityEvents.push(newEvents[i]);
      }
      activityHasMore = result.hasMore || false;
      activityOffset = activityEvents.length;
      renderActivityTimeline();
      btn.disabled = false;
      btn.textContent = "Load more";
    })
    .catch(function () {
      btn.disabled = false;
      btn.textContent = "Load more";
    });
}

function renderActivityTimeline() {
  var container = document.getElementById("activity-timeline");
  var loadMoreWrap = document.getElementById("activity-load-more");

  // Filter events
  var filtered = [];
  for (var i = 0; i < activityEvents.length; i++) {
    var ev = activityEvents[i];
    var typeRaw = String(ev.type || "");
    var badge = getBadgeClass(typeRaw);

    // Type filter
    if (activityFilter !== "all") {
      if (badge !== activityFilter && !typeRaw.includes(activityFilter))
        continue;
    }

    // Issue filter
    if (activityIssueFilter && String(ev.issue || "") !== activityIssueFilter)
      continue;

    filtered.push(ev);
  }

  if (filtered.length === 0) {
    container.innerHTML =
      '<div class="empty-state"><p>No matching events</p></div>';
    loadMoreWrap.style.display = activityHasMore ? "" : "none";
    return;
  }

  var html = "";
  for (var i = 0; i < filtered.length; i++) {
    var ev = filtered[i];
    var typeRaw = String(ev.type || "unknown");
    var typeShort = getTypeShort(typeRaw);
    var badgeClass = getBadgeClass(typeRaw);

    var detail = "";
    if (ev.stage) detail += "stage=" + ev.stage + " ";
    if (ev.issueTitle) detail += ev.issueTitle;
    else if (ev.title) detail += ev.title;
    detail = detail.trim();

    // Remaining keys
    if (!detail) {
      var skip = {
        ts: 1,
        type: 1,
        timestamp: 1,
        issue: 1,
        stage: 1,
        duration_s: 1,
        issueTitle: 1,
        title: 1,
      };
      var keys = Object.keys(ev);
      var dparts = [];
      for (var k = 0; k < keys.length; k++) {
        if (!skip[keys[k]]) dparts.push(keys[k] + "=" + ev[keys[k]]);
      }
      detail = dparts.join(" ");
    }

    html +=
      '<div class="timeline-row">' +
      '<span class="timeline-ts">' +
      formatTime(ev.ts || ev.timestamp) +
      "</span>" +
      '<span class="activity-badge ' +
      badgeClass +
      '">' +
      escapeHtml(typeShort) +
      "</span>" +
      (ev.issue
        ? '<span class="timeline-issue">#' + ev.issue + "</span>"
        : "") +
      '<span class="timeline-detail">' +
      escapeHtml(detail) +
      "</span>" +
      (ev.duration_s != null
        ? '<span class="timeline-duration">' +
          formatDuration(ev.duration_s) +
          "</span>"
        : "") +
      "</div>";
  }

  container.innerHTML = html;
  loadMoreWrap.style.display = activityHasMore ? "" : "none";
}

// ══════════════════════════════════════════════════════════════════
// METRICS TAB
// ══════════════════════════════════════════════════════════════════

function fetchMetrics() {
  fetch("/api/metrics/history")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      metricsCache = data;
      renderMetrics(data);
    })
    .catch(function (err) {
      document.getElementById("metrics-grid").innerHTML =
        '<div class="empty-state"><p>Failed to load metrics: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderMetrics(data) {
  // Success rate donut
  var rate = data.success_rate != null ? data.success_rate : 0;
  var donut = document.getElementById("metric-donut");
  donut.style.setProperty("--pct", rate + "%");
  document.getElementById("metric-success-rate").textContent =
    rate.toFixed(1) + "%";

  // Avg duration
  document.getElementById("metric-avg-duration").textContent = formatDuration(
    data.avg_duration_s,
  );

  // Throughput
  var tp = data.throughput_per_hour != null ? data.throughput_per_hour : 0;
  document.getElementById("metric-throughput").textContent = tp.toFixed(2);

  // Totals
  var totalCompleted = data.total_completed != null ? data.total_completed : 0;
  var totalFailed = data.total_failed != null ? data.total_failed : 0;
  document.getElementById("metric-total-completed").textContent =
    fmtNum(totalCompleted);
  var failedEl = document.getElementById("metric-total-failed");
  failedEl.textContent = fmtNum(totalFailed) + " failed";
  failedEl.className = totalFailed > 0 ? "metric-sub" : "metric-sub";
  failedEl.style.color = totalFailed > 0 ? "var(--rose)" : "";

  // Stage duration breakdown
  renderStageBreakdown(data.stage_durations || {});

  // Daily chart
  renderDailyChart(data.daily_counts || []);
}

function renderStageBreakdown(stageDurations) {
  var container = document.getElementById("stage-breakdown");
  var keys = Object.keys(stageDurations);
  if (keys.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>No data</p></div>';
    return;
  }

  // Find max for scaling
  var maxVal = 0;
  for (var i = 0; i < keys.length; i++) {
    if (stageDurations[keys[i]] > maxVal) maxVal = stageDurations[keys[i]];
  }
  if (maxVal === 0) maxVal = 1;

  var html = "";
  for (var i = 0; i < keys.length; i++) {
    var stage = keys[i];
    var val = stageDurations[stage];
    var pct = (val / maxVal) * 100;
    var colorIdx = i % STAGE_COLORS.length;

    html +=
      '<div class="stage-bar-row">' +
      '<span class="stage-bar-label">' +
      escapeHtml(stage) +
      "</span>" +
      '<div class="stage-bar-track-h">' +
      '<div class="stage-bar-fill-h ' +
      STAGE_COLORS[colorIdx] +
      '" style="width:' +
      pct +
      '%"></div>' +
      "</div>" +
      '<span class="stage-bar-value">' +
      formatDuration(val) +
      "</span>" +
      "</div>";
  }

  container.innerHTML = html;
}

function renderDailyChart(dailyCounts) {
  var container = document.getElementById("daily-chart");

  if (!dailyCounts || dailyCounts.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>No data</p></div>';
    return;
  }

  // Find max for scaling
  var maxCount = 0;
  for (var i = 0; i < dailyCounts.length; i++) {
    var total = (dailyCounts[i].completed || 0) + (dailyCounts[i].failed || 0);
    if (total > maxCount) maxCount = total;
  }
  if (maxCount === 0) maxCount = 1;

  var chartHeight = 80; // pixels
  var html = '<div class="bar-chart">';
  for (var i = 0; i < dailyCounts.length; i++) {
    var day = dailyCounts[i];
    var completed = day.completed || 0;
    var failed = day.failed || 0;
    var cH = Math.round((completed / maxCount) * chartHeight);
    var fH = Math.round((failed / maxCount) * chartHeight);

    // Date label: MM/DD
    var dateStr = day.date || "";
    var parts = dateStr.split("-");
    var label = parts.length >= 3 ? parts[1] + "/" + parts[2] : dateStr;

    html +=
      '<div class="bar-group">' +
      '<div class="bar-stack">' +
      (fH > 0
        ? '<div class="bar-seg failed" style="height:' + fH + 'px"></div>'
        : "") +
      (cH > 0
        ? '<div class="bar-seg completed" style="height:' + cH + 'px"></div>'
        : "") +
      (cH === 0 && fH === 0
        ? '<div class="bar-seg" style="height:1px;background:var(--ocean)"></div>'
        : "") +
      "</div>" +
      '<span class="bar-date">' +
      escapeHtml(label) +
      "</span>" +
      "</div>";
  }
  html += "</div>";

  container.innerHTML = html;
}

// ══════════════════════════════════════════════════════════════════
// AGENTS TAB
// ══════════════════════════════════════════════════════════════════

function renderAgentsTab(data) {
  var container = document.getElementById("agents-grid");
  var agents = data.agents || [];

  if (agents.length === 0) {
    container.innerHTML =
      '<div class="empty-state"><p>No active agents</p></div>';
    return;
  }

  var html = "";
  for (var i = 0; i < agents.length; i++) {
    var a = agents[i];
    var presenceClass = a.status || "dead";
    var elapsed = a.elapsed_s ? formatDuration(a.elapsed_s) : "—";
    var memPct =
      a.memory_mb > 0 ? Math.min((a.memory_mb / 2048) * 100, 100) : 0;
    var cpuPct = a.cpu_pct || 0;

    html +=
      '<div class="agent-card" data-issue="' +
      a.issue +
      '">' +
      '<div class="agent-card-header">' +
      '<span class="presence-dot ' +
      presenceClass +
      '"></span>' +
      '<span class="agent-issue">#' +
      a.issue +
      "</span>" +
      '<span class="agent-machine">' +
      escapeHtml(a.machine || "localhost") +
      "</span>" +
      "</div>" +
      '<div class="agent-title">' +
      escapeHtml(a.title || "Untitled") +
      "</div>" +
      '<div class="agent-stage">' +
      '<span class="agent-stage-badge">' +
      escapeHtml(a.stage || "—") +
      "</span>" +
      '<span class="agent-iteration">iter ' +
      (a.iteration || 0) +
      "</span>" +
      "</div>" +
      '<div class="agent-activity">' +
      escapeHtml(a.activity || "—") +
      "</div>" +
      '<div class="agent-resources">' +
      '<div class="agent-res-row">' +
      '<span class="agent-res-label">CPU</span>' +
      '<div class="resource-bar-track"><div class="resource-bar-fill" style="width:' +
      cpuPct +
      '%"></div></div>' +
      '<span class="agent-res-val">' +
      cpuPct.toFixed(0) +
      "%</span>" +
      "</div>" +
      '<div class="agent-res-row">' +
      '<span class="agent-res-label">MEM</span>' +
      '<div class="resource-bar-track"><div class="resource-bar-fill" style="width:' +
      memPct.toFixed(0) +
      '%"></div></div>' +
      '<span class="agent-res-val">' +
      a.memory_mb +
      "MB</span>" +
      "</div>" +
      "</div>" +
      '<div class="agent-meta">' +
      '<span class="agent-elapsed">' +
      elapsed +
      "</span>" +
      '<span class="agent-heartbeat">' +
      (a.heartbeat_age_s != null
        ? a.heartbeat_age_s + "s ago"
        : "no heartbeat") +
      "</span>" +
      "</div>" +
      '<div class="agent-actions">' +
      '<button class="agent-action-btn" onclick="sendIntervention(' +
      a.issue +
      ', \'pause\')" title="Pause">&#9646;&#9646;</button>' +
      '<button class="agent-action-btn" onclick="sendIntervention(' +
      a.issue +
      ', \'resume\')" title="Resume">&#9654;</button>' +
      '<button class="agent-action-btn" onclick="openInterventionModal(' +
      a.issue +
      ')" title="Message">&#9993;</button>' +
      '<button class="agent-action-btn btn-abort" onclick="confirmAbort(' +
      a.issue +
      ')" title="Abort">&#10005;</button>' +
      "</div>" +
      "</div>";
  }

  container.innerHTML = html;
}

// ══════════════════════════════════════════════════════════════════
// TIMELINE TAB
// ══════════════════════════════════════════════════════════════════

var timelineCache = null;

function fetchTimeline() {
  var rangeEl = document.getElementById("timeline-range");
  var hours = rangeEl ? rangeEl.value : "24";
  fetch("/api/timeline?range=" + hours + "h")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      timelineCache = data;
      renderTimelineTab(data);
    })
    .catch(function (err) {
      document.getElementById("gantt-chart").innerHTML =
        '<div class="empty-state"><p>Failed to load timeline: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderTimelineTab(data) {
  var container = document.getElementById("gantt-chart");
  var entries = data;

  if (!Array.isArray(entries)) entries = data.timeline || [];
  if (entries.length === 0) {
    container.innerHTML =
      '<div class="empty-state"><p>No timeline data</p></div>';
    return;
  }

  // Calculate time range
  var rangeEl = document.getElementById("timeline-range");
  var rangeHours = rangeEl ? parseInt(rangeEl.value, 10) : 24;
  var now = Date.now();
  var rangeStart = now - rangeHours * 3600 * 1000;
  var rangeMs = now - rangeStart;

  // Build hour markers
  var markerCount = Math.min(rangeHours, 12);
  var markerStep = rangeHours / markerCount;
  var headerHtml =
    '<div class="gantt-header"><span class="gantt-label-header">Issue</span><div class="gantt-bar-header">';
  for (var m = 0; m <= markerCount; m++) {
    var markerTime = new Date(rangeStart + m * markerStep * 3600 * 1000);
    var markerLabel = padZero(markerTime.getHours()) + ":00";
    var markerPct = (m / markerCount) * 100;
    headerHtml +=
      '<span class="gantt-marker" style="left:' +
      markerPct +
      '%">' +
      markerLabel +
      "</span>";
  }
  headerHtml += "</div></div>";

  // Build rows
  var rowsHtml = "";
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i];
    var segments = entry.segments || [];

    rowsHtml +=
      '<div class="gantt-row">' +
      '<span class="gantt-label">#' +
      entry.issue +
      '<span class="gantt-label-title">' +
      escapeHtml(truncate(entry.title || "", 20)) +
      "</span></span>" +
      '<div class="gantt-bar-area">';

    for (var s = 0; s < segments.length; s++) {
      var seg = segments[s];
      var segStart = new Date(seg.start).getTime();
      var segEnd = seg.end ? new Date(seg.end).getTime() : now;

      // Clamp to visible range
      if (segEnd < rangeStart) continue;
      if (segStart < rangeStart) segStart = rangeStart;

      var leftPct = ((segStart - rangeStart) / rangeMs) * 100;
      var widthPct = ((segEnd - segStart) / rangeMs) * 100;
      if (widthPct < 0.3) widthPct = 0.3; // min visible width

      var statusClass =
        seg.status === "failed"
          ? "failed"
          : seg.status === "running"
            ? "running"
            : "done";
      var segDuration = formatDuration(Math.round((segEnd - segStart) / 1000));

      rowsHtml +=
        '<div class="gantt-segment ' +
        statusClass +
        '" style="left:' +
        leftPct.toFixed(2) +
        "%;width:" +
        widthPct.toFixed(2) +
        '%" title="' +
        escapeHtml(seg.stage) +
        " — " +
        segDuration +
        '">' +
        '<span class="gantt-seg-label">' +
        escapeHtml(seg.stage) +
        "</span>" +
        "</div>";
    }

    rowsHtml += "</div></div>";
  }

  container.innerHTML = headerHtml + rowsHtml;
}

function setupTimelineControls() {
  var rangeEl = document.getElementById("timeline-range");
  if (rangeEl) {
    rangeEl.addEventListener("change", function () {
      fetchTimeline();
    });
  }
}

// ══════════════════════════════════════════════════════════════════
// COST TICKER
// ══════════════════════════════════════════════════════════════════

function renderCostTicker(data) {
  var ticker = document.getElementById("cost-ticker");
  if (!ticker) return;

  var cost = data.cost;
  if (!cost || cost.daily_budget == null) {
    ticker.innerHTML = "";
    return;
  }

  var spent = cost.today_spent || 0;
  var budget = cost.daily_budget || 1;
  var pct = budget > 0 ? Math.min((spent / budget) * 100, 100) : 0;
  var statusClass = pct >= 80 ? "over" : pct >= 60 ? "warn" : "ok";

  ticker.innerHTML =
    '<span class="cost-amount">$' +
    spent.toFixed(2) +
    "</span>" +
    '<span class="cost-sep"> / </span>' +
    '<span class="cost-budget">$' +
    budget.toFixed(2) +
    "</span>" +
    '<div class="cost-bar-track"><div class="cost-bar-fill ' +
    statusClass +
    '" style="width:' +
    pct.toFixed(0) +
    '%"></div></div>';
}

// ══════════════════════════════════════════════════════════════════
// MACHINES
// ══════════════════════════════════════════════════════════════════

function renderMachines(data) {
  var section = document.getElementById("machines-section");
  var grid = document.getElementById("machines-grid");
  if (!section || !grid) return;

  var machines = data.machines || [];
  if (machines.length === 0) {
    section.style.display = "none";
    return;
  }

  section.style.display = "";
  var html = "";
  for (var i = 0; i < machines.length; i++) {
    var m = machines[i];
    var statusClass = m.status || "offline";

    html +=
      '<div class="machine-card">' +
      '<div class="machine-card-header">' +
      '<span class="presence-dot ' +
      statusClass +
      '"></span>' +
      '<span class="machine-name">' +
      escapeHtml(m.name) +
      "</span>" +
      '<span class="machine-role">' +
      escapeHtml(m.role || "worker") +
      "</span>" +
      "</div>" +
      '<div class="machine-host">' +
      escapeHtml(m.host || "—") +
      "</div>" +
      '<div class="machine-workers">' +
      '<span class="machine-workers-label">Workers:</span> ' +
      (m.active_workers || 0) +
      " / " +
      (m.max_workers || 0) +
      "</div>" +
      "</div>";
  }

  grid.innerHTML = html;
}

// ══════════════════════════════════════════════════════════════════
// INTERVENTION HANDLERS
// ══════════════════════════════════════════════════════════════════

var interventionTarget = null;

function sendIntervention(issue, action, body) {
  var opts = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  };
  if (body) opts.body = JSON.stringify(body);
  fetch("/api/intervention/" + issue + "/" + action, opts)
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function () {
      // Refresh agents tab
      if (activeTab === "agents" && currentData) renderAgentsTab(currentData);
    })
    .catch(function (err) {
      console.error("Intervention failed:", err);
    });
}

function confirmAbort(issue) {
  if (
    confirm("Abort pipeline for issue #" + issue + "? This cannot be undone.")
  ) {
    sendIntervention(issue, "abort");
  }
}

function openInterventionModal(issue) {
  interventionTarget = issue;
  var modal = document.getElementById("intervention-modal");
  var title = document.getElementById("modal-title");
  var msg = document.getElementById("modal-message");
  if (modal) modal.style.display = "";
  if (title) title.textContent = "Send Message to #" + issue;
  if (msg) msg.value = "";
}

function setupInterventionModal() {
  var modal = document.getElementById("intervention-modal");
  var closeBtn = document.getElementById("modal-close");
  var cancelBtn = document.getElementById("modal-cancel");
  var sendBtn = document.getElementById("modal-send");
  var msgEl = document.getElementById("modal-message");

  function closeModal() {
    if (modal) modal.style.display = "none";
    interventionTarget = null;
  }

  if (closeBtn) closeBtn.addEventListener("click", closeModal);
  if (cancelBtn) cancelBtn.addEventListener("click", closeModal);
  if (modal) {
    modal.addEventListener("click", function (e) {
      if (e.target === modal) closeModal();
    });
  }
  if (sendBtn) {
    sendBtn.addEventListener("click", function () {
      if (interventionTarget && msgEl && msgEl.value.trim()) {
        sendIntervention(interventionTarget, "message", {
          message: msgEl.value.trim(),
        });
        closeModal();
      }
    });
  }
}

// ══════════════════════════════════════════════════════════════════
// HELPERS — truncate
// ══════════════════════════════════════════════════════════════════

function truncate(str, maxLen) {
  if (!str) return "";
  return str.length > maxLen ? str.substring(0, maxLen) + "…" : str;
}

function padZero(n) {
  return n < 10 ? "0" + n : "" + n;
}

// ══════════════════════════════════════════════════════════════════
// BOOT
// ══════════════════════════════════════════════════════════════════

fetchUser();
setupUserMenu();
setupTabs();
setupPipelineFilters();
setupActivityFilters();
setupTimelineControls();
setupInterventionModal();
connect();
