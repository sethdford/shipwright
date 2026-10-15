/**
 * F12 dashboard boundaries (D1–D4, spec §3.3, ADR-0008). The dashboard is a separate TypeScript
 * project until it is ported (Wave 3): server.ts (routing) → routes/ → middleware/ and services/ →
 * types/; the browser bundle in dashboard/src talks to the server only over HTTP, and neither side
 * imports src/. Each comment names the fix. Fixtures: tools/arch/depcruise-rules.test.ts.
 */
const SERVER = "^dashboard/(server\\.ts|routes|services|middleware|types)(/|$)";
module.exports = {
  forbidden: [
    {
      name: "D1-browser-server-split",
      comment:
        "D1: dashboard/src is the browser bundle and the server side is Bun. Neither imports the other: talk over HTTP, and keep browser wire types in dashboard/src/types/api.ts.",
      severity: "error",
      from: { path: "^dashboard/src/" },
      to: { path: SERVER },
    },
    {
      name: "D1-server-browser-split",
      comment:
        "D1: the server must not import the browser bundle (dashboard/src). Move shared logic into dashboard/services.",
      severity: "error",
      from: { path: SERVER },
      to: { path: "^dashboard/src/" },
    },
    {
      name: "D1-dashboard-not-src",
      comment:
        "D1: the dashboard does not import src/ until it is ported (Wave 3). Call the shipwright CLI from a service, or port the route into src/.",
      severity: "error",
      from: { path: "^dashboard/" },
      to: { path: "^src/" },
    },
    {
      name: "D2-services-are-the-bottom-layer",
      comment:
        "D2: services/ and types/ never import routes/, middleware/ or server.ts. Pass what the service needs as parameters.",
      severity: "error",
      from: { path: "^dashboard/(services|types)/" },
      to: { path: "^dashboard/(routes|middleware|server\\.ts)" },
    },
    {
      name: "D2-middleware-not-routes",
      comment:
        "D2: middleware/ never imports routes/ or server.ts. Move the shared piece into middleware/ or services/.",
      severity: "error",
      from: { path: "^dashboard/middleware/" },
      to: { path: "^dashboard/(routes|server\\.ts)" },
    },
    {
      name: "D3-routes-not-server",
      comment:
        "D3: routes/ never imports server.ts or another route. Move the shared piece into services/ or middleware/.",
      severity: "error",
      from: { path: "^dashboard/routes/([^/]+)\\.ts$" },
      to: { path: "^dashboard/(server\\.ts|routes/)", pathNot: "^dashboard/routes/$1\\.ts$" },
    },
    {
      name: "D4-no-cycles",
      comment: "D4: break the cycle by moving the shared piece down into services/ or types/.",
      severity: "error",
      from: { path: "^dashboard/" },
      to: { circular: true },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    exclude: { path: ["\\.test\\.ts$", "^dashboard/(public|coverage|node_modules)/"] },
    tsPreCompilationDeps: true,
    // The server tsconfig (Wave 1a Task 15) resolves "./x.js" imports to the .ts sources.
    tsConfig: { fileName: "dashboard/tsconfig.server.json" },
  },
};
