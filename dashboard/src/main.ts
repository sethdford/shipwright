// Fleet Command Dashboard - Main Entry Point
// Boots WebSocket, router, header, modals, and registers all views

import { connect } from "./core/ws";
import { store } from "./core/state";
import { setupRouter, registerView } from "./core/router";
import {
  setupHeader,
  renderCostTicker,
  renderAlertBanner,
  updateEmergencyBrakeVisibility,
  updateAmbientIndicator,
  detectCompletions,
} from "./components/header";
import { setupInterventionModal, setupBulkActions } from "./components/modal";

// Views
import { overviewView } from "./views/overview";
import { agentsView } from "./views/agents";
import { pipelinesView } from "./views/pipelines";
import { timelineView } from "./views/timeline";
import { activityView } from "./views/activity";
import { metricsView } from "./views/metrics";
import { machinesView } from "./views/machines";
import { insightsView } from "./views/insights";
import { teamView } from "./views/team";

// New visualization views (lazy-loaded when tabs exist)
import { fleetMapView } from "./views/fleet-map";
import { pipelineTheaterView } from "./views/pipeline-theater";
import { agentCockpitView } from "./views/agent-cockpit";

// Register all views
registerView("overview", overviewView);
registerView("agents", agentsView);
registerView("pipelines", pipelinesView);
registerView("timeline", timelineView);
registerView("activity", activityView);
registerView("metrics", metricsView);
registerView("machines", machinesView);
registerView("insights", insightsView);
registerView("team", teamView);
registerView("fleet-map", fleetMapView);
registerView("pipeline-theater", pipelineTheaterView);
registerView("agent-cockpit", agentCockpitView);

// Setup header (user menu, daemon control, emergency brake)
setupHeader();

// Setup shared modals
setupInterventionModal();
setupBulkActions();

// Setup tab routing
setupRouter();

// Subscribe to fleet state for global UI updates
store.subscribe("fleetState", (data) => {
  if (!data) return;
  renderCostTicker(data);
  renderAlertBanner(data);
  updateEmergencyBrakeVisibility(data);
  updateAmbientIndicator(data);
  detectCompletions(data);
});

// Connect WebSocket
connect();
