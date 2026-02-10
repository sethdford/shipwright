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
const STAGE_HEX = {
  intake: "#00d4ff",
  plan: "#0066ff",
  design: "#7c3aed",
  build: "#4ade80",
  test: "#fbbf24",
  review: "#00d4ff",
  compound_quality: "#0066ff",
  pr: "#7c3aed",
  merge: "#4ade80",
  deploy: "#fbbf24",
  monitor: "#00d4ff",
};

// ── State ───────────────────────────────────────────────────────
var currentData = null;
var activeTab = "overview";
var metricsCache = null;
var pipelineDetail = null;
var selectedPipelineIssue = null;
var activityEvents = [];
var activityOffset = 0;
var activityHasMore = false;
var activityFilter = "all";
var activityIssueFilter = "";
var pipelineFilter = "all";
var firstRender = true;
var insightsCache = null;
var selectedIssues = {};
var alertsCache = null;
var alertDismissed = false;
var costBreakdownCache = null;
var machinesCache = null;
var joinTokensCache = null;
var workerUpdateTimer = null;
var removeMachineTarget = null;
var teamCache = null;
var teamActivityCache = null;
var teamRefreshTimer = null;

// ── WebSocket ───────────────────────────────────────────────────
var wsUrl = "ws://" + location.host + "/ws";
var ws;
var reconnectDelay = 1000;
var connectedAt = null;
var connectionTimer = null;

function connect() {
  ws = new WebSocket(wsUrl);

  ws.onopen = function () {
    reconnectDelay = 1000;
    connectedAt = Date.now();
    updateConnectionStatus("LIVE");
    startConnectionTimer();
  };

  ws.onclose = function () {
    connectedAt = null;
    stopConnectionTimer();
    updateConnectionStatus("OFFLINE");
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 10000);
  };

  ws.onerror = function () {};

  ws.onmessage = function (e) {
    try {
      var data = JSON.parse(e.data);
      currentData = data;
      renderCostTicker(data);
      renderActiveTab();
      renderAlertBanner();
      updateEmergencyBrakeVisibility(data);
      if (data.team && activeTab === "team") {
        renderTeamGrid(data.team);
        renderTeamStats(data.team);
      }
      firstRender = false;
    } catch (err) {
      console.error("Failed to parse message:", err);
    }
  };
}

// ── Connection Timer ────────────────────────────────────────────
function startConnectionTimer() {
  stopConnectionTimer();
  connectionTimer = setInterval(function () {
    if (connectedAt) {
      var elapsed = Math.floor((Date.now() - connectedAt) / 1000);
      var h = String(Math.floor(elapsed / 3600)).padStart(2, "0");
      var m = String(Math.floor((elapsed % 3600) / 60)).padStart(2, "0");
      var s = String(elapsed % 60).padStart(2, "0");
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
  var dot = document.getElementById("connection-dot");
  var text = document.getElementById("connection-text");
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
  var d = new Date(iso);
  var h = String(d.getHours()).padStart(2, "0");
  var m = String(d.getMinutes()).padStart(2, "0");
  var s = String(d.getSeconds()).padStart(2, "0");
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

// ── Animated Number Counter ─────────────────────────────────────
function animateValue(el, start, end, duration, suffix) {
  if (!el) return;
  if (typeof suffix === "undefined") suffix = "";
  var startTime = null;
  var diff = end - start;

  function step(timestamp) {
    if (!startTime) startTime = timestamp;
    var progress = Math.min((timestamp - startTime) / duration, 1);
    var current = Math.floor(start + diff * progress);
    el.textContent = fmtNum(current) + suffix;
    if (progress < 1) {
      requestAnimationFrame(step);
    }
  }

  if (diff === 0) {
    el.textContent = fmtNum(end) + suffix;
    return;
  }
  requestAnimationFrame(step);
}

// ── SVG Pipeline Visualization ──────────────────────────────────
function renderPipelineSVG(pipeline) {
  var stagesDone = pipeline.stagesDone || [];
  var currentStage = pipeline.stage || "";
  var failed = pipeline.status === "failed";

  var nodeSpacing = 80;
  var nodeR = 14;
  var svgWidth = STAGES.length * nodeSpacing + 40;
  var svgHeight = 72;
  var yCenter = 28;
  var yLabel = 60;

  var svg =
    '<svg class="pipeline-svg" viewBox="0 0 ' +
    svgWidth +
    " " +
    svgHeight +
    '" width="100%" height="' +
    svgHeight +
    '" xmlns="http://www.w3.org/2000/svg">';

  // Connecting lines
  for (var i = 0; i < STAGES.length - 1; i++) {
    var x1 = 20 + i * nodeSpacing + nodeR;
    var x2 = 20 + (i + 1) * nodeSpacing - nodeR;
    var isDone = stagesDone.indexOf(STAGES[i]) !== -1;
    var lineColor = isDone ? "#4ade80" : "#1a3a6a";
    var dashAttr = isDone ? "" : ' stroke-dasharray="4,3"';
    svg +=
      '<line x1="' +
      x1 +
      '" y1="' +
      yCenter +
      '" x2="' +
      x2 +
      '" y2="' +
      yCenter +
      '" stroke="' +
      lineColor +
      '" stroke-width="2"' +
      dashAttr +
      "/>";
  }

  // Stage nodes
  for (var i = 0; i < STAGES.length; i++) {
    var s = STAGES[i];
    var cx = 20 + i * nodeSpacing;
    var isDone = stagesDone.indexOf(s) !== -1;
    var isActive = s === currentStage;
    var isFailed = failed && isActive;

    var fillColor = "#0d1f3c";
    var strokeColor = "#1a3a6a";
    var textColor = "#5a6d8a";
    var extra = "";

    if (isDone) {
      fillColor = "#4ade80";
      strokeColor = "#4ade80";
      textColor = "#060a14";
    } else if (isFailed) {
      fillColor = "#f43f5e";
      strokeColor = "#f43f5e";
      textColor = "#fff";
    } else if (isActive) {
      fillColor = "#00d4ff";
      strokeColor = "#00d4ff";
      textColor = "#060a14";
      extra = ' class="stage-node-active"';
    }

    // Glow filter for active
    if (isActive && !isFailed) {
      svg +=
        '<circle cx="' +
        cx +
        '" cy="' +
        yCenter +
        '" r="' +
        (nodeR + 4) +
        '" fill="none" stroke="' +
        strokeColor +
        '" stroke-width="1" opacity="0.3"' +
        extra +
        ">" +
        '<animate attributeName="r" values="' +
        (nodeR + 2) +
        ";" +
        (nodeR + 6) +
        ";" +
        (nodeR + 2) +
        '" dur="2s" repeatCount="indefinite"/>' +
        '<animate attributeName="opacity" values="0.3;0.1;0.3" dur="2s" repeatCount="indefinite"/>' +
        "</circle>";
    }

    svg +=
      '<circle cx="' +
      cx +
      '" cy="' +
      yCenter +
      '" r="' +
      nodeR +
      '" fill="' +
      fillColor +
      '" stroke="' +
      strokeColor +
      '" stroke-width="2"/>';
    svg +=
      '<text x="' +
      cx +
      '" y="' +
      (yCenter + 4) +
      '" text-anchor="middle" fill="' +
      textColor +
      '" font-family="\'JetBrains Mono\', monospace" font-size="8" font-weight="600">' +
      STAGE_SHORT[s] +
      "</text>";
    svg +=
      '<text x="' +
      cx +
      '" y="' +
      yLabel +
      '" text-anchor="middle" fill="#5a6d8a" font-family="\'JetBrains Mono\', monospace" font-size="7">' +
      escapeHtml(s === "compound_quality" ? "quality" : s) +
      "</text>";
  }

  svg += "</svg>";
  return svg;
}

// ── SVG Donut Chart ─────────────────────────────────────────────
function renderSVGDonut(rate) {
  var size = 120;
  var strokeW = 12;
  var r = (size - strokeW) / 2;
  var c = Math.PI * 2 * r;
  var pct = Math.max(0, Math.min(100, rate));
  var offset = c - (pct / 100) * c;

  var svg =
    '<svg class="svg-donut" width="' +
    size +
    '" height="' +
    size +
    '" viewBox="0 0 ' +
    size +
    " " +
    size +
    '">';
  svg +=
    '<defs><linearGradient id="donut-grad" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" stop-color="#00d4ff"/><stop offset="100%" stop-color="#7c3aed"/></linearGradient></defs>';
  // Background track
  svg +=
    '<circle cx="' +
    size / 2 +
    '" cy="' +
    size / 2 +
    '" r="' +
    r +
    '" fill="none" stroke="#0d1f3c" stroke-width="' +
    strokeW +
    '"/>';
  // Foreground arc
  svg +=
    '<circle cx="' +
    size / 2 +
    '" cy="' +
    size / 2 +
    '" r="' +
    r +
    '" fill="none" stroke="url(#donut-grad)" stroke-width="' +
    strokeW +
    '" stroke-linecap="round" stroke-dasharray="' +
    c +
    '" stroke-dashoffset="' +
    offset +
    '" transform="rotate(-90 ' +
    size / 2 +
    " " +
    size / 2 +
    ')" style="transition: stroke-dashoffset 0.8s ease"/>';
  // Center text
  svg +=
    '<text x="' +
    size / 2 +
    '" y="' +
    (size / 2 + 8) +
    '" text-anchor="middle" fill="#e8ecf4" font-family="\'Instrument Serif\', serif" font-size="24">' +
    pct.toFixed(1) +
    "%</text>";
  svg += "</svg>";
  return svg;
}

// ── SVG Bar Chart ───────────────────────────────────────────────
function renderSVGBarChart(dailyCounts) {
  if (!dailyCounts || dailyCounts.length === 0) return "";

  var chartW = 700;
  var chartH = 100;
  var barGap = 4;
  var barW = Math.max(
    8,
    (chartW - (dailyCounts.length - 1) * barGap) / dailyCounts.length,
  );
  var maxCount = 0;
  for (var i = 0; i < dailyCounts.length; i++) {
    var total = (dailyCounts[i].completed || 0) + (dailyCounts[i].failed || 0);
    if (total > maxCount) maxCount = total;
  }
  if (maxCount === 0) maxCount = 1;

  var svg =
    '<svg class="svg-bar-chart" viewBox="0 0 ' +
    chartW +
    " " +
    (chartH + 20) +
    '" width="100%" height="' +
    (chartH + 20) +
    '">';

  for (var i = 0; i < dailyCounts.length; i++) {
    var day = dailyCounts[i];
    var completed = day.completed || 0;
    var failed = day.failed || 0;
    var x = i * (barW + barGap);
    var cH = (completed / maxCount) * chartH;
    var fH = (failed / maxCount) * chartH;

    if (cH > 0) {
      svg +=
        '<rect x="' +
        x +
        '" y="' +
        (chartH - cH - fH) +
        '" width="' +
        barW +
        '" height="' +
        cH +
        '" rx="3" fill="#4ade80" opacity="0.85"/>';
    }
    if (fH > 0) {
      svg +=
        '<rect x="' +
        x +
        '" y="' +
        (chartH - fH) +
        '" width="' +
        barW +
        '" height="' +
        fH +
        '" rx="3" fill="#f43f5e" opacity="0.85"/>';
    }
    if (cH === 0 && fH === 0) {
      svg +=
        '<rect x="' +
        x +
        '" y="' +
        (chartH - 1) +
        '" width="' +
        barW +
        '" height="1" fill="#0d1f3c"/>';
    }

    // Date label
    var dateStr = day.date || "";
    var parts = dateStr.split("-");
    var label = parts.length >= 3 ? parts[1] + "/" + parts[2] : dateStr;
    svg +=
      '<text x="' +
      (x + barW / 2) +
      '" y="' +
      (chartH + 14) +
      '" text-anchor="middle" fill="#5a6d8a" font-family="\'JetBrains Mono\', monospace" font-size="8">' +
      escapeHtml(label) +
      "</text>";
  }

  svg += "</svg>";
  return svg;
}

// ── DORA Grade Badges ───────────────────────────────────────────
function renderDoraGrades(dora) {
  if (!dora) return "";

  var metrics = [
    { key: "deploy_freq", label: "Deploy Frequency" },
    { key: "lead_time", label: "Lead Time" },
    { key: "cfr", label: "Change Failure Rate" },
    { key: "mttr", label: "Mean Time to Recovery" },
  ];

  var html = '<div class="dora-grades-row">';
  for (var i = 0; i < metrics.length; i++) {
    var m = metrics[i];
    var d = dora[m.key];
    if (!d) continue;
    var grade = (d.grade || "N/A").toLowerCase();
    var gradeClass = "dora-" + grade;
    html +=
      '<div class="dora-grade-card">' +
      '<span class="dora-grade-label">' +
      escapeHtml(m.label) +
      "</span>" +
      '<span class="dora-badge ' +
      gradeClass +
      '">' +
      escapeHtml(d.grade || "N/A") +
      "</span>" +
      '<span class="dora-grade-value">' +
      (d.value != null ? d.value.toFixed(1) : "\u2014") +
      " " +
      escapeHtml(d.unit || "") +
      "</span>" +
      "</div>";
  }
  html += "</div>";
  return html;
}

// ── User Menu ───────────────────────────────────────────────────
var currentUser = null;

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
  var validTabs = [
    "overview",
    "agents",
    "pipelines",
    "timeline",
    "activity",
    "metrics",
    "machines",
    "insights",
    "team",
  ];
  if (validTabs.indexOf(hash) !== -1) {
    switchTab(hash);
  }

  window.addEventListener("hashchange", function () {
    var hash = location.hash.replace("#", "");
    if (validTabs.indexOf(hash) !== -1 && hash !== activeTab) {
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
  if (tab === "insights") {
    fetchInsightsData();
  }
  if (tab === "machines") {
    fetchMachinesTab();
  }
  if (tab === "team") {
    fetchTeamData();
    if (teamRefreshTimer) clearInterval(teamRefreshTimer);
    teamRefreshTimer = setInterval(fetchTeamData, 10000);
  } else {
    if (teamRefreshTimer) {
      clearInterval(teamRefreshTimer);
      teamRefreshTimer = null;
    }
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
    case "machines":
      // Machines use cached data; don't re-fetch on every WS push
      if (machinesCache) renderMachinesTab(machinesCache);
      break;
    case "insights":
      // Insights use cached data; don't re-fetch on every WS push
      if (insightsCache) renderInsightsTab(insightsCache);
      break;
    case "team":
      // Team uses cached data; don't re-fetch on every WS push
      if (teamCache) {
        renderTeamGrid(teamCache);
        renderTeamStats(teamCache);
      }
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
  var activeEl = document.getElementById("stat-active");
  if (firstRender && active > 0) {
    animateValue(activeEl, 0, active, 600, " / " + fmtNum(max));
  } else {
    activeEl.textContent = fmtNum(active) + " / " + fmtNum(max);
  }
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
  var completedEl = document.getElementById("stat-completed");
  if (firstRender && completed > 0) {
    animateValue(completedEl, 0, completed, 800, "");
  } else {
    completedEl.textContent = fmtNum(completed);
  }
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
      '<div class="pipeline-svg-wrap">' +
      renderPipelineSVG(p) +
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
    var costEst =
      q.estimated_cost != null
        ? ' <span class="queue-cost-est">~$' +
          q.estimated_cost.toFixed(2) +
          "</span>"
        : "";
    html +=
      '<div class="queue-row" data-queue-idx="' +
      i +
      '">' +
      '<span class="queue-issue">#' +
      q.issue +
      "</span>" +
      '<span class="queue-title-text">' +
      escapeHtml(q.title) +
      "</span>" +
      '<span class="queue-score">' +
      (q.score != null ? q.score : "\u2014") +
      "</span>" +
      costEst +
      "</div>";
    if (q.factors) {
      html +=
        '<div class="queue-scoring-detail" id="queue-detail-' +
        i +
        '" style="display:none">';
      html += renderScoringFactors(q.factors);
      html += "</div>";
    }
  }
  container.innerHTML = html;

  // Click handlers for expandable queue items
  var rows = container.querySelectorAll(".queue-row");
  for (var i = 0; i < rows.length; i++) {
    rows[i].addEventListener("click", function () {
      var idx = this.getAttribute("data-queue-idx");
      var detail = document.getElementById("queue-detail-" + idx);
      if (detail) {
        detail.style.display = detail.style.display === "none" ? "" : "none";
      }
    });
  }
}

function renderScoringFactors(factors) {
  if (!factors) return "";
  var keys = [
    "complexity",
    "impact",
    "priority",
    "age",
    "dependency",
    "memory",
  ];
  var html = '<div class="scoring-factors">';
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    var val = factors[k] != null ? factors[k] : 0;
    var pct = Math.max(0, Math.min(100, val));
    html +=
      '<div class="scoring-factor-row">' +
      '<span class="scoring-factor-label">' +
      escapeHtml(k) +
      "</span>" +
      '<div class="scoring-factor-track">' +
      '<div class="scoring-factor-fill" style="width:' +
      pct +
      '%"></div>' +
      "</div>" +
      '<span class="scoring-factor-val">' +
      pct +
      "</span>" +
      "</div>";
  }
  html += "</div>";
  return html;
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
      '<tr><td colspan="7" class="empty-state"><p>No pipelines match filter</p></td></tr>';
    return;
  }

  var html = "";
  for (var i = 0; i < filtered.length; i++) {
    var r = filtered[i];
    var selectedClass = selectedPipelineIssue == r.issue ? " row-selected" : "";
    var isChecked = selectedIssues[r.issue] ? " checked" : "";
    html +=
      '<tr class="pipeline-row' +
      selectedClass +
      '" data-issue="' +
      r.issue +
      '">' +
      '<td class="col-checkbox"><input type="checkbox" class="pipeline-checkbox" data-issue="' +
      r.issue +
      '"' +
      isChecked +
      "></td>" +
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

  // Checkbox handlers
  var checkboxes = tbody.querySelectorAll(".pipeline-checkbox");
  for (var i = 0; i < checkboxes.length; i++) {
    checkboxes[i].addEventListener("change", function (e) {
      e.stopPropagation();
      var iss = this.getAttribute("data-issue");
      if (this.checked) {
        selectedIssues[iss] = true;
      } else {
        delete selectedIssues[iss];
      }
      updateBulkToolbar();
    });
    checkboxes[i].addEventListener("click", function (e) {
      e.stopPropagation();
    });
  }

  // Select-all checkbox
  var selectAll = document.getElementById("select-all-pipelines");
  if (selectAll) {
    selectAll.addEventListener("change", function () {
      var cbs = tbody.querySelectorAll(".pipeline-checkbox");
      for (var j = 0; j < cbs.length; j++) {
        cbs[j].checked = this.checked;
        var iss = cbs[j].getAttribute("data-issue");
        if (this.checked) {
          selectedIssues[iss] = true;
        } else {
          delete selectedIssues[iss];
        }
      }
      updateBulkToolbar();
    });
  }

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
  var issue = detail.issue || selectedPipelineIssue;

  // GitHub status banner at top
  html +=
    '<div id="github-status-' + issue + '" class="github-status-banner"></div>';

  // SVG pipeline visualization at top of detail
  html +=
    '<div class="pipeline-svg-wrap">' +
    renderPipelineSVG({
      stagesDone: (detail.stageHistory || []).map(function (h) {
        return h.stage;
      }),
      stage: detail.stage,
      status: detail.status || "",
    }) +
    "</div>";

  // Error highlight for failed stages
  if (detail.status === "failed" || detail.error) {
    html +=
      '<div id="error-highlight-' +
      issue +
      '" class="error-highlight-box"></div>';
  }

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

  // Failure pattern match box
  if (detail.failurePatterns && detail.failurePatterns.length > 0) {
    html +=
      '<div class="detail-section pattern-match-box">' +
      '<div class="detail-section-label">MATCHED FAILURE PATTERNS</div>';
    for (var fp = 0; fp < detail.failurePatterns.length; fp++) {
      var pat = detail.failurePatterns[fp];
      html +=
        '<div class="pattern-match-item">' +
        '<span class="pattern-match-desc">' +
        escapeHtml(pat.description || pat.pattern || "") +
        "</span>" +
        (pat.fix
          ? '<span class="pattern-match-fix">Fix: ' +
            escapeHtml(pat.fix) +
            "</span>"
          : "") +
        "</div>";
    }
    html += "</div>";
  }

  // Artifact viewer tabs (replaces static plan/design/dod)
  html += renderArtifactViewer(issue, detail);

  body.innerHTML = html;

  // Async: fetch GitHub status
  if (issue) {
    renderGitHubStatus(issue);
  }

  // Async: fetch error highlight for failed pipelines
  if (issue && (detail.status === "failed" || detail.error)) {
    renderErrorHighlight(issue);
  }

  // Setup artifact tab clicks
  setupArtifactTabs(issue);
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
  // Success rate — SVG donut
  var rate = data.success_rate != null ? data.success_rate : 0;
  var donutWrap = document.getElementById("metric-donut-wrap");
  if (donutWrap) {
    donutWrap.innerHTML = renderSVGDonut(rate);
  } else {
    // Fallback: use the CSS donut
    var donut = document.getElementById("metric-donut");
    if (donut) {
      donut.style.setProperty("--pct", rate + "%");
      var rateEl = document.getElementById("metric-success-rate");
      if (rateEl) rateEl.textContent = rate.toFixed(1) + "%";
    }
  }

  // Avg duration
  var avgDurEl = document.getElementById("metric-avg-duration");
  if (avgDurEl) {
    avgDurEl.textContent = formatDuration(data.avg_duration_s);
  }

  // Throughput
  var tp = data.throughput_per_hour != null ? data.throughput_per_hour : 0;
  var tpEl = document.getElementById("metric-throughput");
  if (tpEl) tpEl.textContent = tp.toFixed(2);

  // Totals
  var totalCompleted = data.total_completed != null ? data.total_completed : 0;
  var totalFailed = data.total_failed != null ? data.total_failed : 0;
  var tcEl = document.getElementById("metric-total-completed");
  if (tcEl) {
    if (firstRender && totalCompleted > 0) {
      animateValue(tcEl, 0, totalCompleted, 800, "");
    } else {
      tcEl.textContent = fmtNum(totalCompleted);
    }
  }
  var failedEl = document.getElementById("metric-total-failed");
  if (failedEl) {
    failedEl.textContent = fmtNum(totalFailed) + " failed";
    failedEl.style.color = totalFailed > 0 ? "var(--rose)" : "";
  }

  // Stage duration breakdown — SVG bars
  renderStageBreakdown(data.stage_durations || {});

  // Daily chart — SVG
  renderDailyChart(data.daily_counts || []);

  // DORA grades
  var doraContainer = document.getElementById("dora-grades-container");
  if (doraContainer && data.dora_grades) {
    doraContainer.innerHTML = renderDoraGrades(data.dora_grades);
    doraContainer.style.display = "";
  } else if (doraContainer) {
    doraContainer.style.display = "none";
  }

  // Phase 2: Cost breakdown and trend
  var costBreakdownEl = document.getElementById("cost-breakdown-container");
  if (costBreakdownEl) {
    renderCostBreakdown();
  }
  var costTrendEl = document.getElementById("cost-trend-container");
  if (costTrendEl) {
    renderCostTrend();
  }

  // Phase 2: DORA trend sparklines
  var doraTrendEl = document.getElementById("dora-trend-container");
  if (doraTrendEl) {
    renderDoraTrend();
  }

  // Phase 4: Stage performance, bottleneck, throughput, capacity
  var stagePerfEl = document.getElementById("stage-performance-container");
  if (stagePerfEl) {
    renderStagePerformance();
  }
  var bottleneckEl = document.getElementById("bottleneck-alert-container");
  if (bottleneckEl) {
    renderBottleneckAlert();
  }
  var throughputEl = document.getElementById("throughput-trend-container");
  if (throughputEl) {
    renderThroughputTrend();
  }
  var capacityEl = document.getElementById("capacity-forecast-container");
  if (capacityEl) {
    renderCapacityForecast();
  }
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

  container.innerHTML = renderSVGBarChart(dailyCounts);
}

// ══════════════════════════════════════════════════════════════════
// AGENTS TAB
// ══════════════════════════════════════════════════════════════════

function renderAgentsTab(data) {
  var container = document.getElementById("agents-grid");
  var agents = data.agents || [];

  if (agents.length === 0) {
    container.innerHTML =
      '<div class="empty-state">' +
      '<svg class="empty-icon" viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5">' +
      '<path d="M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 00-3-3.87"/><path d="M16 3.13a4 4 0 010 7.75"/>' +
      "</svg>" +
      "<p>No active agents. Start a pipeline to see agents here.</p>" +
      "</div>";
    return;
  }

  var html = "";
  for (var i = 0; i < agents.length; i++) {
    var a = agents[i];
    var presenceClass = a.status || "dead";
    var elapsed = a.elapsed_s ? formatDuration(a.elapsed_s) : "\u2014";
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
      escapeHtml(a.stage || "\u2014") +
      "</span>" +
      '<span class="agent-iteration">iter ' +
      (a.iteration || 0) +
      "</span>" +
      "</div>" +
      '<div class="agent-activity">' +
      escapeHtml(a.activity || "\u2014") +
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
      if (!seg.start) continue;
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
        " \u2014 " +
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
  // Support both select and segmented control
  var rangeEl = document.getElementById("timeline-range");
  if (rangeEl) {
    rangeEl.addEventListener("change", function () {
      fetchTimeline();
    });
  }

  // Segmented control buttons
  var segBtns = document.querySelectorAll(".timeline-seg-btn");
  for (var i = 0; i < segBtns.length; i++) {
    segBtns[i].addEventListener("click", function () {
      var val = this.getAttribute("data-value");
      // Update hidden select
      if (rangeEl) rangeEl.value = val;
      // Update active state
      var siblings = document.querySelectorAll(".timeline-seg-btn");
      for (var j = 0; j < siblings.length; j++)
        siblings[j].classList.remove("active");
      this.classList.add("active");
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
  var statusClass =
    pct >= 80 ? "cost-over" : pct >= 60 ? "cost-warn" : "cost-ok";

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
      escapeHtml(m.host || "\u2014") +
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

// ── Machines Tab Functions ────────────────────────────────────────

function fetchMachinesTab() {
  fetch("/api/machines")
    .then(function (r) {
      return r.json();
    })
    .then(function (data) {
      machinesCache = data;
      renderMachinesTab(data);
    })
    .catch(function (err) {
      console.error("Failed to fetch machines:", err);
    });
  fetchJoinTokens();
}

function fetchJoinTokens() {
  fetch("/api/join-tokens")
    .then(function (r) {
      return r.json();
    })
    .then(function (data) {
      joinTokensCache = data;
      renderJoinTokens(data || []);
    })
    .catch(function () {
      /* ignore */
    });
}

function renderMachinesTab(machines) {
  var summaryEl = document.getElementById("machines-summary");
  var gridEl = document.getElementById("machines-tab-grid");
  if (!summaryEl || !gridEl) return;

  if (!machines || machines.length === 0) {
    summaryEl.innerHTML = "";
    gridEl.innerHTML =
      '<div class="empty-state"><p>No machines registered. Click <strong>+ Add Machine</strong> to get started.</p></div>';
    return;
  }

  summaryEl.innerHTML = renderMachineSummary(machines);

  var cardsHtml = "";
  for (var i = 0; i < machines.length; i++) {
    cardsHtml += renderMachineCard(machines[i]);
  }
  gridEl.innerHTML = cardsHtml;
}

function renderMachineSummary(machines) {
  var totalMachines = machines.length;
  var totalMaxWorkers = 0;
  var totalActiveWorkers = 0;
  var onlineCount = 0;
  for (var i = 0; i < machines.length; i++) {
    totalMaxWorkers += machines[i].max_workers || 0;
    totalActiveWorkers += machines[i].active_workers || 0;
    if (machines[i].status === "online") onlineCount++;
  }

  return (
    '<div class="machines-summary-card">' +
    '<div class="stat-value">' +
    totalMachines +
    "</div>" +
    '<div class="stat-label">Total Machines</div>' +
    "</div>" +
    '<div class="machines-summary-card">' +
    '<div class="stat-value">' +
    onlineCount +
    "</div>" +
    '<div class="stat-label">Online</div>' +
    "</div>" +
    '<div class="machines-summary-card">' +
    '<div class="stat-value">' +
    totalActiveWorkers +
    " / " +
    totalMaxWorkers +
    "</div>" +
    '<div class="stat-label">Active / Max Workers</div>' +
    "</div>"
  );
}

function renderMachineCard(machine) {
  var name = machine.name || "";
  var host = machine.host || "\u2014";
  var role = machine.role || "worker";
  var status = machine.status || "offline";
  var maxWorkers = machine.max_workers || 4;
  var activeWorkers = machine.active_workers || 0;
  var health = machine.health || {};
  var daemonRunning = health.daemon_running || false;
  var heartbeatCount = health.heartbeat_count || 0;
  var lastHbAge = health.last_heartbeat_s_ago;
  var lastHbText = "\u2014";
  if (typeof lastHbAge === "number" && lastHbAge < 9999) {
    if (lastHbAge < 60) lastHbText = lastHbAge + "s ago";
    else if (lastHbAge < 3600)
      lastHbText = Math.floor(lastHbAge / 60) + "m ago";
    else lastHbText = Math.floor(lastHbAge / 3600) + "h ago";
  }

  return (
    '<div class="machine-card" id="machine-card-' +
    escapeHtml(name) +
    '">' +
    '<div class="machine-card-header">' +
    '<span class="presence-dot ' +
    status +
    '"></span>' +
    '<span class="machine-name">' +
    escapeHtml(name) +
    "</span>" +
    '<span class="machine-role">' +
    escapeHtml(role) +
    "</span>" +
    "</div>" +
    '<div class="machine-host">' +
    escapeHtml(host) +
    "</div>" +
    '<div class="machine-workers-section">' +
    '<div class="machine-workers-label-row">' +
    "<span>Workers</span>" +
    '<span class="workers-count">' +
    activeWorkers +
    " / " +
    maxWorkers +
    "</span>" +
    "</div>" +
    '<input type="range" class="workers-slider" min="1" max="64" value="' +
    maxWorkers +
    '"' +
    " oninput=\"updateWorkerCount('" +
    escapeHtml(name) +
    "', this.value)\"" +
    ' title="Max workers" />' +
    "</div>" +
    '<div class="machine-health">' +
    '<div class="machine-health-row">' +
    '<span class="health-label">Daemon</span>' +
    '<span class="health-status ' +
    (daemonRunning ? "running" : "stopped") +
    '">' +
    (daemonRunning ? "Running" : "Stopped") +
    "</span>" +
    "</div>" +
    '<div class="machine-health-row">' +
    '<span class="health-label">Heartbeats</span>' +
    '<span class="health-value">' +
    heartbeatCount +
    "</span>" +
    "</div>" +
    '<div class="machine-health-row">' +
    '<span class="health-label">Last heartbeat</span>' +
    '<span class="health-value">' +
    lastHbText +
    "</span>" +
    "</div>" +
    "</div>" +
    '<div class="machine-card-actions">' +
    '<button class="machine-action-btn" onclick="machineHealthCheck(\'' +
    escapeHtml(name) +
    "')\">Check</button>" +
    '<button class="machine-action-btn danger" onclick="confirmMachineRemove(\'' +
    escapeHtml(name) +
    "')\">Remove</button>" +
    "</div>" +
    "</div>"
  );
}

function renderJoinTokens(tokens) {
  var section = document.getElementById("join-tokens-section");
  var list = document.getElementById("join-tokens-list");
  if (!section || !list) return;

  if (!tokens || tokens.length === 0) {
    section.style.display = "none";
    return;
  }

  section.style.display = "";
  var html = "";
  for (var i = 0; i < tokens.length; i++) {
    var t = tokens[i];
    var label = t.label || "Unlabeled";
    var created = t.created_at
      ? new Date(t.created_at).toLocaleDateString()
      : "\u2014";
    var used = t.used ? "Claimed" : "Active";
    var usedClass = t.used ? "c-amber" : "c-green";
    html +=
      '<div class="join-token-row">' +
      '<span class="join-token-label">' +
      escapeHtml(label) +
      "</span>" +
      '<span class="join-token-created">' +
      created +
      "</span>" +
      '<span class="join-token-status ' +
      usedClass +
      '">' +
      used +
      "</span>" +
      "</div>";
  }
  list.innerHTML = html;
}

function openAddMachineModal() {
  document.getElementById("add-machine-modal").style.display = "flex";
  document.getElementById("machine-name").value = "";
  document.getElementById("machine-host").value = "";
  document.getElementById("machine-ssh-user").value = "";
  document.getElementById("machine-path").value = "";
  document.getElementById("machine-workers").value = "4";
  document.getElementById("machine-role").value = "worker";
  document.getElementById("machine-modal-error").style.display = "none";
}

function closeAddMachineModal() {
  document.getElementById("add-machine-modal").style.display = "none";
}

function submitAddMachine() {
  var name = document.getElementById("machine-name").value.trim();
  var host = document.getElementById("machine-host").value.trim();
  var sshUser = document.getElementById("machine-ssh-user").value.trim();
  var swPath = document.getElementById("machine-path").value.trim();
  var maxWorkers =
    parseInt(document.getElementById("machine-workers").value, 10) || 4;
  var role = document.getElementById("machine-role").value;
  var errEl = document.getElementById("machine-modal-error");

  if (!name || !host) {
    errEl.textContent = "Name and host are required";
    errEl.style.display = "";
    return;
  }

  var body = { name: name, host: host, role: role, max_workers: maxWorkers };
  if (sshUser) body.ssh_user = sshUser;
  if (swPath) body.shipwright_path = swPath;

  fetch("/api/machines", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
    .then(function (r) {
      if (!r.ok)
        return r.json().then(function (d) {
          throw new Error(d.error || "Failed");
        });
      return r.json();
    })
    .then(function () {
      closeAddMachineModal();
      fetchMachinesTab();
    })
    .catch(function (err) {
      errEl.textContent = err.message || "Failed to register machine";
      errEl.style.display = "";
    });
}

function updateWorkerCount(name, value) {
  if (workerUpdateTimer) clearTimeout(workerUpdateTimer);
  workerUpdateTimer = setTimeout(function () {
    fetch("/api/machines/" + encodeURIComponent(name), {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ max_workers: parseInt(value, 10) }),
    })
      .then(function (r) {
        return r.json();
      })
      .then(function (updated) {
        // Update the count display in the card
        var card = document.getElementById("machine-card-" + name);
        if (card) {
          var countEl = card.querySelector(".workers-count");
          if (countEl) {
            countEl.textContent =
              (updated.active_workers || 0) +
              " / " +
              (updated.max_workers || value);
          }
        }
      })
      .catch(function (err) {
        console.error("Worker update failed:", err);
      });
  }, 500);
}

function machineHealthCheck(name) {
  var card = document.getElementById("machine-card-" + name);
  if (card) {
    var checkBtn = card.querySelector(".machine-action-btn");
    if (checkBtn) {
      checkBtn.textContent = "Checking\u2026";
      checkBtn.disabled = true;
    }
  }

  fetch("/api/machines/" + encodeURIComponent(name) + "/health-check", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  })
    .then(function (r) {
      return r.json();
    })
    .then(function (result) {
      if (result.machine && card) {
        var m = result.machine;
        var health = m.health || {};
        var daemonRunning = health.daemon_running || false;
        var heartbeatCount = health.heartbeat_count || 0;
        var lastHbAge = health.last_heartbeat_s_ago;
        var lastHbText = "\u2014";
        if (typeof lastHbAge === "number" && lastHbAge < 9999) {
          if (lastHbAge < 60) lastHbText = lastHbAge + "s ago";
          else if (lastHbAge < 3600)
            lastHbText = Math.floor(lastHbAge / 60) + "m ago";
          else lastHbText = Math.floor(lastHbAge / 3600) + "h ago";
        }

        var healthRows = card.querySelectorAll(".machine-health-row");
        if (healthRows.length >= 3) {
          healthRows[0].querySelector(".health-status").className =
            "health-status " + (daemonRunning ? "running" : "stopped");
          healthRows[0].querySelector(".health-status").textContent =
            daemonRunning ? "Running" : "Stopped";
          healthRows[1].querySelector(".health-value").textContent =
            heartbeatCount;
          healthRows[2].querySelector(".health-value").textContent = lastHbText;
        }

        // Update presence dot
        var dot = card.querySelector(".presence-dot");
        if (dot) {
          dot.className = "presence-dot " + (m.status || "offline");
        }
      }
      // Reset button
      if (card) {
        var btn = card.querySelector(".machine-action-btn");
        if (btn) {
          btn.textContent = "Check";
          btn.disabled = false;
        }
      }
    })
    .catch(function (err) {
      console.error("Health check failed:", err);
      if (card) {
        var btn = card.querySelector(".machine-action-btn");
        if (btn) {
          btn.textContent = "Check";
          btn.disabled = false;
        }
      }
    });
}

function confirmMachineRemove(name) {
  removeMachineTarget = name;
  document.getElementById("remove-machine-name").textContent = name;
  document.getElementById("remove-stop-daemon").checked = false;
  document.getElementById("remove-machine-modal").style.display = "flex";
}

function executeRemoveMachine() {
  if (!removeMachineTarget) return;
  var name = removeMachineTarget;

  fetch("/api/machines/" + encodeURIComponent(name), {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
  })
    .then(function (r) {
      if (!r.ok)
        return r.json().then(function (d) {
          throw new Error(d.error || "Failed");
        });
      return r.json();
    })
    .then(function () {
      document.getElementById("remove-machine-modal").style.display = "none";
      removeMachineTarget = null;
      fetchMachinesTab();
    })
    .catch(function (err) {
      console.error("Remove machine failed:", err);
      document.getElementById("remove-machine-modal").style.display = "none";
      removeMachineTarget = null;
    });
}

function openJoinLinkModal() {
  document.getElementById("join-link-modal").style.display = "flex";
  document.getElementById("join-label").value = "";
  document.getElementById("join-workers").value = "4";
  document.getElementById("join-command-display").style.display = "none";
  document.getElementById("join-command-text").textContent = "";
}

function closeJoinLinkModal() {
  document.getElementById("join-link-modal").style.display = "none";
}

function generateJoinLink() {
  var label = document.getElementById("join-label").value.trim();
  var maxWorkers =
    parseInt(document.getElementById("join-workers").value, 10) || 4;
  var generateBtn = document.getElementById("join-modal-generate");
  generateBtn.textContent = "Generating\u2026";
  generateBtn.disabled = true;

  fetch("/api/join-token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ label: label, max_workers: maxWorkers }),
  })
    .then(function (r) {
      return r.json();
    })
    .then(function (data) {
      document.getElementById("join-command-text").textContent =
        data.join_cmd || "";
      document.getElementById("join-command-display").style.display = "";
      generateBtn.textContent = "Generate";
      generateBtn.disabled = false;
      // Refresh token list
      fetchJoinTokens();
    })
    .catch(function (err) {
      console.error("Generate join link failed:", err);
      generateBtn.textContent = "Generate";
      generateBtn.disabled = false;
    });
}

function copyJoinCommand() {
  var text = document.getElementById("join-command-text").textContent;
  if (text && navigator.clipboard) {
    navigator.clipboard.writeText(text).then(function () {
      var btn = document.getElementById("join-copy-btn");
      btn.textContent = "Copied!";
      setTimeout(function () {
        btn.textContent = "Copy";
      }, 2000);
    });
  }
}

function setupMachinesTab() {
  var addBtn = document.getElementById("btn-add-machine");
  if (addBtn) addBtn.addEventListener("click", openAddMachineModal);

  var joinBtn = document.getElementById("btn-join-link");
  if (joinBtn) joinBtn.addEventListener("click", openJoinLinkModal);

  var machineModalClose = document.getElementById("machine-modal-close");
  if (machineModalClose)
    machineModalClose.addEventListener("click", closeAddMachineModal);

  var machineModalCancel = document.getElementById("machine-modal-cancel");
  if (machineModalCancel)
    machineModalCancel.addEventListener("click", closeAddMachineModal);

  var machineModalSubmit = document.getElementById("machine-modal-submit");
  if (machineModalSubmit)
    machineModalSubmit.addEventListener("click", submitAddMachine);

  var joinModalClose = document.getElementById("join-modal-close");
  if (joinModalClose)
    joinModalClose.addEventListener("click", closeJoinLinkModal);

  var joinModalCancel = document.getElementById("join-modal-cancel");
  if (joinModalCancel)
    joinModalCancel.addEventListener("click", closeJoinLinkModal);

  var joinModalGenerate = document.getElementById("join-modal-generate");
  if (joinModalGenerate)
    joinModalGenerate.addEventListener("click", generateJoinLink);

  var joinCopyBtn = document.getElementById("join-copy-btn");
  if (joinCopyBtn) joinCopyBtn.addEventListener("click", copyJoinCommand);

  var removeModalClose = document.getElementById("remove-modal-close");
  if (removeModalClose)
    removeModalClose.addEventListener("click", function () {
      document.getElementById("remove-machine-modal").style.display = "none";
    });

  var removeModalCancel = document.getElementById("remove-modal-cancel");
  if (removeModalCancel)
    removeModalCancel.addEventListener("click", function () {
      document.getElementById("remove-machine-modal").style.display = "none";
    });

  var removeModalConfirm = document.getElementById("remove-modal-confirm");
  if (removeModalConfirm)
    removeModalConfirm.addEventListener("click", executeRemoveMachine);
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
// PHASE 1: ARTIFACT VIEWER, GITHUB STATUS, LOG VIEWER, ERROR HIGHLIGHT
// ══════════════════════════════════════════════════════════════════

function renderArtifactViewer(issue, detail) {
  var tabs = [
    { key: "plan", label: "Plan", content: detail.plan },
    { key: "design", label: "Design", content: detail.design },
    { key: "dod", label: "DoD", content: detail.dod },
    { key: "tests", label: "Tests", content: null },
    { key: "review", label: "Review", content: null },
    { key: "logs", label: "Logs", content: null },
  ];

  var html = '<div class="artifact-viewer">';
  html += '<div class="artifact-tabs">';
  for (var i = 0; i < tabs.length; i++) {
    var activeClass = i === 0 ? " active" : "";
    html +=
      '<button class="artifact-tab-btn' +
      activeClass +
      '" data-artifact="' +
      tabs[i].key +
      '" data-issue="' +
      issue +
      '">' +
      escapeHtml(tabs[i].label) +
      "</button>";
  }
  html += "</div>";

  html += '<div class="artifact-content" id="artifact-content-' + issue + '">';
  // Show plan by default if available
  if (detail.plan) {
    html +=
      '<div class="detail-plan-content">' +
      formatMarkdown(detail.plan) +
      "</div>";
  } else {
    html += '<div class="empty-state"><p>No plan data</p></div>';
  }
  html += "</div>";
  html += "</div>";
  return html;
}

function setupArtifactTabs(issue) {
  var btns = document.querySelectorAll(
    '.artifact-tab-btn[data-issue="' + issue + '"]',
  );
  for (var i = 0; i < btns.length; i++) {
    btns[i].addEventListener("click", function () {
      var artifact = this.getAttribute("data-artifact");
      var iss = this.getAttribute("data-issue");
      var siblings = document.querySelectorAll(
        '.artifact-tab-btn[data-issue="' + iss + '"]',
      );
      for (var j = 0; j < siblings.length; j++) {
        siblings[j].classList.remove("active");
      }
      this.classList.add("active");
      fetchArtifact(iss, artifact);
    });
  }
}

function fetchArtifact(issue, type) {
  var container = document.getElementById("artifact-content-" + issue);
  if (!container) return;
  container.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';

  // Check if we have inline data from detail
  if (pipelineDetail) {
    if (type === "plan" && pipelineDetail.plan) {
      container.innerHTML =
        '<div class="detail-plan-content">' +
        formatMarkdown(pipelineDetail.plan) +
        "</div>";
      return;
    }
    if (type === "design" && pipelineDetail.design) {
      container.innerHTML =
        '<div class="detail-plan-content">' +
        formatMarkdown(pipelineDetail.design) +
        "</div>";
      return;
    }
    if (type === "dod" && pipelineDetail.dod) {
      container.innerHTML =
        '<div class="detail-plan-content">' +
        formatMarkdown(pipelineDetail.dod) +
        "</div>";
      return;
    }
  }

  fetch(
    "/api/artifacts/" +
      encodeURIComponent(issue) +
      "/" +
      encodeURIComponent(type),
  )
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      if (type === "logs") {
        container.innerHTML = renderLogViewer(data.content || "");
      } else {
        container.innerHTML =
          '<div class="detail-plan-content">' +
          formatMarkdown(data.content || "") +
          "</div>";
      }
    })
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Not available: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function formatMarkdown(text) {
  if (!text) return "";
  var escaped = escapeHtml(text);
  // Headers → bold
  escaped = escaped.replace(/^#{1,3}\s+(.+)$/gm, function (_m, content) {
    return "<strong>" + content + "</strong>";
  });
  // Code blocks → monospace
  escaped = escaped.replace(/```[\s\S]*?```/g, function (block) {
    var inner = block.replace(/^```\w*\n?/, "").replace(/\n?```$/, "");
    return '<pre class="artifact-code">' + inner + "</pre>";
  });
  // Inline code
  escaped = escaped.replace(/`([^`]+)`/g, "<code>$1</code>");
  // Bullet lists
  escaped = escaped.replace(/^[-*]\s+(.+)$/gm, "<li>$1</li>");
  // Line breaks
  escaped = escaped.replace(/\n/g, "<br>");
  return escaped;
}

function renderGitHubStatus(issue) {
  var container = document.getElementById("github-status-" + issue);
  if (!container) return;

  fetch("/api/github/" + encodeURIComponent(issue))
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      if (!data.configured) {
        container.innerHTML = "";
        return;
      }
      var html = '<div class="github-banner">';
      // Issue state badge
      if (data.issue_state) {
        html +=
          '<span class="github-badge ' +
          escapeHtml(data.issue_state) +
          '">' +
          escapeHtml(data.issue_state) +
          "</span>";
      }
      // PR link
      if (data.pr_number) {
        html +=
          '<a class="github-link" href="' +
          escapeHtml(data.pr_url || "") +
          '" target="_blank">PR #' +
          data.pr_number +
          "</a>";
      }
      // CI checks
      if (data.checks && data.checks.length > 0) {
        html += '<span class="github-checks">';
        for (var c = 0; c < data.checks.length; c++) {
          var check = data.checks[c];
          var icon =
            check.status === "success"
              ? "\u2713"
              : check.status === "failure"
                ? "\u2717"
                : "\u25CF";
          var cls =
            check.status === "success"
              ? "github-badge success"
              : check.status === "failure"
                ? "github-badge failure"
                : "github-badge pending";
          html +=
            '<span class="' +
            cls +
            '" title="' +
            escapeHtml(check.name || "") +
            '">' +
            icon +
            "</span>";
        }
        html += "</span>";
      }
      html += "</div>";
      container.innerHTML = html;
    })
    .catch(function () {
      container.innerHTML = "";
    });
}

function renderLogViewer(content) {
  if (!content)
    return '<div class="empty-state"><p>No logs available</p></div>';
  // Strip ANSI escape codes
  var clean = content.replace(/\x1b\[[0-9;]*m/g, "");
  var lines = clean.split("\n");
  var html = '<div class="log-viewer">';
  for (var i = 0; i < lines.length; i++) {
    var lineNum = i + 1;
    var lineClass = "";
    var lower = lines[i].toLowerCase();
    if (lower.indexOf("error") !== -1 || lower.indexOf("fail") !== -1) {
      lineClass = " log-line-error";
    }
    html +=
      '<div class="log-line' +
      lineClass +
      '">' +
      '<span class="log-line-num">' +
      lineNum +
      "</span>" +
      '<span class="log-line-text">' +
      escapeHtml(lines[i]) +
      "</span>" +
      "</div>";
  }
  html += "</div>";
  return html;
}

function renderErrorHighlight(issue) {
  var container = document.getElementById("error-highlight-" + issue);
  if (!container) return;

  fetch("/api/logs/" + encodeURIComponent(issue))
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var content = data.content || "";
      var lines = content.split("\n");
      var errorLines = [];
      for (var i = 0; i < lines.length; i++) {
        var lower = lines[i].toLowerCase();
        if (lower.indexOf("error") !== -1 || lower.indexOf("fail") !== -1) {
          errorLines.push(lines[i]);
        }
      }
      if (errorLines.length === 0) {
        container.innerHTML = "";
        return;
      }
      // Show last error
      var lastError = errorLines[errorLines.length - 1];
      container.innerHTML =
        '<div class="error-highlight">' +
        '<span class="error-highlight-title">LAST ERROR</span>' +
        '<pre class="error-highlight-content">' +
        escapeHtml(lastError) +
        "</pre>" +
        "</div>";
    })
    .catch(function () {
      container.innerHTML = "";
    });
}

// ══════════════════════════════════════════════════════════════════
// PHASE 2: QUEUE DETAILED, COST BREAKDOWN, COST TREND, DORA TREND
// ══════════════════════════════════════════════════════════════════

function renderQueueDetailed() {
  var container = document.getElementById("queue-detailed-container");
  if (!container) return;

  fetch("/api/queue/detailed")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var items = data.items || data.queue || [];
      if (items.length === 0) {
        container.innerHTML =
          '<div class="empty-state"><p>Queue empty</p></div>';
        return;
      }
      var html = "";
      for (var i = 0; i < items.length; i++) {
        var q = items[i];
        var costEst =
          q.estimated_cost != null
            ? "$" + q.estimated_cost.toFixed(2)
            : "\u2014";
        html +=
          '<div class="queue-detailed-row" data-idx="' +
          i +
          '">' +
          '<div class="queue-detailed-header">' +
          '<span class="queue-issue">#' +
          q.issue +
          "</span>" +
          '<span class="queue-title-text">' +
          escapeHtml(q.title || "") +
          "</span>" +
          '<span class="queue-score">' +
          (q.score != null ? q.score : "\u2014") +
          "</span>" +
          '<span class="queue-cost-est">' +
          costEst +
          "</span>" +
          "</div>" +
          '<div class="queue-detailed-body" id="queue-detailed-body-' +
          i +
          '" style="display:none">';
        if (q.factors) {
          html += renderScoringFactors(q.factors);
        }
        html += "</div></div>";
      }
      container.innerHTML = html;

      // Expand/collapse handlers
      var rows = container.querySelectorAll(".queue-detailed-row");
      for (var i = 0; i < rows.length; i++) {
        rows[i]
          .querySelector(".queue-detailed-header")
          .addEventListener("click", function () {
            var idx = this.parentNode.getAttribute("data-idx");
            var body = document.getElementById("queue-detailed-body-" + idx);
            if (body) {
              body.style.display = body.style.display === "none" ? "" : "none";
            }
          });
      }
    })
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderCostBreakdown() {
  var container = document.getElementById("cost-breakdown-container");
  if (!container) return;

  fetch("/api/costs/breakdown?period=7")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      costBreakdownCache = data;
      var html = "";

      // Cost by model
      if (data.by_model) {
        html +=
          '<div class="cost-section"><div class="cost-section-label">COST BY MODEL</div>';
        var modelColors = {
          opus: "#7c3aed",
          sonnet: "#00d4ff",
          haiku: "#4ade80",
        };
        var models = Object.keys(data.by_model);
        var maxModel = 0;
        for (var i = 0; i < models.length; i++) {
          if (data.by_model[models[i]] > maxModel)
            maxModel = data.by_model[models[i]];
        }
        if (maxModel === 0) maxModel = 1;
        for (var i = 0; i < models.length; i++) {
          var m = models[i];
          var val = data.by_model[m];
          var pct = (val / maxModel) * 100;
          var color = modelColors[m.toLowerCase()] || "#5a6d8a";
          html +=
            '<div class="cost-bar-row">' +
            '<span class="cost-bar-label">' +
            escapeHtml(m) +
            "</span>" +
            '<div class="cost-bar-track-h">' +
            '<div class="cost-bar-fill-h" style="width:' +
            pct +
            "%;background:" +
            color +
            '"></div>' +
            "</div>" +
            '<span class="cost-bar-value">$' +
            val.toFixed(2) +
            "</span>" +
            "</div>";
        }
        html += "</div>";
      }

      // Cost by stage
      if (data.by_stage) {
        html +=
          '<div class="cost-section"><div class="cost-section-label">COST BY STAGE</div>';
        var stages = Object.keys(data.by_stage);
        var maxStage = 0;
        for (var i = 0; i < stages.length; i++) {
          if (data.by_stage[stages[i]] > maxStage)
            maxStage = data.by_stage[stages[i]];
        }
        if (maxStage === 0) maxStage = 1;
        for (var i = 0; i < stages.length; i++) {
          var s = stages[i];
          var val = data.by_stage[s];
          var pct = (val / maxStage) * 100;
          var colorIdx = STAGES.indexOf(s);
          var barColor = colorIdx >= 0 ? STAGE_HEX[s] || "#5a6d8a" : "#5a6d8a";
          html +=
            '<div class="cost-bar-row">' +
            '<span class="cost-bar-label">' +
            escapeHtml(s) +
            "</span>" +
            '<div class="cost-bar-track-h">' +
            '<div class="cost-bar-fill-h" style="width:' +
            pct +
            "%;background:" +
            barColor +
            '"></div>' +
            "</div>" +
            '<span class="cost-bar-value">$' +
            val.toFixed(2) +
            "</span>" +
            "</div>";
        }
        html += "</div>";
      }

      // Cost per issue
      if (data.by_issue && data.by_issue.length > 0) {
        html +=
          '<div class="cost-section"><div class="cost-section-label">COST PER ISSUE</div>';
        html +=
          '<table class="cost-issue-table"><thead><tr><th>Issue</th><th>Cost</th></tr></thead><tbody>';
        var sorted = data.by_issue.slice().sort(function (a, b) {
          return (b.cost || 0) - (a.cost || 0);
        });
        for (var i = 0; i < sorted.length; i++) {
          html +=
            "<tr><td>#" +
            sorted[i].issue +
            "</td><td>$" +
            (sorted[i].cost || 0).toFixed(2) +
            "</td></tr>";
        }
        html += "</tbody></table></div>";
      }

      // Budget utilization
      if (data.budget != null && data.spent != null) {
        var budgetPct =
          data.budget > 0 ? Math.min((data.spent / data.budget) * 100, 100) : 0;
        var budgetClass =
          budgetPct >= 80
            ? "cost-over"
            : budgetPct >= 60
              ? "cost-warn"
              : "cost-ok";
        html +=
          '<div class="cost-section"><div class="cost-section-label">BUDGET UTILIZATION</div>' +
          '<div class="budget-util-bar">' +
          '<div class="cost-bar-track"><div class="cost-bar-fill ' +
          budgetClass +
          '" style="width:' +
          budgetPct.toFixed(0) +
          '%"></div></div>' +
          '<span class="budget-util-text">$' +
          data.spent.toFixed(2) +
          " / $" +
          data.budget.toFixed(2) +
          " (" +
          budgetPct.toFixed(0) +
          "%)</span>" +
          "</div></div>";
      }

      container.innerHTML =
        html || '<div class="empty-state"><p>No cost data</p></div>';
    })
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderCostTrend() {
  var container = document.getElementById("cost-trend-container");
  if (!container) return;

  fetch("/api/costs/trend?period=30")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var points = data.points || data.daily || [];
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
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderDoraTrend() {
  var container = document.getElementById("dora-trend-container");
  if (!container) return;

  fetch("/api/metrics/dora-trend?period=30")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var metrics = [
        { key: "deploy_freq", label: "Deploy Freq", color: "#00d4ff" },
        { key: "lead_time", label: "Lead Time", color: "#0066ff" },
        { key: "cfr", label: "Change Fail Rate", color: "#f43f5e" },
        { key: "mttr", label: "MTTR", color: "#4ade80" },
      ];
      var html = '<div class="dora-trend-grid">';
      for (var i = 0; i < metrics.length; i++) {
        var m = metrics[i];
        var points = data[m.key] || [];
        html +=
          '<div class="dora-trend-card">' +
          '<span class="dora-trend-label">' +
          escapeHtml(m.label) +
          "</span>";
        if (points.length > 0) {
          html += renderSparkline(points, m.color, 120, 30);
        } else {
          html += '<span class="dora-trend-empty">\u2014</span>';
        }
        html += "</div>";
      }
      html += "</div>";
      container.innerHTML = html;
    })
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderSparkline(points, color, width, height) {
  if (!points || points.length < 2) return "";
  var maxVal = 0;
  var minVal = Infinity;
  for (var i = 0; i < points.length; i++) {
    var v = typeof points[i] === "object" ? points[i].value || 0 : points[i];
    if (v > maxVal) maxVal = v;
    if (v < minVal) minVal = v;
  }
  var range = maxVal - minVal || 1;
  var padding = 2;
  var w = width - padding * 2;
  var h = height - padding * 2;

  var pathParts = [];
  for (var i = 0; i < points.length; i++) {
    var v = typeof points[i] === "object" ? points[i].value || 0 : points[i];
    var x = padding + (i / (points.length - 1)) * w;
    var y = padding + h - ((v - minVal) / range) * h;
    pathParts.push((i === 0 ? "M" : "L") + x.toFixed(1) + "," + y.toFixed(1));
  }

  return (
    '<svg class="sparkline" width="' +
    width +
    '" height="' +
    height +
    '" viewBox="0 0 ' +
    width +
    " " +
    height +
    '">' +
    '<path d="' +
    pathParts.join(" ") +
    '" fill="none" stroke="' +
    color +
    '" stroke-width="1.5" stroke-linecap="round"/></svg>'
  );
}

function renderSVGLineChart(points, valueKey, color, width, height) {
  if (!points || points.length < 2)
    return '<div class="empty-state"><p>Not enough data</p></div>';
  var maxVal = 0;
  for (var i = 0; i < points.length; i++) {
    var v =
      typeof points[i] === "object"
        ? points[i][valueKey] || points[i].value || 0
        : points[i];
    if (v > maxVal) maxVal = v;
  }
  if (maxVal === 0) maxVal = 1;
  var padding = 20;
  var chartW = width - padding * 2;
  var chartH = height - padding * 2;

  var svg =
    '<svg class="svg-line-chart" viewBox="0 0 ' +
    width +
    " " +
    height +
    '" width="100%" height="' +
    height +
    '">';

  // Grid lines
  for (var g = 0; g <= 4; g++) {
    var gy = padding + (g / 4) * chartH;
    svg +=
      '<line x1="' +
      padding +
      '" y1="' +
      gy +
      '" x2="' +
      (width - padding) +
      '" y2="' +
      gy +
      '" stroke="#1a3a6a" stroke-width="0.5"/>';
  }

  var pathParts = [];
  for (var i = 0; i < points.length; i++) {
    var v =
      typeof points[i] === "object"
        ? points[i][valueKey] || points[i].value || 0
        : points[i];
    var x = padding + (i / (points.length - 1)) * chartW;
    var y = padding + chartH - (v / maxVal) * chartH;
    pathParts.push((i === 0 ? "M" : "L") + x.toFixed(1) + "," + y.toFixed(1));
  }

  // Fill area
  var lastX = padding + chartW;
  var firstX = padding;
  svg +=
    '<path d="' +
    pathParts.join(" ") +
    " L" +
    lastX +
    "," +
    (padding + chartH) +
    " L" +
    firstX +
    "," +
    (padding + chartH) +
    ' Z" fill="' +
    color +
    '" opacity="0.1"/>';
  // Line
  svg +=
    '<path d="' +
    pathParts.join(" ") +
    '" fill="none" stroke="' +
    color +
    '" stroke-width="2" stroke-linecap="round"/>';

  svg += "</svg>";
  return svg;
}

// ══════════════════════════════════════════════════════════════════
// PHASE 3: INSIGHTS TAB
// ══════════════════════════════════════════════════════════════════

function fetchInsightsData() {
  var panel = document.getElementById("panel-insights");
  if (!panel) return;
  if (insightsCache) {
    renderInsightsTab(insightsCache);
    return;
  }

  panel.innerHTML = '<div class="empty-state"><p>Loading insights...</p></div>';

  var results = {
    patterns: null,
    decisions: null,
    patrol: null,
    heatmap: null,
  };
  var pending = 4;

  function checkDone() {
    pending--;
    if (pending <= 0) {
      insightsCache = results;
      renderInsightsTab(results);
    }
  }

  fetch("/api/memory/patterns")
    .then(function (r) {
      return r.ok ? r.json() : { patterns: [] };
    })
    .then(function (d) {
      results.patterns = d.patterns || d;
    })
    .catch(function () {
      results.patterns = [];
    })
    .then(checkDone);

  fetch("/api/memory/decisions")
    .then(function (r) {
      return r.ok ? r.json() : { decisions: [] };
    })
    .then(function (d) {
      results.decisions = d.decisions || d;
    })
    .catch(function () {
      results.decisions = [];
    })
    .then(checkDone);

  fetch("/api/patrol/recent")
    .then(function (r) {
      return r.ok ? r.json() : { findings: [] };
    })
    .then(function (d) {
      results.patrol = d.findings || d;
    })
    .catch(function () {
      results.patrol = [];
    })
    .then(checkDone);

  fetch("/api/metrics/failure-heatmap")
    .then(function (r) {
      return r.ok ? r.json() : { data: [] };
    })
    .then(function (d) {
      results.heatmap = d;
    })
    .catch(function () {
      results.heatmap = null;
    })
    .then(checkDone);
}

function renderInsightsTab(data) {
  var panel = document.getElementById("panel-insights");
  if (!panel) return;

  var html = '<div class="insights-grid">';

  // Failure patterns section
  html +=
    '<div class="insights-section">' +
    '<div class="section-header"><h3>Failure Patterns</h3></div>' +
    '<div id="failure-patterns-content">' +
    renderFailurePatterns(data.patterns || []) +
    "</div></div>";

  // Patrol findings section
  html +=
    '<div class="insights-section">' +
    '<div class="section-header"><h3>Patrol Findings</h3></div>' +
    '<div id="patrol-findings-content">' +
    renderPatrolFindings(data.patrol || []) +
    "</div></div>";

  // Decision log section
  html +=
    '<div class="insights-section insights-full-width">' +
    '<div class="section-header"><h3>Decision Log</h3></div>' +
    '<div id="decision-log-content">' +
    renderDecisionLog(data.decisions || []) +
    "</div></div>";

  // Failure heatmap section
  html +=
    '<div class="insights-section insights-full-width">' +
    '<div class="section-header"><h3>Failure Heatmap</h3></div>' +
    '<div id="failure-heatmap-content">' +
    renderFailureHeatmap(data.heatmap) +
    "</div></div>";

  html += "</div>";
  panel.innerHTML = html;
}

function renderFailurePatterns(patterns) {
  if (!patterns || patterns.length === 0) {
    return '<div class="empty-state"><p>No failure patterns recorded</p></div>';
  }

  // Sort by frequency (most common first)
  var sorted = patterns.slice().sort(function (a, b) {
    return (b.frequency || b.count || 0) - (a.frequency || a.count || 0);
  });

  var html = "";
  for (var i = 0; i < sorted.length; i++) {
    var p = sorted[i];
    var freq = p.frequency || p.count || 0;
    html +=
      '<div class="pattern-card">' +
      '<div class="pattern-card-header">' +
      '<span class="pattern-desc">' +
      escapeHtml(p.description || p.pattern || "") +
      "</span>" +
      '<span class="pattern-freq-badge">' +
      freq +
      "x</span>" +
      "</div>";
    if (p.root_cause) {
      html +=
        '<div class="pattern-detail"><span class="pattern-label">Root cause:</span> ' +
        escapeHtml(p.root_cause) +
        "</div>";
    }
    if (p.fix || p.suggested_fix) {
      html +=
        '<div class="pattern-detail pattern-fix"><span class="pattern-label">Fix:</span> ' +
        escapeHtml(p.fix || p.suggested_fix) +
        "</div>";
    }
    html += "</div>";
  }
  return html;
}

function renderPatrolFindings(findings) {
  if (!findings || findings.length === 0) {
    return '<div class="empty-state"><p>No patrol findings</p></div>';
  }

  var html = "";
  for (var i = 0; i < findings.length; i++) {
    var f = findings[i];
    var severity = (f.severity || "low").toLowerCase();
    html +=
      '<div class="patrol-card">' +
      '<div class="patrol-card-header">' +
      '<span class="patrol-severity-badge severity-' +
      escapeHtml(severity) +
      '">' +
      escapeHtml(severity.toUpperCase()) +
      "</span>" +
      '<span class="patrol-type">' +
      escapeHtml(f.type || f.category || "") +
      "</span>" +
      "</div>" +
      '<div class="patrol-desc">' +
      escapeHtml(f.description || f.message || "") +
      "</div>" +
      (f.file
        ? '<div class="patrol-file">' + escapeHtml(f.file) + "</div>"
        : "") +
      "</div>";
  }
  return html;
}

function renderDecisionLog(decisions) {
  if (!decisions || decisions.length === 0) {
    return '<div class="empty-state"><p>No decisions logged</p></div>';
  }

  var html = '<div class="decision-list">';
  for (var i = 0; i < decisions.length; i++) {
    var d = decisions[i];
    html +=
      '<div class="decision-row">' +
      '<span class="decision-ts">' +
      formatTime(d.timestamp || d.ts) +
      "</span>" +
      '<span class="decision-action">' +
      escapeHtml(d.action || d.decision || "") +
      "</span>" +
      '<span class="decision-outcome">' +
      escapeHtml(d.outcome || d.result || "") +
      "</span>" +
      (d.issue ? '<span class="decision-issue">#' + d.issue + "</span>" : "") +
      "</div>";
  }
  html += "</div>";
  return html;
}

function renderFailureHeatmap(data) {
  if (!data || !data.stages || !data.days) {
    return '<div class="empty-state"><p>No heatmap data</p></div>';
  }

  var stages = data.stages || [];
  var days = data.days || [];
  var cells = data.cells || {};

  if (stages.length === 0 || days.length === 0) {
    return '<div class="empty-state"><p>No heatmap data</p></div>';
  }

  // Find max for color scaling
  var maxCount = 0;
  for (var key in cells) {
    if (cells[key] > maxCount) maxCount = cells[key];
  }
  if (maxCount === 0) maxCount = 1;

  var html =
    '<div class="heatmap-grid" style="grid-template-columns: 100px repeat(' +
    days.length +
    ', 1fr)">';

  // Header row
  html += '<div class="heatmap-corner"></div>';
  for (var d = 0; d < days.length; d++) {
    var parts = days[d].split("-");
    var label = parts.length >= 3 ? parts[1] + "/" + parts[2] : days[d];
    html += '<div class="heatmap-day-label">' + escapeHtml(label) + "</div>";
  }

  // Data rows
  for (var s = 0; s < stages.length; s++) {
    html +=
      '<div class="heatmap-stage-label">' + escapeHtml(stages[s]) + "</div>";
    for (var d = 0; d < days.length; d++) {
      var key = stages[s] + ":" + days[d];
      var count = cells[key] || 0;
      var intensity = count / maxCount;
      var bgColor =
        count === 0
          ? "transparent"
          : "rgba(244, 63, 94, " + (0.2 + intensity * 0.8).toFixed(2) + ")";
      html +=
        '<div class="heatmap-cell" style="background:' +
        bgColor +
        '" title="' +
        escapeHtml(stages[s]) +
        " " +
        escapeHtml(days[d]) +
        ": " +
        count +
        ' failures">' +
        (count > 0 ? count : "") +
        "</div>";
    }
  }

  html += "</div>";
  return html;
}

// ══════════════════════════════════════════════════════════════════
// PHASE 4: STAGE PERFORMANCE, BOTTLENECK, THROUGHPUT, CAPACITY
// ══════════════════════════════════════════════════════════════════

function renderStagePerformance() {
  var container = document.getElementById("stage-performance-container");
  if (!container) return;

  fetch("/api/metrics/stage-performance?period=7")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var stages = data.stages || [];
      if (stages.length === 0) {
        container.innerHTML =
          '<div class="empty-state"><p>No stage performance data</p></div>';
        return;
      }
      var html =
        '<table class="stage-perf-table">' +
        "<thead><tr><th>Stage</th><th>Avg</th><th>Min</th><th>Max</th><th>Count</th><th>Trend</th></tr></thead>" +
        "<tbody>";
      for (var i = 0; i < stages.length; i++) {
        var s = stages[i];
        var trendArrow = "";
        if (s.trend_pct != null) {
          if (s.trend_pct > 5)
            trendArrow =
              '<span class="trend-up">\u2191 ' +
              s.trend_pct.toFixed(0) +
              "%</span>";
          else if (s.trend_pct < -5)
            trendArrow =
              '<span class="trend-down">\u2193 ' +
              Math.abs(s.trend_pct).toFixed(0) +
              "%</span>";
          else trendArrow = '<span class="trend-flat">\u2192</span>';
        }
        html +=
          "<tr>" +
          "<td>" +
          escapeHtml(s.name || s.stage || "") +
          "</td>" +
          "<td>" +
          formatDuration(s.avg_s) +
          "</td>" +
          "<td>" +
          formatDuration(s.min_s) +
          "</td>" +
          "<td>" +
          formatDuration(s.max_s) +
          "</td>" +
          "<td>" +
          (s.count || 0) +
          "</td>" +
          "<td>" +
          trendArrow +
          "</td>" +
          "</tr>";
      }
      html += "</tbody></table>";
      container.innerHTML = html;
    })
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderBottleneckAlert() {
  var container = document.getElementById("bottleneck-alert-container");
  if (!container) return;

  fetch("/api/metrics/bottlenecks")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      if (!data.bottleneck) {
        container.innerHTML = "";
        return;
      }
      var b = data.bottleneck;
      var msg =
        escapeHtml(b.stage || "Unknown") +
        " stage averages " +
        formatDuration(b.avg_s) +
        ", " +
        (b.ratio || "?") +
        "x longer than " +
        escapeHtml(b.comparison_stage || "other stages");
      var suggestion = b.suggestion
        ? '<div class="bottleneck-suggestion">' +
          escapeHtml(b.suggestion) +
          "</div>"
        : "";
      container.innerHTML =
        '<div class="bottleneck-alert">' +
        '<span class="bottleneck-icon">\u26A0</span>' +
        '<span class="bottleneck-msg">' +
        msg +
        "</span>" +
        suggestion +
        "</div>";
    })
    .catch(function () {
      container.innerHTML = "";
    });
}

function renderThroughputTrend() {
  var container = document.getElementById("throughput-trend-container");
  if (!container) return;

  fetch("/api/metrics/throughput-trend?period=30")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var points = data.points || data.daily || [];
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
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

function renderCapacityForecast() {
  var container = document.getElementById("capacity-forecast-container");
  if (!container) return;

  fetch("/api/metrics/capacity")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      if (!data.rate && !data.queue_clear_hours) {
        container.innerHTML =
          '<div class="empty-state"><p>No capacity data</p></div>';
        return;
      }
      var rate = data.rate != null ? data.rate.toFixed(1) : "?";
      var clearTime =
        data.queue_clear_hours != null
          ? data.queue_clear_hours.toFixed(1)
          : "?";
      container.innerHTML =
        '<div class="capacity-forecast">' +
        '<span class="capacity-text">At current rate (' +
        rate +
        "/hr), queue will clear in " +
        "<strong>" +
        clearTime +
        " hours</strong></span>" +
        "</div>";
    })
    .catch(function (err) {
      container.innerHTML =
        '<div class="empty-state"><p>Failed to load: ' +
        escapeHtml(String(err)) +
        "</p></div>";
    });
}

// ══════════════════════════════════════════════════════════════════
// PHASE 5: ALERT BANNER, BULK ACTIONS, EMERGENCY BRAKE
// ══════════════════════════════════════════════════════════════════

function renderAlertBanner() {
  var container = document.getElementById("alert-banner");
  if (!container) return;

  if (alertDismissed) {
    container.innerHTML = "";
    container.style.display = "none";
    return;
  }

  fetch("/api/alerts")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      var alerts = data.alerts || [];
      if (alerts.length === 0) {
        container.innerHTML = "";
        container.style.display = "none";
        return;
      }

      // Show highest severity alert
      var alert = alerts[0];
      alertsCache = alerts;

      var severityClass = "alert-" + (alert.severity || "info");
      var html =
        '<div class="alert-banner-content ' +
        severityClass +
        '">' +
        '<span class="alert-banner-icon">\u26A0</span>' +
        '<span class="alert-banner-msg">' +
        escapeHtml(alert.message || "") +
        "</span>" +
        '<span class="alert-banner-actions">';

      // Action buttons depend on alert type
      if (alert.issue) {
        html +=
          '<button class="alert-action-btn" onclick="switchTab(\'pipelines\');fetchPipelineDetail(' +
          alert.issue +
          ')">View</button>';
      }
      if (alert.type === "failure_spike") {
        html +=
          "<button class=\"alert-action-btn btn-abort\" onclick=\"document.getElementById('emergency-modal').style.display=''\">Emergency Brake</button>";
      }
      if (alert.type === "stuck_pipeline" && alert.issue) {
        html +=
          '<button class="alert-action-btn btn-abort" onclick="sendIntervention(' +
          alert.issue +
          ",'abort')\">Abort</button>" +
          '<button class="alert-action-btn" onclick="sendIntervention(' +
          alert.issue +
          ",'skip_stage')\">Skip Stage</button>";
      }

      html +=
        '<button class="alert-dismiss-btn" onclick="dismissAlert()">\u2715</button>';
      html += "</span></div>";

      container.innerHTML = html;
      container.style.display = "";
    })
    .catch(function () {
      container.innerHTML = "";
      container.style.display = "none";
    });
}

function dismissAlert() {
  alertDismissed = true;
  var container = document.getElementById("alert-banner");
  if (container) {
    container.innerHTML = "";
    container.style.display = "none";
  }
  // Reset on next WS message with new alerts
  setTimeout(function () {
    alertDismissed = false;
  }, 30000);
}

function updateBulkToolbar() {
  var toolbar = document.getElementById("bulk-actions");
  if (!toolbar) return;
  var count = Object.keys(selectedIssues).length;
  if (count === 0) {
    toolbar.style.display = "none";
    return;
  }
  toolbar.style.display = "";
  var countEl = document.getElementById("bulk-count");
  if (countEl) countEl.textContent = count + " selected";
}

function setupBulkActions() {
  var toolbar = document.getElementById("bulk-actions");
  if (!toolbar) return;

  var pauseBtn = document.getElementById("bulk-pause");
  var resumeBtn = document.getElementById("bulk-resume");
  var abortBtn = document.getElementById("bulk-abort");

  if (pauseBtn) {
    pauseBtn.addEventListener("click", function () {
      var issues = Object.keys(selectedIssues);
      for (var i = 0; i < issues.length; i++) {
        sendIntervention(issues[i], "pause");
      }
    });
  }

  if (resumeBtn) {
    resumeBtn.addEventListener("click", function () {
      var issues = Object.keys(selectedIssues);
      for (var i = 0; i < issues.length; i++) {
        sendIntervention(issues[i], "resume");
      }
    });
  }

  if (abortBtn) {
    abortBtn.addEventListener("click", function () {
      var issues = Object.keys(selectedIssues);
      if (issues.length === 0) return;
      if (
        confirm(
          "Abort " + issues.length + " pipeline(s)? This cannot be undone.",
        )
      ) {
        for (var i = 0; i < issues.length; i++) {
          sendIntervention(issues[i], "abort");
        }
        selectedIssues = {};
        updateBulkToolbar();
      }
    });
  }
}

function updateEmergencyBrakeVisibility(data) {
  var brakeBtn = document.getElementById("emergency-brake");
  if (!brakeBtn) return;
  var active = data.pipelines ? data.pipelines.length : 0;
  brakeBtn.style.display = active > 0 ? "" : "none";
}

function setupEmergencyBrake() {
  var brakeBtn = document.getElementById("emergency-brake");
  if (!brakeBtn) return;

  brakeBtn.addEventListener("click", function () {
    var modal = document.getElementById("emergency-modal");
    if (modal) modal.style.display = "";
  });

  var confirmBtn = document.getElementById("emergency-confirm");
  var cancelBtn = document.getElementById("emergency-cancel");
  var modal = document.getElementById("emergency-modal");

  if (cancelBtn && modal) {
    cancelBtn.addEventListener("click", function () {
      modal.style.display = "none";
    });
  }

  if (modal) {
    modal.addEventListener("click", function (e) {
      if (e.target === modal) modal.style.display = "none";
    });
  }

  if (confirmBtn) {
    confirmBtn.addEventListener("click", function () {
      fetch("/api/emergency-brake", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      })
        .then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then(function () {
          if (modal) modal.style.display = "none";
        })
        .catch(function (err) {
          console.error("Emergency brake failed:", err);
          if (modal) modal.style.display = "none";
        });
    });
  }
}

// ══════════════════════════════════════════════════════════════════
// HELPERS — truncate
// ══════════════════════════════════════════════════════════════════

function truncate(str, maxLen) {
  if (!str) return "";
  return str.length > maxLen ? str.substring(0, maxLen) + "\u2026" : str;
}

function padZero(n) {
  return n < 10 ? "0" + n : "" + n;
}

// ══════════════════════════════════════════════════════════════════
// Daemon Control
// ══════════════════════════════════════════════════════════════════
async function daemonControl(action) {
  var btn = document.getElementById("daemon-btn-" + action);
  if (btn) btn.disabled = true;

  try {
    var method = "POST";
    var url = "/api/daemon/" + action;

    // Toggle pause/resume
    if (action === "pause") {
      var badge = document.getElementById("daemon-status-badge");
      if (badge && badge.classList.contains("paused")) {
        url = "/api/daemon/resume";
      }
    }

    var resp = await fetch(url, { method: method });
    var data = await resp.json();
    if (!data.ok && data.error) {
      console.warn("Daemon control error:", data.error);
    }
    // Refresh daemon status after action
    setTimeout(fetchDaemonConfig, 1000);
  } catch (err) {
    console.error("Daemon control failed:", err);
  } finally {
    if (btn) btn.disabled = false;
  }
}

async function fetchDaemonConfig() {
  try {
    var resp = await fetch("/api/daemon/config");
    if (!resp.ok) return;
    var data = await resp.json();
    updateDaemonControlBar(data);
  } catch {
    // dashboard may not be running
  }
}

function updateDaemonControlBar(data) {
  var badge = document.getElementById("daemon-status-badge");
  var pauseBtn = document.getElementById("daemon-btn-pause");
  var workersEl = document.getElementById("daemon-info-workers");
  var pollEl = document.getElementById("daemon-info-poll");
  var patrolEl = document.getElementById("daemon-info-patrol");
  var budgetEl = document.getElementById("daemon-info-budget");

  if (!badge) return;

  // Determine daemon status
  if (data.paused) {
    badge.textContent = "Paused";
    badge.className = "daemon-status-badge paused";
    if (pauseBtn) pauseBtn.textContent = "Resume";
  } else if (data.config && data.config.watch_label) {
    badge.textContent = "Running";
    badge.className = "daemon-status-badge running";
    if (pauseBtn) pauseBtn.textContent = "Pause";
  } else {
    badge.textContent = "Stopped";
    badge.className = "daemon-status-badge stopped";
    if (pauseBtn) pauseBtn.textContent = "Pause";
  }

  // Update config info
  if (data.config) {
    if (workersEl) workersEl.textContent = data.config.max_workers || "-";
    if (pollEl) pollEl.textContent = data.config.poll_interval || "-";
    if (patrolEl)
      patrolEl.textContent =
        (data.config.patrol && data.config.patrol.interval) || "-";
  }

  // Update budget info
  if (data.budget && budgetEl) {
    var remaining = data.budget.remaining || data.budget.daily_limit || "-";
    budgetEl.textContent =
      typeof remaining === "number" ? remaining.toFixed(2) : remaining;
  }
}

// Wire alert actions for daemon control
function handleAlertAction(action) {
  if (action === "pause_daemon") {
    daemonControl("pause");
  } else if (action === "scale_up") {
    // Could implement config update; for now just log
    console.log("Scale up requested via alert action");
  }
}

// ══════════════════════════════════════════════════════════════════
// TEAM TAB
// ══════════════════════════════════════════════════════════════════

function timeAgo(date) {
  var seconds = Math.floor((Date.now() - date.getTime()) / 1000);
  if (seconds < 60) return seconds + "s ago";
  var minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + "m ago";
  var hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + "h ago";
  return Math.floor(hours / 24) + "d ago";
}

function fetchTeamData() {
  fetch("/api/team")
    .then(function (r) {
      return r.json();
    })
    .then(function (data) {
      teamCache = data;
      renderTeamGrid(data);
      renderTeamStats(data);
    })
    .catch(function () {});

  fetch("/api/team/activity")
    .then(function (r) {
      return r.json();
    })
    .then(function (data) {
      teamActivityCache = data;
      renderTeamActivity(data);
    })
    .catch(function () {});
}

function renderTeamStats(data) {
  var el = document.getElementById("team-stat-online");
  if (el) el.textContent = (data.total_online || 0).toString();
  el = document.getElementById("team-stat-pipelines");
  if (el) el.textContent = (data.total_active_pipelines || 0).toString();
  el = document.getElementById("team-stat-queued");
  if (el) el.textContent = (data.total_queued || 0).toString();
}

function renderTeamGrid(data) {
  var grid = document.getElementById("team-grid");
  if (!grid) return;

  var devs = data.developers || [];
  if (devs.length === 0) {
    grid.innerHTML =
      '<div class="empty-state">No developers connected. Run <code>shipwright connect start</code> to join.</div>';
    return;
  }

  grid.innerHTML = devs
    .map(function (dev) {
      var presence = dev._presence || "offline";
      var initials = (dev.developer_id || "?").substring(0, 2).toUpperCase();
      var pipelines = (dev.active_jobs || [])
        .map(function (job) {
          return (
            '<div class="team-card-pipeline-item">' +
            '<span class="team-card-pipeline-issue">#' +
            escapeHtml(String(job.issue)) +
            "</span>" +
            '<span class="team-card-pipeline-stage">' +
            escapeHtml(job.stage || "\u2014") +
            "</span>" +
            "</div>"
          );
        })
        .join("");

      var pipelineSection = pipelines
        ? '<div class="team-card-pipelines">' + pipelines + "</div>"
        : "";

      return (
        '<div class="team-card">' +
        '<div class="team-card-header">' +
        '<div class="team-card-avatar">' +
        escapeHtml(initials) +
        "</div>" +
        '<div class="team-card-info">' +
        '<div class="team-card-name">' +
        escapeHtml(dev.developer_id) +
        "</div>" +
        '<div class="team-card-machine">' +
        escapeHtml(dev.machine_name) +
        "</div>" +
        "</div>" +
        '<div class="presence-dot ' +
        presence +
        '" title="' +
        presence +
        '"></div>' +
        "</div>" +
        '<div class="team-card-body">' +
        '<div class="team-card-row">' +
        '<span class="team-card-row-label">Daemon</span>' +
        '<span class="team-card-row-value">' +
        (dev.daemon_running ? "\u25cf Running" : "\u25cb Stopped") +
        "</span>" +
        "</div>" +
        '<div class="team-card-row">' +
        '<span class="team-card-row-label">Active</span>' +
        '<span class="team-card-row-value">' +
        (dev.active_jobs || []).length +
        " pipelines</span>" +
        "</div>" +
        '<div class="team-card-row">' +
        '<span class="team-card-row-label">Queued</span>' +
        '<span class="team-card-row-value">' +
        (dev.queued || []).length +
        " issues</span>" +
        "</div>" +
        pipelineSection +
        "</div>" +
        "</div>"
      );
    })
    .join("");
}

function renderTeamActivity(events) {
  var container = document.getElementById("team-activity");
  if (!container) return;

  var items = Array.isArray(events) ? events : events.events || [];
  if (items.length === 0) {
    container.innerHTML =
      '<div class="empty-state">No team activity yet.</div>';
    return;
  }

  container.innerHTML = items
    .slice(0, 50)
    .map(function (evt) {
      var isCI = evt.from_developer === "github-actions";
      var badgeClass = isCI ? "ci" : "local";
      var badgeText = isCI ? "CI" : evt.from_developer || "local";
      var text = formatTeamEvent(evt);
      var time = evt.ts ? timeAgo(new Date(evt.ts)) : "";

      return (
        '<div class="team-activity-item">' +
        '<span class="source-badge ' +
        badgeClass +
        '">' +
        escapeHtml(badgeText) +
        "</span>" +
        '<div class="team-activity-content">' +
        '<div class="team-activity-text">' +
        text +
        "</div>" +
        '<div class="team-activity-time">' +
        time +
        "</div>" +
        "</div>" +
        "</div>"
      );
    })
    .join("");
}

function formatTeamEvent(evt) {
  var type = evt.type || "";
  var issue = evt.issue ? " #" + evt.issue : "";

  if (type.indexOf("pipeline.started") !== -1)
    return "Pipeline started" + issue;
  if (
    type.indexOf("pipeline.completed") !== -1 ||
    type.indexOf("pipeline_completed") !== -1
  ) {
    var result = evt.result === "success" ? "\u2713" : "\u2717";
    return "Pipeline " + result + issue;
  }
  if (type.indexOf("stage.") !== -1) {
    var stage = evt.stage || type.split(".").pop();
    return "Stage " + escapeHtml(stage) + issue;
  }
  if (type.indexOf("daemon.") !== -1)
    return type.replace("daemon.", "Daemon: ");
  if (type.indexOf("ci.") !== -1) return type.replace("ci.", "CI: ") + issue;

  return escapeHtml(type) + issue;
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
setupBulkActions();
setupEmergencyBrake();
setupMachinesTab();
fetchDaemonConfig();
setInterval(fetchDaemonConfig, 30000);
connect();
